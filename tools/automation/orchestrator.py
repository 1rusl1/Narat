#!/usr/bin/env python3
"""Explicit task manifests → isolated CLI agents → verification → durable acceptance."""

import argparse
import json
from pathlib import Path
import re
import shutil
import signal
import sys

from doctor import ROOT, RUNS, BUNDLED_CODEX, exclusive_run
from orchestration.context import make_packet, validate
from orchestration.engine import Engine
from orchestration.metrics import compare_reports, metrics_report
from orchestration.provider import Agy, BUNDLED_AGY, Codex, MultiProvider
from orchestration.storage import State


def metrics(directory):
    return metrics_report(json.loads((directory / "state.json").read_text()))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("validate", "context", "run", "status", "metrics"))
    parser.add_argument("--manifest", type=Path)
    parser.add_argument("--config", type=Path, default=Path(__file__).with_name("orchestrator.config.json"))
    parser.add_argument("--run-id", default="queue")
    parser.add_argument("--compare-run-id", action="append", default=[], help="Compare metrics for matching quality contracts")
    parser.add_argument("--task")
    parser.add_argument("--role", choices=("developer", "reviewer", "qa", "acceptance"), default="developer")
    parser.add_argument("--resume", action="store_true")
    parser.add_argument("--codex", default=shutil.which("codex") or str(BUNDLED_CODEX))
    parser.add_argument("--agy", default=shutil.which("agy") or str(BUNDLED_AGY))
    args = parser.parse_args()
    if any(not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]{0,79}", rid) for rid in [args.run_id, *args.compare_run_id]):
        parser.error("Invalid run ID")
    if args.compare_run_id and args.command != "metrics":
        parser.error("--compare-run-id is only supported for metrics")
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
            report = metrics(directory)
            if args.compare_run_id:
                reports = {args.run_id: report}
                for rid in args.compare_run_id:
                    other = RUNS / ("orchestrator-" + rid)
                    if not other.resolve().is_relative_to(RUNS.resolve()):
                        raise ValueError("Comparison run path escapes evidence directory")
                    reports[rid] = metrics(other)
                report = compare_reports(reports)
            print(json.dumps(report, indent=2, ensure_ascii=False))
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
            provider = MultiProvider({
                "codex": Codex(args.codex, config["agent_timeout"]),
                "agy": Agy(args.agy, config["agent_timeout"]),
            })
            engine = Engine(ROOT, directory, config, tasks, provider, lock_fd)
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
