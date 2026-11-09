"""Comparable acceptance cost on fixtures; no pricing or live quota inference."""

import copy
from contextlib import redirect_stdout
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from orchestration.metrics import compare_reports, metrics_report, token_totals
import orchestrator


def call(number, scope="per_turn", tokens=100, **overrides):
    return {"id": str(number), "agent": "developer", "model": "fixture", "provider": "codex",
            "session_id": "session-one", "status": "PASS", "retry": number - 1,
            "prompt_bytes": 400, "estimated_prompt_tokens": 100, "elapsed_seconds": 2,
            "input_tokens": tokens, "output_tokens": tokens // 5, "cached_input_tokens": tokens // 2,
            "usage_scope": scope, **overrides}


def record(status="COMPLETED", calls=None, contract="same-quality"):
    return {"status": status, "quality_contract": contract, "calls": calls or [], "checks": {},
            "check_runs": [{"elapsed_seconds": 3}, {"elapsed_seconds": 4}]}


class MetricsTests(unittest.TestCase):
    def test_retries_fallbacks_and_failed_tasks_are_charged_per_accepted_task(self):
        data = {"tasks": {"accepted": record(calls=[call(1), call(2, provider="agy")]),
                          "blocked": record("BLOCKED", [call(1, status="FAIL")])}}
        report = metrics_report(data)
        overall = report["overall"]
        self.assertEqual(overall["accepted_tasks"], 1)
        self.assertEqual(overall["total_including_retries"]["calls"], 3)
        self.assertEqual(overall["per_accepted_task"]["input_tokens"], 300)
        self.assertEqual(overall["per_accepted_task"]["retries"], 1)
        self.assertEqual(overall["per_accepted_task"]["check_elapsed_seconds"], 14)
        self.assertEqual(report["tasks"]["accepted"]["per_accepted_task"]["input_tokens"], 200)

    def test_cumulative_resume_is_counted_once_across_sessions_and_models(self):
        calls = [call(1, "session_cumulative"), call(2, "session_cumulative", tokens=200),
                 call(3, "session_cumulative", tokens=50, session_id="new-session")]
        self.assertEqual(token_totals(calls), {"input_tokens": 250, "output_tokens": 50, "cached_input_tokens": 125})
        calls.append(call(4, "session_cumulative", tokens=30, model="other-model"))
        self.assertEqual(token_totals(calls)["input_tokens"], 280)

    def test_unknown_scope_or_partial_tokens_are_null_not_zero(self):
        calls = [call(1), call(2, "CLI-reported counters; per-turn/session scope not guaranteed")]
        self.assertTrue(all(value is None for value in token_totals(calls).values()))
        calls = [call(1), call(2, output_tokens=None)]
        self.assertEqual(token_totals(calls)["input_tokens"], 200)
        self.assertIsNone(token_totals(calls)["output_tokens"])

    def test_counter_reset_is_unknown(self):
        self.assertIsNone(token_totals([call(1, "session_cumulative"),
                                      call(2, "session_cumulative", tokens=50)])["input_tokens"])

    def test_zero_acceptance_never_reports_zero_cost(self):
        overall = metrics_report({"tasks": {"failed": record("BLOCKED", [call(1)])}})["overall"]
        self.assertEqual(overall["accepted_tasks"], 0)
        self.assertTrue(all(value is None for value in overall["per_accepted_task"].values()))

    def test_different_quality_contracts_remain_separate(self):
        report = metrics_report({"tasks": {"a": record(calls=[call(1)]),
            "b": record(calls=[call(1)], contract="live-contract")}})
        self.assertEqual(set(report["quality_cohorts"]), {"same-quality", "live-contract"})
        self.assertTrue(all(c["accepted_tasks"] == 1 for c in report["quality_cohorts"].values()))

    def test_metrics_projection_is_idempotent_and_keeps_unknown_raw_usage(self):
        data = {"tasks": {"a": record(calls=[call(1, input_tokens=None)])}}
        before = copy.deepcopy(data)
        report = metrics_report(data)
        self.assertEqual(report, metrics_report(data))
        self.assertEqual(data, before)
        self.assertEqual(report["overall"]["unknown_or_ambiguous_usage_calls"], 1)
        self.assertIsNone(next(iter(report["groups"].values()))["reported_tokens_by_call"][0]["input_tokens"])

    def test_comparison_only_pairs_matching_quality_contracts(self):
        old = metrics_report({"tasks": {"a": record(calls=[call(1), call(2), call(3)])}})
        new = metrics_report({"tasks": {"b": record(calls=[call(1), call(2)]),
            "different": record(calls=[call(1)], contract="unrelated")}})
        comparison = compare_reports({"old": old, "new": new})
        self.assertEqual(set(comparison["matching_quality_contracts"]), {"same-quality"})
        pair = comparison["matching_quality_contracts"]["same-quality"]
        self.assertEqual(pair["old"]["per_accepted_task"]["calls"], 3)
        self.assertEqual(pair["new"]["per_accepted_task"]["calls"], 2)

    def test_interrupted_unknown_time_and_legacy_check_history_are_not_zero(self):
        data = record(calls=[call(1, elapsed_seconds=None)])
        data.pop("check_runs")
        data["checks"] = {"unit": {"elapsed_seconds": 2}}
        report = metrics_report({"tasks": {"a": data}})["overall"]
        self.assertIsNone(report["per_accepted_task"]["agent_elapsed_seconds"])
        self.assertIsNone(report["per_accepted_task"]["check_elapsed_seconds"])
        self.assertEqual(report["unknown_elapsed_calls"], 1)

    def test_metrics_cli_compares_saved_runs_without_models(self):
        with tempfile.TemporaryDirectory() as tmp:
            runs = Path(tmp)
            for name, calls in (("old", [call(1), call(2), call(3)]), ("new", [call(1), call(2)])):
                directory = runs / ("orchestrator-" + name)
                directory.mkdir()
                (directory / "state.json").write_text(json.dumps({"tasks": {"one": record(calls=calls)}}))
            output = io.StringIO()
            with patch.object(orchestrator, "RUNS", runs), patch.object(sys, "argv", [
                    "orchestrator.py", "metrics", "--run-id", "old", "--compare-run-id", "new"]), redirect_stdout(output):
                self.assertEqual(orchestrator.main(), 0)
            report = json.loads(output.getvalue())
            self.assertEqual(set(report["matching_quality_contracts"]["same-quality"]), {"old", "new"})


if __name__ == "__main__":
    unittest.main()
