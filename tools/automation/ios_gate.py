#!/usr/bin/env python3
"""Reuse doctor's isolated build/welcome gate, then run the existing PlantsTests target."""

import argparse
import json
import signal

from doctor import (Doctor, RUNS, SIMULATOR, check_ios, exclusive_run, ios_command,
                    new_run_path)


def unit_summary_ok(summary):
    return (summary.get("result") == "Passed" and summary.get("totalTestCount", 0) > 0
            and summary.get("passedTests") == summary.get("totalTestCount")
            and summary.get("failedTests") == 0 and summary.get("skippedTests") == 0)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--simulator", default=SIMULATOR)
    args = parser.parse_args()
    args.build_timeout, args.test_timeout = 1200, 300
    def interrupted(signum, frame):
        raise InterruptedError(f"signal {signum}")
    signal.signal(signal.SIGTERM, interrupted)
    with exclusive_run(RUNS):
        runner = Doctor(new_run_path(RUNS, args.run_id))
        try:
            check_ios(runner, args)
            if not any(x["name"] == "welcome-acceptance" and x["status"] == "PASS" for x in runner.report["checks"]):
                runner.add("unit", "FAIL", reason="Build/welcome gate did not pass")
                return runner.finish(True)
            result = runner.run_dir / "unit.xcresult"
            check = runner.command("unit", [*ios_command(args), "-only-testing:PlantsTests",
                                    "-resultBundlePath", str(result), "test-without-building"], 600)
            if check["status"] == "PASS":
                check = runner.command("unit-result", ["xcrun", "xcresulttool", "get", "test-results",
                                        "summary", "--path", str(result), "--compact"])
                valid = check["status"] == "PASS" and unit_summary_ok(json.loads(runner.read_stdout(check)))
                runner.add("unit-acceptance", "PASS" if valid else "FAIL", mode="local")
            return runner.finish(True)
        except (KeyboardInterrupt, InterruptedError):
            runner.add("unit", "FAIL", reason="interrupted")
            runner.finish(False)
            return 130
        except (OSError, ValueError, KeyError) as error:
            runner.add("unit", "FAIL", reason=str(error))
            return runner.finish(False)


if __name__ == "__main__":
    raise SystemExit(main())
