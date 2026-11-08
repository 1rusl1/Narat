"""Context/state contracts using fixture data only."""

import copy
import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from orchestration.context import (PROJECT_START, PROJECT_END, make_packet, route_models, safe_path,
                                   selected_checks, validate, level)
from orchestration.storage import State, checkpoint

CONFIG = json.loads((Path(__file__).resolve().parents[1] / "orchestrator.config.json").read_text())


def task(tid="one"):
    return {"id": tid, "description": "Implement the requested change", "depends_on": [],
            "files": ["src/file.txt"], "write_files": ["src/file.txt"],
            "risk": "low", "complexity": "low", "constraints": ["Preserve existing behavior"],
            "acceptance_criteria": [{"id": "AC1", "description": "Expected behavior verified",
                                      "checks": ["diff-check"], "mode": "local"}]}


class ContextTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name).resolve()
        (self.root / "docs").mkdir()
        (self.root / "docs/handoff_status.md").write_text(
            PROJECT_START + "\nCurrent state\n" + PROJECT_END + "\nOld secret history " * 500)
        self.config = copy.deepcopy(CONFIG)
        self.task = task()
        self.state = State(self.root / "state.json", self.config, [self.task])
        self.record = self.state.data["tasks"]["one"]

    def tearDown(self):
        self.tmp.cleanup()

    def test_manifest_valid(self):
        validate(self.config, [self.task], self.root)

    def test_criteria_must_have_real_checks_and_evidence_mode(self):
        for field, value in (("checks", []), ("checks", ["unknown"]), ("mode", "live")):
            altered = copy.deepcopy(self.task)
            altered["acceptance_criteria"][0][field] = value
            with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                validate(self.config, [altered], self.root)

    def test_cyclic_unknown_and_duplicate_tasks_rejected(self):
        for tasks in ([task(), task()], [{**task(), "depends_on": ["one"]}],
                      [{**task(), "depends_on": ["missing"]}]):
            with self.assertRaises(ValueError):
                validate(self.config, tasks, self.root)

    def test_budget_zero_rejected(self):
        self.config["retry"]["max_developer_attempts"] = 0
        with self.assertRaises(ValueError):
            validate(self.config, [self.task], self.root)

    def test_config_cannot_skip_tests_or_delegate_failure_to_review(self):
        for key, value in (("before_review", ["static"]), ("on_failure", "continue_to_review")):
            config = copy.deepcopy(self.config)
            config["verification"][key] = value
            with self.assertRaises(ValueError):
                validate(config, [self.task], self.root)

    def test_paths_cannot_escape_or_modify_controller(self):
        for path in ("../escape", "/tmp/x", "a/../b", ".git/config", "AGENTS.md",
                     "docs/handoff_status.md", "tools/automation/orchestrator.config.json", ".env.prod"):
            with self.subTest(path=path), self.assertRaises(ValueError):
                safe_path(self.root, path, writable=True)
        (self.root / "link").symlink_to(self.root / "docs", target_is_directory=True)
        with self.assertRaises(ValueError):
            safe_path(self.root, "link/x", writable=True)

    def test_risk_can_only_increase_model_level(self):
        self.task.update(risk="high", complexity="low")
        self.assertEqual(level(self.task), "high")

    def test_ios_scope_cannot_drop_required_gates(self):
        self.task["write_files"] = ["ios/file.swift"]
        self.assertEqual(selected_checks(self.config, self.task), ["diff-check", "ios-tests", "simulator-smoke"])

    def test_minimal_packet_retains_all_criteria_and_excludes_history(self):
        self.task["acceptance_criteria"][0]["description"] = "Criterion " * 2000
        prompt = make_packet(self.root, self.config, self.task, self.record, "reviewer",
                             diff="difference " * 4000, diff_path="full.patch")
        self.assertNotIn("Old secret history", prompt)
        self.assertIn(self.task["acceptance_criteria"][0]["description"], prompt)
        self.assertIn('"diff_truncated": true', prompt)
        self.assertIn("full.patch", prompt)
        self.assertIn("Current state", prompt)

    def test_next_task_has_no_previous_transcript(self):
        self.record["transcript"] = "Previous private reasoning"
        next_task = task("two")
        prompt = make_packet(self.root, self.config, next_task, self.record, "developer")
        self.assertNotIn("Previous private reasoning", prompt)
        self.assertIn('"task_id": "two"', prompt)

    def test_missing_explicit_handoff_section_fails_closed(self):
        (self.root / "docs/handoff_status.md").write_text("Very long unstructured history")
        with self.assertRaises(ValueError):
            make_packet(self.root, self.config, self.task, self.record, "developer")

    def test_budget_is_persisted_before_call_and_survives_restart(self):
        self.assertTrue(self.state.reserve("one", "developer", 1))
        recovered = State(self.state.path, self.config, [self.task])
        self.assertFalse(recovered.reserve("one", "developer", 1))
        self.assertEqual(recovered.data["tasks"]["one"]["status"], "BLOCKED")

    def test_same_error_without_progress_blocks(self):
        self.assertTrue(self.state.failure("one", "tree1", ["error"], 2))
        self.assertTrue(self.state.failure("one", "tree2", ["error"], 2))
        self.assertFalse(self.state.failure("one", "tree2", ["error"], 2))

    def test_changed_manifest_cannot_reuse_state(self):
        with self.assertRaises(ValueError):
            State(self.state.path, self.config, [{**self.task, "description": "Changed contract"}])

    def test_checkpoint_retains_results_not_logs(self):
        self.record.update(summary={"summary": "Done", "decisions": ["Use existing adapter"]},
                           feedback=["Pending check"], checks={"unit": {"status": "PASS"}},
                           transcript="Long reasoning", raw_log="Verbose command log")
        compact = checkpoint(self.task, self.record)
        self.assertEqual(compact["acceptance_criteria"], self.task["acceptance_criteria"])
        self.assertEqual(compact["decisions"], ["Use existing adapter"])
        self.assertEqual(compact["unresolved"], ["Pending check"])
        self.assertNotIn("transcript", compact)
        self.assertNotIn("raw_log", compact)

    def test_route_models_supports_codex_and_agy_fallback_chain(self):
        dev_low = route_models(self.config["roles"]["developer"]["low"])
        self.assertEqual([(m["provider"], m["model"]) for m in dev_low], [
            ("codex", "gpt-6.1-sol"),
            ("agy", "gemini-4-argon-low"),
            ("agy", "gemini-3.8-flash-high"),
        ])
        rev_high = route_models(self.config["roles"]["reviewer"]["high"])
        self.assertEqual([(m["provider"], m["model"]) for m in rev_high], [
            ("codex", "gpt-6-astra"),
            ("agy", "gemini-4-argon-high"),
        ])
        with self.assertRaises(ValueError):
            route_models({"provider": "codex", "models": ["unknown:model"]})


if __name__ == "__main__":
    unittest.main()
