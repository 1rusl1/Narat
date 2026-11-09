#!/usr/bin/env python3
"""Run existing iOS gate and require every XCTest source method to execute.

Controller-owned wrapper: catches missing target membership as well as skips.
Behavioral adequacy remains the independent Reviewer/QA's responsibility.
"""

import json
import re
import sys

from doctor import ROOT, RUNS, write_json
import ios_gate


def coverage(log, summary, sources):
    expected = set()
    for path, source in sources:
        for method in re.findall(r"\bfunc\s+(test\w+)\s*\(", source):
            expected.add((path.stem, method))
    passed = set(re.findall(
        r"Test Case '-\[PlantsTests\.(\w+) (test\w+)\]' passed", log))
    missing = sorted(expected - passed)
    return {
        "status": "PASS" if (ios_gate.unit_summary_ok(summary)
                              and summary["totalTestCount"] >= 36
                              and len(expected) >= 33 and not missing) else "FAIL",
        "expected_xctest_methods": len(expected),
        "passed_xctest_methods": len(expected & passed),
        "total_tests": summary.get("totalTestCount"),
        "missing_methods": missing,
        "mode": "local_fixture_transport_not_live",
    }


def main():
    result = ios_gate.main()
    if result:
        return result
    run_id = sys.argv[sys.argv.index("--run-id") + 1]
    directory = RUNS / run_id
    summary = json.loads((directory / "summary.json").read_text())
    unit = json.loads((directory / "unit-result.stdout.log").read_text())
    sources = [(path, path.read_text()) for path in (ROOT / "ios/PlantsTests").glob("*.swift")]
    check = coverage((directory / "unit.stdout.log").read_text(), unit, sources)
    write_json(directory / "source-test-coverage.json", check)
    summary["checks"].append({"name": "source-test-coverage", **check})
    if check["status"] != "PASS":
        summary["status"] = "FAIL"
    write_json(directory / "summary.json", summary)
    print(json.dumps(check, ensure_ascii=False), flush=True)
    return 0 if check["status"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
