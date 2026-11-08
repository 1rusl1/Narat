"""Provider/process contracts with a fake executable, never a live model."""

import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import doctor
from ios_gate import unit_summary_ok
from orchestration.process import error_excerpt, run
from orchestration.provider import Codex, classify, events, validate_reply
from test_orchestration_context import task


class ProviderTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name).resolve()

    def tearDown(self):
        self.tmp.cleanup()

    def fake_cli(self, source):
        path = self.root / "fake-codex"
        path.write_text(f"#!{sys.executable}\n" + source)
        path.chmod(0o755)
        return path

    def test_real_subprocess_parses_structured_reply_and_measured_usage(self):
        cli = self.fake_cli('''import json, sys
from pathlib import Path
prompt = sys.stdin.read()
reply = {"task_id":"one", "fingerprint":"hash", "status":"PASS", "summary":"done", "patch":"", "decisions":[], "findings":[], "criteria":[]}
Path(sys.argv[sys.argv.index('--output-last-message')+1]).write_text(json.dumps(reply))
print(json.dumps({"type":"thread.started", "thread_id":"fixture-id"}))
print(json.dumps({"type":"turn.completed", "usage":{"input_tokens":12,"output_tokens":5,"cached_input_tokens":4}}))
''')
        result = Codex(cli).invoke(self.root, self.root / "call", task(), "hash", "minimal prompt", "configured-model", "low")
        self.assertEqual(result["status"], "PASS")
        self.assertEqual(result["session_id"], "fixture-id")
        self.assertEqual(result["usage"]["input_tokens"], 12)
        self.assertEqual(result["reply"]["task_id"], "one")
        self.assertTrue((self.root / "call/process.json").exists())

    def test_successful_exit_without_turn_or_answer_is_failure(self):
        cli = self.fake_cli("print('no JSON result')\n")
        result = Codex(cli).invoke(self.root, self.root / "call", task(), "hash", "prompt", "model", "low")
        self.assertEqual(result["status"], "FAIL")
        self.assertIsNone(result["usage"]["input_tokens"])

    def test_cli_rate_limit_classification(self):
        cli = self.fake_cli("import sys; print('usage limit reached', file=sys.stderr); sys.exit(1)\n")
        result = Codex(cli).invoke(self.root, self.root / "call", task(), "hash", "prompt", "model", "low")
        self.assertEqual(result["category"], "limit")
        self.assertIsNone(result["quota"])

    def test_explicit_resume_and_readonly_no_inherited_user_config(self):
        provider = Codex("codex")
        command = provider.command(self.root, self.root / "call", "model", "medium", session="uuid-one")
        self.assertEqual(command[command.index("resume") + 1], "uuid-one")
        self.assertNotIn("--last", command)
        self.assertIn("--ignore-user-config", command)
        self.assertEqual(command[command.index("--sandbox") + 1], "read-only")
        self.assertIn("features.apps=false", command)
        self.assertNotIn("--ephemeral", command)
        self.assertEqual(command[-1], "-")  # Prompt through stdin, never argv/process listing.

    def test_unreported_tokens_stay_unknown_and_quota_is_preserved(self):
        path = self.root / "events"
        path.write_text('\n'.join(json.dumps(x) for x in [
            {"type": "turn.completed", "usage": {"input_tokens": 17}},
            {"type": "account.rate_limits.updated", "rate_limits": {"reset_at": 123, "used_percent": 20}}]))
        result = events(path)
        self.assertEqual(result["usage"]["input_tokens"], 17)
        self.assertIsNone(result["usage"]["cached_input_tokens"])
        self.assertEqual(result["quota"]["reset_at"], 123)

    def test_partial_usage_across_turns_is_not_presented_as_exact(self):
        path = self.root / "events"
        path.write_text('\n'.join(json.dumps(x) for x in [
            {"type": "turn.completed", "usage": {"input_tokens": 17}}, {"type": "turn.completed"}]))
        self.assertIsNone(events(path)["usage"]["input_tokens"])

    def test_cumulative_usage_events_are_not_added(self):
        path = self.root / "events"
        path.write_text('\n'.join(json.dumps(x) for x in [
            {"type": "turn.completed", "usage": {"input_tokens": 17}},
            {"type": "turn.completed", "usage": {"input_tokens": 35}}]))
        self.assertEqual(events(path)["usage"]["input_tokens"], 35)

    def test_error_categories(self):
        for text, category in (("HTTP 401 unauthorized", "auth"), ("HTTP 429 too many requests", "limit"),
                               ("model not supported", "unavailable"), ("session not found", "session_lost"),
                               ("timeout", "timeout"), ("unexpected exit", "cli_error")):
            self.assertEqual(classify(text), category)

    def test_stale_response_is_rejected(self):
        reply = {"task_id": "two", "fingerprint": "old", "status": "PASS", "summary": "", "patch": "",
                 "decisions": [], "findings": [], "criteria": []}
        with self.assertRaises(ValueError):
            validate_reply(reply, task(), "new")

    def test_output_is_bounded_and_full_log_remains(self):
        directory = self.root / "logs"
        result = run([sys.executable, "-c", "import sys; print('OK'*100000); print('file.py:19: error fixture'); sys.exit(1)"],
                     self.root, directory, 10)
        excerpt = error_excerpt([Path(result["stdout"])], 200)
        self.assertLessEqual(len(excerpt), 200)
        self.assertIn("file.py:19: error fixture", excerpt)
        self.assertGreater(Path(result["stdout"]).stat().st_size, 100000)

    def test_timeout_stops_process_and_saves_result(self):
        result = run([sys.executable, "-c", "import time; time.sleep(30)"], self.root, self.root / "timeout", 0.05)
        self.assertEqual(result["error"], "timeout")
        self.assertLess(result["elapsed_seconds"], 10)
        self.assertEqual(json.loads((self.root / "timeout/process.json").read_text())["status"], "FAIL")

    def test_nested_check_inherits_real_lock_and_unrelated_runner_is_blocked(self):
        base = doctor.RUNS / ("lock-test-" + self.root.name)
        try:
            with doctor.exclusive_run(base) as fd:
                with patch.dict(os.environ, {"NARAT_AUTOMATION_LOCK_FD": str(fd)}):
                    with doctor.exclusive_run(base) as inherited:
                        self.assertEqual(inherited, fd)
                with self.assertRaises(RuntimeError):
                    with doctor.exclusive_run(base):
                        self.fail("A concurrent controller took the lock")
        finally:
            (base / ".doctor.lock").unlink(missing_ok=True)
            base.rmdir()

    def test_unrelated_lock_descriptor_does_not_bypass_lock(self):
        base = doctor.RUNS / ("lock-reject-" + self.root.name)
        try:
            with (self.root / "not-lock").open("w") as other:
                with patch.dict(os.environ, {"NARAT_AUTOMATION_LOCK_FD": str(other.fileno())}):
                    with doctor.exclusive_run(base):
                        with self.assertRaises(RuntimeError):
                            with doctor.exclusive_run(base):
                                self.fail("Unrelated descriptor bypassed a held lock")
        finally:
            (base / ".doctor.lock").unlink(missing_ok=True)
            base.rmdir()

    def test_ios_unit_gate_rejects_zero_skipped_or_failed_tests(self):
        good = {"result": "Passed", "totalTestCount": 3, "passedTests": 3, "failedTests": 0, "skippedTests": 0}
        self.assertTrue(unit_summary_ok(good))
        for altered in ({"totalTestCount": 0, "passedTests": 0}, {"skippedTests": 1}, {"failedTests": 1}):
            self.assertFalse(unit_summary_ok({**good, **altered}))


if __name__ == "__main__":
    unittest.main()
