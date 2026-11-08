#!/usr/bin/env python3
"""Explicit task manifests → isolated CLI agents → verification → durable acceptance."""

import argparse
from collections import defaultdict
import json
from pathlib import Path
import re
import shutil
import signal
import sys

from doctor import ROOT, RUNS, BUNDLED_CODEX, exclusive_run
from orchestration.context import make_packet, validate
from orchestration.engine import Engine
from orchestration.provider import Codex
from orchestration.storage import State


def metrics(directory):
    data = json.loads((directory / "state.json").read_text())
    groups = defaultdict(lambda: {"calls": 0, "retries": 0, "prompt_bytes": 0,
                                 "reported_tokens_by_call": [],
                                 "unknown_usage_calls": 0, "elapsed_seconds": 0})
    for tid, record in data["tasks"].items():
        for call in record["calls"]:
            group = groups[f"{tid}/{call['agent']}/{call['model']}"]
            group["calls"] += 1
            group["retries"] += int(call["retry"] > 0)
            group["prompt_bytes"] += call["prompt_bytes"]
            group["elapsed_seconds"] += call.get("elapsed_seconds") or 0
            group["unknown_usage_calls"] += int(any(call.get(k) is None for k in ("input_tokens", "output_tokens", "cached_input_tokens")))
            group["reported_tokens_by_call"].append({"id": call["id"],
                **{key: call.get(key) for key in ("input_tokens", "output_tokens", "cached_input_tokens")},
                "scope": call.get("usage_scope", "unspecified")})
    return {"groups": dict(groups), "note": "Raw CLI counters are not summed: resumed sessions may report cumulative usage. Unknown is not zero. Subscription quota is not inferred from tokens."}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("validate", "context", "run", "status", "metrics"))
    parser.add_argument("--manifest", type=Path)
    parser.add_argument("--config", type=Path, default=Path(__file__).with_name("orchestrator.config.json"))
    parser.add_argument("--run-id", default="queue")
    parser.add_argument("--task")
    parser.add_argument("--role", choices=("developer", "reviewer", "qa"), default="developer")
    parser.add_argument("--resume", action="store_true")
    parser.add_argument("--codex", default=shutil.which("codex") or str(BUNDLED_CODEX))
    args = parser.parse_args()
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]{0,79}", args.run_id):
        parser.error("Invalid run ID")
    directory = RUNS / ("orchestrator-" + args.run_id)
    if not directory.resolve().is_relative_to(RUNS.resolve()):
        parser.error("Run path escapes evidence directory")
    def interrupted(signum, frame):
        raise InterruptedError(f"signal {signum}")
    signal.signal(signal.SIGTERM, interrupted)
    try:
        if args.command == "status":
            data = json.loads((directory / "state.json").read_text())
            print(json.dumps({tid: {"status": r["status"], "phase": r["phase"], "counts": r["counts"], "reason": r.get("reason")}
                              for tid, r in data["tasks"].items()}, indent=2, ensure_ascii=False))
            return 0
        if args.command == "metrics":
            print(json.dumps(metrics(directory), indent=2, ensure_ascii=False))
            return 0
        if args.manifest is None:
            parser.error("--manifest is required")
        config = json.loads(args.config.read_text())
        tasks = json.loads(args.manifest.read_text())["tasks"]
        validate(config, tasks, ROOT)
        if args.command == "validate":
            print(f"VALID: {len(tasks)} explicit tasks; no model calls")
            return 0
        if args.command == "context":
            task = next(t for t in tasks if args.task in (None, t["id"]))
            record = {"phase": args.role}
            print(make_packet(ROOT, config, task, record, args.role))
            return 0
        with exclusive_run(RUNS) as lock_fd:
            if directory.exists() and not args.resume:
                raise ValueError("Run exists: inspect status and use --resume; never overwrite evidence")
            if args.resume and not (directory / "state.json").exists():
                raise ValueError("No saved run to resume")
            directory.mkdir(parents=True, exist_ok=True)
            engine = Engine(ROOT, directory, config, tasks, Codex(args.codex, config["agent_timeout"]), lock_fd)
            statuses = engine.execute(resume=args.resume)
            print(json.dumps(statuses, ensure_ascii=False, indent=2))
            return 0 if all(x == "COMPLETED" for x in statuses.values()) else 1
    except (KeyboardInterrupt, InterruptedError):
        print("WAITING: interrupted; state preserved", file=sys.stderr)
        return 130
    except (OSError, ValueError, RuntimeError, KeyError, TypeError, StopIteration) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
