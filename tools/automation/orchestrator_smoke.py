#!/usr/bin/env python3
"""Three tiny read-only CLI turns: new task, explicit resume, isolated next task.

Connectivity/session checks only, never product or task acceptance.
"""

import argparse
import json
import shutil
import signal

from doctor import BUNDLED_CODEX, ROOT, RUNS, exclusive_run, new_run_path
from orchestration.provider import Agy, BUNDLED_AGY, Codex, MultiProvider
from orchestration.storage import atomic_json


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--provider", choices=("codex", "agy"), default="codex")
    parser.add_argument("--model", default="gpt-6.1-sol")
    parser.add_argument("--codex", default=shutil.which("codex") or str(BUNDLED_CODEX))
    parser.add_argument("--agy", default=shutil.which("agy") or str(BUNDLED_AGY))
    args = parser.parse_args()
    def interrupted(signum, frame):
        raise InterruptedError(f"signal {signum}")
    signal.signal(signal.SIGTERM, interrupted)
    with exclusive_run(RUNS):
        directory = new_run_path(RUNS, args.run_id)
        report = {"status": "RUNNING", "scope": "CLI transport/session smoke only", "calls": []}
        atomic_json(directory / "summary.json", report)
        provider = MultiProvider({"codex": Codex(args.codex, 180), "agy": Agy(args.agy, 180)}, default=args.provider)
        session = None
        try:
            for index, tid in enumerate(("smoke-one", "smoke-one", "smoke-two")):
                reply = {"task_id": tid, "fingerprint": "connectivity-only", "status": "PASS",
                         "summary": "CLI smoke only", "patch": "", "decisions": [], "findings": [], "criteria": [],
                         "finding_complexity": "low"}
                prompt = ("Only a CLI connectivity/session smoke, not a development stage. "
                          "Use no tools, do not read or change files, update handoff/tasks or run Git. "
                          "Return exactly this JSON: " + json.dumps(reply))
                result = provider.invoke(ROOT, directory / f"call-{index + 1}", {"id": tid},
                                         "connectivity-only", prompt, args.model, "low",
                                         session=session if index == 1 else None, provider=args.provider)
                item = {k: result.get(k) for k in ("status", "session_id", "usage", "quota", "elapsed_seconds", "category", "error")}
                item.update(task_id=tid, model=args.model, provider=args.provider, prompt_bytes=len(prompt.encode()))
                # Connectivity must not perform tool/repository work.
                if args.provider == "codex":
                    with (directory / f"call-{index + 1}/stdout.log").open() as stream:
                        for line in stream:
                            try:
                                event = json.loads(line)
                            except ValueError:
                                continue
                            if event.get("item", {}).get("type") in ("command_execution", "file_change", "mcp_tool_call", "web_search"):
                                item["status"] = "FAIL"
                                item["error"] = "Smoke invoked tools"
                report["calls"].append(item)
                if item["status"] != "PASS" or not result.get("session_id") or result["reply"] != reply:
                    report["status"] = "FAIL"
                    break
                if index == 0:
                    session = result["session_id"]
                elif index == 1 and result["session_id"] != session:
                    report["status"] = "FAIL"
                    break
                elif index == 2:
                    report["status"] = "PASS" if result["session_id"] != session else "FAIL"
                atomic_json(directory / "summary.json", report)
        except (KeyboardInterrupt, InterruptedError, OSError, ValueError) as error:
            report.update(status="FAIL", error=str(error))
        atomic_json(directory / "summary.json", report)
        print(json.dumps(report, ensure_ascii=False, indent=2))
        return 0 if report["status"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
