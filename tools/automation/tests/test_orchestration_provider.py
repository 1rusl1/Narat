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
from orchestration.provider import (Agy, Codex, MultiProvider, agy_transcript_events,
                                    classify, events, extract_json_object, resolve_agy_model, validate_reply)
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

    def test_optional_complex_finding_is_validated_without_breaking_old_replies(self):
        reply = {"task_id": "one", "fingerprint": "hash", "status": "FAIL", "summary": "needs expert",
                 "patch": "", "decisions": [], "findings": ["Ambiguous cross-component failure"], "criteria": []}
        self.assertEqual(validate_reply(reply, task(), "hash"), reply)
        reply["finding_complexity"] = "high"
        self.assertEqual(validate_reply(reply, task(), "hash")["finding_complexity"], "high")
        reply["finding_complexity"] = "unknown"
        with self.assertRaises(ValueError):
            validate_reply(reply, task(), "hash")

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

    def test_agy_provider_new_and_resumed_session_with_transcript(self):
        app_data = self.root / "agy-data"
        conv_id = "conv-fixture-123"
        tpath = app_data / "brain" / conv_id / ".system_generated/logs/transcript.jsonl"
        tpath.parent.mkdir(parents=True, exist_ok=True)
        cli = self.fake_cli(f'''import json, sys
from pathlib import Path
tpath = Path({str(tpath)!r})
reply = {{"task_id":"one", "fingerprint":"hash", "status":"PASS", "summary":"agy done", "patch":"", "decisions":[], "findings":[], "criteria":[]}}
if "new-conversation" in sys.argv:
    tpath.write_text(
        json.dumps({{"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","content":"p"}}) + "\\n" +
        json.dumps({{"step_index":1,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","input_tokens":100,"cache_read_tokens":20,"output_tokens":15,"content":json.dumps(reply)}}) + "\\n"
    )
    print(json.dumps({{"response":{{"newConversation":{{"conversationId":{conv_id!r}}}}}}}))
elif "send-message" in sys.argv:
    with tpath.open("a") as f:
        f.write(json.dumps({{"step_index":2,"source":"SYSTEM","type":"SYSTEM_MESSAGE","status":"DONE","content":"p2"}}) + "\\n")
        f.write(json.dumps({{"step_index":3,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","input_tokens":150,"cache_read_tokens":80,"output_tokens":18,"content":"```json\\n" + json.dumps(reply) + "\\n```"}}) + "\\n")
    print(json.dumps({{"response":{{"sendMessage":{{"recipientId":{conv_id!r}}}}}}}))
''')
        agy = Agy(cli, timeout=10, app_data_dir=app_data, poll_interval=0.01)
        multi = MultiProvider({"codex": Codex(cli), "agy": agy})
        res1 = multi.invoke(self.root, self.root / "agy-call-1", task(), "hash", "prompt 1", "gemini-4-argon-low", "medium", provider="agy")
        self.assertEqual(res1["status"], "PASS")
        self.assertEqual(res1["session_id"], conv_id)
        self.assertEqual(res1["usage"]["input_tokens"], 100)
        self.assertEqual(res1["usage"]["cached_input_tokens"], 20)
        self.assertEqual(res1["usage"]["output_tokens"], 15)
        res2 = multi.invoke(self.root, self.root / "agy-call-2", task(), "hash", "prompt 2", "gemini-4-argon-low", "medium", session=conv_id, provider="agy")
        self.assertEqual(res2["status"], "PASS")
        self.assertEqual(res2["session_id"], conv_id)
        self.assertEqual(res2["usage"]["input_tokens"], 150)
        self.assertEqual(res2["usage"]["cached_input_tokens"], 80)
        self.assertEqual(resolve_agy_model("gemini-4-argon", "high"), "gemini-4-argon-high")
        self.assertEqual(resolve_agy_model("gemini-4-argon-low", "high"), "gemini-4-argon-low")
        parsed_raw = extract_json_object('{"task_id": "one", "patch": "line1\nline2"}')
        self.assertEqual(parsed_raw["patch"], "line1\nline2")
        trunc_dir = self.root / "trunc"
        trunc_dir.mkdir()
        (trunc_dir / "transcript.jsonl").write_text(json.dumps({
            "step_index": 1, "type": "PLANNER_RESPONSE", "status": "DONE",
            "content": '{"patch": "short\n<truncated 100 bytes>\nend"}',
            "truncated_fields": ["content"], "input_tokens": 10, "output_tokens": 5, "cache_read_tokens": 2,
        }) + "\n")
        (trunc_dir / "transcript_full.jsonl").write_text(json.dumps({
            "step_index": 1, "type": "PLANNER_RESPONSE", "status": "DONE",
            "content": '{"patch": "full untruncated patch"}',
            "input_tokens": 10, "output_tokens": 5, "cache_read_tokens": 2,
        }) + "\n")
        ev = agy_transcript_events(trunc_dir / "transcript.jsonl")
        self.assertEqual(ev["answer_text"], '{"patch": "full untruncated patch"}')


if __name__ == "__main__":
    unittest.main()
