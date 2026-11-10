"""End-to-end controller tests: real subprocess checks and temporary Git repositories.

Models are scripted fixtures; no paid/live calls or Simulator acceptance are implied.
"""

import copy
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from orchestration.context import PROJECT_START, PROJECT_END, SUMMARY_START, SUMMARY_END, validate
from orchestration.engine import Engine
from orchestration.repository import apply_patch, contents, diff, fingerprint, git
from orchestration.storage import digest
from test_orchestration_context import CONFIG, task


class FakeProvider:
    def __init__(self, responses=None):
        self.responses = list(responses or [])
        self.calls = []

    def invoke(self, root, directory, task, fingerprint, prompt, model, effort, session=None, ephemeral=False, provider="codex"):
        role = json.loads(prompt.split("\n", 1)[1].split("\nFull task diff:", 1)[0])["role"]
        call = {"role": role, "task": task["id"], "prompt": prompt, "session": session,
                "model": model, "provider": provider, "effort": effort}
        self.calls.append(call)
        reply = {"task_id": task["id"], "fingerprint": fingerprint, "status": "PASS", "summary": "Verified fixture",
                 "patch": "", "decisions": ["Reuse existing behavior"], "findings": [],
                 "criteria": [{"id": c["id"], "status": "PASS", "evidence": c["checks"]}
                              for c in task["acceptance_criteria"]]}
        result = {"status": "PASS", "reply": reply, "session_id": session or f"session-{len(self.calls)}",
                  "usage": {"input_tokens": 100, "output_tokens": 20, "cached_input_tokens": 50}, "elapsed_seconds": 0.1}
        if self.responses:
            response = self.responses.pop(0)
            if isinstance(response, BaseException):
                raise response
            if callable(response):
                response(result, call, root)
            else:
                result.update(response)
        return result


def patch_response(before="before\n", after="after\n", path="src/file.txt"):
    def response(result, call, root):
        result["reply"]["patch"] = diff({path: before}, {path: after})
    return response


def fail_response(message="Wrong result"):
    def response(result, call, root):
        result["reply"].update(status="FAIL", findings=[message])
    return response


class EngineTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.base = Path(self.tmp.name).resolve()
        self.root = self.base / "repo"
        self.root.mkdir()
        git(self.root, "init", "-b", "main")
        git(self.root, "config", "user.name", "Fixture")
        git(self.root, "config", "user.email", "fixture@example.invalid")
        git(self.root, "config", "commit.gpgsign", "false")
        (self.root / "docs").mkdir()
        (self.root / "docs/handoff_status.md").write_text(
            PROJECT_START + "\nFixture project state\n" + PROJECT_END + "\n" +
            SUMMARY_START + "\nPrevious summary\n" + SUMMARY_END + "\nHistory PRIVATE_PAST_REASONING\n")
        (self.root / "src").mkdir()
        (self.root / "src/file.txt").write_text("before\n")
        (self.root / ".gitignore").write_text(".runs/\n")
        git(self.root, "add", ".")
        git(self.root, "commit", "-m", "baseline")
        self.remote = self.base / "remote.git"
        subprocess.run(["git", "init", "--bare", str(self.remote)], check=True, capture_output=True)
        git(self.root, "remote", "add", "origin", str(self.remote))
        self.config = copy.deepcopy(CONFIG)
        self.config["acceptance"]["combined_levels"] = []  # Keep coverage of the split path below.
        self.config["checks"] = {
            "diff-check": {"argv": ["git", "diff", "--check"], "stage": "static", "mode": "local", "timeout": 10},
            "unit": {"argv": [sys.executable, "-c", "print('fixture tests PASS')"], "stage": "unit", "mode": "fixture", "timeout": 10},
            "ui": {"argv": [sys.executable, "-c", "print('fixture UI PASS')"], "stage": "qa", "mode": "fixture", "timeout": 10}}
        self.config["scope_checks"] = {}
        self.task = task()
        self.task["acceptance_criteria"] = [{"id": "AC1", "description": "Fixture unit proof", "mode": "fixture", "checks": ["unit"]},
                                            {"id": "AC2", "description": "Fixture UI proof", "mode": "fixture", "checks": ["ui"]}]
        self.directory = self.root / ".runs/test"

    def tearDown(self):
        self.tmp.cleanup()

    def engine(self, provider, tasks=None):
        tasks = tasks or [self.task]
        validate(self.config, tasks, self.root)
        return Engine(self.root, self.directory, self.config, tasks, provider)

    def test_happy_path_checks_review_qa_commit_push_and_no_duplicate_resume(self):
        provider = FakeProvider([patch_response()])
        engine = self.engine(provider)
        self.assertEqual(engine.execute(), {"one": "COMPLETED"})
        self.assertEqual([c["role"] for c in provider.calls], ["developer", "reviewer", "qa"])
        self.assertEqual((self.root / "src/file.txt").read_text(), "after\n")
        self.assertEqual(git(self.root, "status", "--porcelain"), b"")
        self.assertEqual(git(self.root, "rev-parse", "HEAD").strip(),
                         git(self.root, "ls-remote", "origin", "refs/heads/main").split()[0])
        reviewer = provider.calls[1]["prompt"]
        self.assertIn("+after", reviewer)
        self.assertIn("Fixture unit proof", reviewer)
        self.assertNotIn("PRIVATE_PAST_REASONING", reviewer)
        self.assertNotIn("fixture tests PASS", reviewer)  # Successful full stdout is never included.
        replay = FakeProvider()
        recovered = self.engine(replay)
        self.assertEqual(recovered.execute(resume=True), {"one": "COMPLETED"})
        self.assertEqual(replay.calls, [])
        metrics = [json.loads(x) for x in (self.directory / "metrics.jsonl").read_text().splitlines()]
        self.assertEqual(len(metrics), 3)
        self.assertTrue(all(m["task_status"] == "COMPLETED" for m in metrics))
        self.assertEqual(sum(m["input_tokens"] for m in metrics), 300)

    def test_failed_build_blocks_reviewer_and_stops_no_progress(self):
        self.config["checks"]["unit"]["argv"] = [sys.executable, "-c", "import sys; print('file.swift:10: error broken'); sys.exit(1)"]
        provider = FakeProvider()
        engine = self.engine(provider)
        self.assertEqual(engine.execute()["one"], "BLOCKED")
        self.assertEqual([c["role"] for c in provider.calls], ["developer", "developer"])
        self.assertIn("file.swift:10: error broken", provider.calls[-1]["prompt"])
        self.assertEqual(engine.state.data["tasks"]["one"]["counts"].get("reviewer", 0), 0)

    def test_budget_stops_changing_failures(self):
        provider = FakeProvider([fail_response("one"), fail_response("two"), fail_response("three")])
        engine = self.engine(provider)
        self.assertEqual(engine.execute()["one"], "BLOCKED")
        self.assertEqual(len(provider.calls), 3)
        self.assertIn("budget exhausted", engine.state.data["tasks"]["one"]["reason"])

    def test_qa_cannot_accept_missing_evidence(self):
        self.config["retry"]["max_qa_cycles"] = 2
        def no_evidence(result, call, root):
            result["reply"]["criteria"] = []
        provider = FakeProvider([{}, {}, no_evidence, {}, {}, no_evidence])
        engine = self.engine(provider)
        self.assertEqual(engine.execute()["one"], "BLOCKED")
        self.assertFalse((self.root / "docs/validation/automation/tasks/one.md").exists())

    def test_patch_outside_scope_never_applied(self):
        provider = FakeProvider([patch_response(path="docs/handoff_status.md"), patch_response(path="docs/handoff_status.md")])
        engine = self.engine(provider)
        self.assertEqual(engine.execute()["one"], "BLOCKED")
        self.assertEqual(git(self.root, "status", "--porcelain"), b"")

    def test_limit_waits_without_automatic_retries(self):
        self.config["roles"]["developer"]["low"]["models"] = ["codex:gpt-6.1-sol"]
        provider = FakeProvider([{"status": "FAIL", "category": "limit", "error": "usage limit"}])
        engine = self.engine(provider)
        self.assertEqual(engine.execute()["one"], "WAITING")
        self.assertEqual(len(provider.calls), 1)
        self.assertEqual(engine.state.data["tasks"]["one"]["calls"][0]["quota"], None)

    def test_default_config_falls_back_from_codex_to_agy_on_limit(self):
        provider = FakeProvider([
            {"status": "FAIL", "category": "limit", "error": "codex usage limit"},
            {},
            {"status": "FAIL", "category": "limit", "error": "codex reviewer limit"},
            {},
            {},
        ])
        engine = self.engine(provider)
        self.assertEqual(engine.execute()["one"], "COMPLETED")
        self.assertEqual([(c["role"], c["provider"], c["model"]) for c in provider.calls], [
            ("developer", "codex", "gpt-6.1-sol"),
            ("developer", "agy", "gemini-3.8-flash-high"),
            ("reviewer", "codex", "gpt-6.1-sol"),
            ("reviewer", "agy", "gemini-3.8-flash-high"),
            ("qa", "codex", "gpt-6.1-sol"),
        ])
        self.assertIsNone(provider.calls[1]["session"])
        self.assertIsNone(provider.calls[3]["session"])

    def test_explicit_allowed_fallback_gets_new_session(self):
        self.config["roles"]["developer"]["low"]["models"] = ["primary", "approved-alternative"]
        provider = FakeProvider([{"status": "FAIL", "category": "unavailable", "error": "model unavailable"}])
        engine = self.engine(provider)
        self.assertEqual(engine.execute()["one"], "COMPLETED")
        self.assertEqual([c["model"] for c in provider.calls[:2]], ["primary", "approved-alternative"])
        self.assertIsNone(provider.calls[1]["session"])

    def test_auth_error_does_not_fallback(self):
        self.config["roles"]["developer"]["low"]["models"] = ["primary", "alternative"]
        provider = FakeProvider([{"status": "FAIL", "category": "auth", "error": "authentication failed"}])
        engine = self.engine(provider)
        self.assertEqual(engine.execute()["one"], "WAITING")
        self.assertEqual(len(provider.calls), 1)

    def test_interruption_persists_budget_and_resumes_fresh(self):
        engine = self.engine(FakeProvider([InterruptedError("fixture signal")]))
        with self.assertRaises(InterruptedError):
            engine.execute()
        record = engine.state.data["tasks"]["one"]
        self.assertEqual(record["status"], "WAITING")
        self.assertEqual(record["counts"]["developer"], 1)
        provider = FakeProvider()
        recovered = self.engine(provider)
        self.assertEqual(recovered.execute(resume=True)["one"], "COMPLETED")
        self.assertIsNone(provider.calls[0]["session"])
        self.assertEqual(recovered.state.data["tasks"]["one"]["counts"]["developer"], 2)

    def test_changed_source_after_interruption_is_blocked(self):
        engine = self.engine(FakeProvider([InterruptedError()]))
        with self.assertRaises(InterruptedError):
            engine.execute()
        (self.root / "src/file.txt").write_text("external edit\n")
        provider = FakeProvider()
        self.assertEqual(self.engine(provider).execute(resume=True)["one"], "BLOCKED")
        self.assertEqual(provider.calls, [])

    def test_failed_task_does_not_block_independent_clean_task(self):
        second = task("two")
        second["write_files"] = []
        provider = FakeProvider([fail_response(), fail_response()])
        engine = self.engine(provider, [self.task, second])
        self.assertEqual(engine.execute(), {"one": "BLOCKED", "two": "COMPLETED"})
        self.assertIsNone(next(c for c in provider.calls if c["task"] == "two")["session"])

    def test_blocked_dependency_never_runs(self):
        second = {**task("two"), "depends_on": ["one"]}
        provider = FakeProvider([fail_response(), fail_response()])
        engine = self.engine(provider, [second, self.task])
        self.assertEqual(engine.execute(), {"two": "PENDING", "one": "BLOCKED"})
        self.assertTrue(all(c["task"] == "one" for c in provider.calls))

    def test_uncommitted_blocked_work_prevents_next_task(self):
        def blocked(result, call, root):
            result["reply"].update(status="BLOCKED", findings=["Cannot verify"])
        provider = FakeProvider([patch_response(), blocked])
        engine = self.engine(provider, [self.task, task("two")])
        self.assertEqual(engine.execute(), {"one": "BLOCKED", "two": "WAITING"})
        self.assertEqual((self.root / "src/file.txt").read_text(), "after\n")

    def test_resume_reuses_only_same_role_and_re_review_uses_delta(self):
        provider = FakeProvider([patch_response(), fail_response("fix after"),
                                 patch_response("after\n", "fixed\n"), {}, {}])
        engine = self.engine(provider)
        self.assertEqual(engine.execute()["one"], "COMPLETED")
        self.assertEqual(provider.calls[2]["session"], "session-1")
        self.assertEqual(provider.calls[3]["session"], "session-2")
        self.assertIn("-after", provider.calls[3]["prompt"])
        self.assertIn("+fixed", provider.calls[3]["prompt"])
        self.assertNotIn("-before", provider.calls[3]["prompt"])
        self.assertIn("fix after", provider.calls[3]["prompt"])

    def test_compaction_threshold_restarts_without_extra_model_call(self):
        self.config["sessions"]["max_turns"] = 1
        provider = FakeProvider([fail_response("first attempt")])
        engine = self.engine(provider)
        self.assertEqual(engine.execute()["one"], "COMPLETED")
        self.assertEqual(len(provider.calls), 4)
        self.assertIsNone(provider.calls[1]["session"])
        self.assertIn("first attempt", provider.calls[1]["prompt"])
        compacted = engine.state.data["tasks"]["one"]["compactions"]
        self.assertEqual(compacted[0]["model_calls"], 0)
        self.assertTrue(list((self.directory / "one").glob("checkpoint-*.json")))

    def test_unchanged_check_success_is_not_repeated(self):
        provider = FakeProvider([{}, fail_response("review finding"), {}, {}, {}])
        engine = self.engine(provider)
        self.assertEqual(engine.execute()["one"], "COMPLETED")
        self.assertEqual(engine.state.data["tasks"]["one"]["check_sequence"], 3)

    def test_push_failure_waits_and_resume_does_not_reinvoke_models(self):
        git(self.root, "remote", "set-url", "origin", str(self.base / "missing.git"))
        provider = FakeProvider()
        engine = self.engine(provider)
        self.assertEqual(engine.execute()["one"], "WAITING")
        self.assertIn("Publication failed", engine.state.data["tasks"]["one"]["reason"])
        git(self.root, "remote", "set-url", "origin", str(self.remote))
        retry = FakeProvider()
        recovered = self.engine(retry)
        self.assertEqual(recovered.execute(resume=True)["one"], "COMPLETED")
        self.assertEqual(retry.calls, [])

    def test_read_only_agent_changes_block_acceptance(self):
        def external_write(result, call, root):
            (root / "src/file.txt").write_text("unexpected\n")
        provider = FakeProvider([external_write])
        engine = self.engine(provider)
        self.assertEqual(engine.execute()["one"], "BLOCKED")
        self.assertEqual(len(provider.calls), 1)

    def test_check_mutation_invalidates_all_evidence(self):
        self.config["checks"]["unit"]["argv"] = [sys.executable, "-c", "from pathlib import Path; Path('src/file.txt').write_text('changed')"]
        provider = FakeProvider()
        engine = self.engine(provider)
        self.assertEqual(engine.execute()["one"], "BLOCKED")
        self.assertEqual(len(provider.calls), 1)

    def test_new_and_deleted_files_are_in_diff_and_apply(self):
        text = diff({"src/new.txt": None}, {"src/new.txt": "new\n"})
        apply_patch(self.root, text, ["src/new.txt"])
        self.assertEqual((self.root / "src/new.txt").read_text(), "new\n")
        apply_patch(self.root, diff({"src/new.txt": "new\n"}, {"src/new.txt": None}), ["src/new.txt"])
        self.assertFalse((self.root / "src/new.txt").exists())

    def test_multifile_patch_without_diff_git_headers_applies_under_recount(self):
        (self.root / "src/second.txt").write_text("alpha\nbeta\n")
        raw_patch = (
            "--- a/src/file.txt\n"
            "+++ b/src/file.txt\n"
            "@@ -1,1 +1,1 @@\n"
            "-before\n"
            "+after\n"
            "--- a/src/second.txt\n"
            "+++ b/src/second.txt\n"
            "@@ -1,2 +1,2 @@\n"
            " alpha\n"
            "-beta\n"
            "+gamma\n"
        )
        changed = apply_patch(self.root, raw_patch, ["src/file.txt", "src/second.txt"])
        self.assertEqual(changed, ["src/file.txt", "src/second.txt"])
        self.assertEqual((self.root / "src/file.txt").read_text(), "after\n")
        self.assertEqual((self.root / "src/second.txt").read_text(), "alpha\ngamma\n")

    def test_already_reported_task_does_not_call_models(self):
        report = self.root / "docs/validation/automation/tasks/one.md"
        report.parent.mkdir(parents=True)
        report.write_text("Prior accepted task")
        git(self.root, "add", ".")
        git(self.root, "commit", "-m", "previous task")
        provider = FakeProvider()
        self.assertEqual(self.engine(provider).execute()["one"], "BLOCKED")
        self.assertEqual(provider.calls, [])

    def test_readonly_task_checks_precede_models_and_skip_developer(self):
        self.task["write_files"] = []
        def inspect_evidence(result, call, root):
            self.assertIn('"status": "PASS"', call["prompt"])
            self.assertIn("check-2-unit/stdout.log", call["prompt"])
            self.assertTrue((self.directory / "one/check-2-unit/stdout.log").exists())
        provider = FakeProvider([inspect_evidence])
        self.assertEqual(self.engine(provider).execute()["one"], "COMPLETED")
        self.assertEqual([c["role"] for c in provider.calls], ["reviewer", "qa"])

    def test_readonly_failed_checks_never_invoke_review(self):
        self.task["write_files"] = []
        self.config["checks"]["unit"]["argv"] = [sys.executable, "-c", "raise SystemExit(1)"]
        provider = FakeProvider([fail_response("Cannot repair without writable files")])
        engine = self.engine(provider)
        self.assertEqual(engine.execute()["one"], "BLOCKED")
        self.assertFalse(any(c["role"] in ("reviewer", "qa") for c in provider.calls))
        self.assertEqual(provider.calls, [])

    def test_developer_repairs_failing_tests_before_first_review(self):
        self.config["checks"]["unit"]["argv"] = [sys.executable, "-c",
            "from pathlib import Path; import sys; sys.exit(0 if Path('src/file.txt').read_text() == 'fixed\\n' else 1)"]
        provider = FakeProvider([{}, patch_response("before\n", "fixed\n")])
        engine = self.engine(provider)
        self.assertEqual(engine.execute()["one"], "COMPLETED")
        self.assertEqual([c["role"] for c in provider.calls], ["developer", "developer", "reviewer", "qa"])
        self.assertIn('"status": "FAIL"', provider.calls[1]["prompt"])
        self.assertIn('"status": "PASS"', provider.calls[2]["prompt"])
        self.assertEqual(engine.state.data["tasks"]["one"]["checks"]["unit"]["owner"], "developer")

    def test_contradictory_pass_does_not_trigger_developer_repairs(self):
        self.task["write_files"] = []
        def conflicting(result, call, root):
            result["reply"]["findings"] = ["Informational note in the wrong field"]
        provider = FakeProvider([conflicting])
        self.assertEqual(self.engine(provider).execute()["one"], "WAITING")
        self.assertEqual([c["role"] for c in provider.calls], ["reviewer"])

    def test_crash_after_apply_recovers_without_second_developer(self):
        provider = FakeProvider([patch_response()])
        engine = self.engine(provider)
        original = apply_patch
        def apply_and_crash(root, text, allowed):
            original(root, text, allowed)
            raise InterruptedError("after patch write")
        with patch("orchestration.engine.apply_patch", side_effect=apply_and_crash):
            with self.assertRaises(InterruptedError):
                engine.execute()
        recovered_provider = FakeProvider()
        recovered = self.engine(recovered_provider)
        self.assertEqual(recovered.execute(resume=True)["one"], "COMPLETED")
        self.assertEqual([c["role"] for c in recovered_provider.calls], ["reviewer", "qa"])

    def test_crash_after_commit_recovers_publication_without_new_models(self):
        provider = FakeProvider([patch_response()])
        engine = self.engine(provider)
        original = git
        def commit_and_crash(root, *args, **kwargs):
            value = original(root, *args, **kwargs)
            if args[0] == "commit":
                raise InterruptedError("after commit")
            return value
        with patch("orchestration.engine.git", side_effect=commit_and_crash):
            with self.assertRaises(InterruptedError):
                engine.execute()
        recovered_provider = FakeProvider()
        self.assertEqual(self.engine(recovered_provider).execute(resume=True)["one"], "COMPLETED")
        self.assertEqual(recovered_provider.calls, [])

    def test_pending_push_stops_later_tasks(self):
        git(self.root, "remote", "set-url", "origin", str(self.base / "missing.git"))
        provider = FakeProvider()
        engine = self.engine(provider, [self.task, task("two")])
        self.assertEqual(engine.execute(), {"one": "WAITING", "two": "PENDING"})
        self.assertEqual(len(provider.calls), 3)

    def test_simple_task_runs_all_checks_then_one_combined_acceptance(self):
        self.config["acceptance"]["combined_levels"] = ["low"]
        def accept(result, call, root):
            record = engine.state.data["tasks"]["one"]
            self.assertEqual(set(record["checks"]), {"diff-check", "unit", "ui"})
            self.assertTrue(all(c["status"] == "PASS" for c in record["checks"].values()))
            self.assertIn("ONE combined Review/QA", call["prompt"])
        provider = FakeProvider([patch_response(), accept])
        engine = self.engine(provider)
        self.assertEqual(engine.execute()["one"], "COMPLETED")
        self.assertEqual([c["role"] for c in provider.calls], ["developer", "acceptance"])
        self.assertEqual(provider.calls[-1]["model"], "gpt-6.1-sol")
        self.assertEqual(self.engine(FakeProvider()).execute(resume=True)["one"], "COMPLETED")

    def test_combined_acceptance_cannot_skip_ui_evidence(self):
        self.config["acceptance"]["combined_levels"] = ["low"]
        self.task["write_files"] = []
        def missing_ui(result, call, root):
            result["reply"]["criteria"][1]["evidence"] = []
        engine = self.engine(FakeProvider([missing_ui]))
        self.assertEqual(engine.execute()["one"], "BLOCKED")
        self.assertFalse((self.root / "docs/validation/automation/tasks/one.md").exists())

    def test_combined_acceptance_limit_falls_back_without_an_extra_qa_role(self):
        self.config["acceptance"]["combined_levels"] = ["low"]
        provider = FakeProvider([{}, {"status": "FAIL", "category": "limit", "error": "quota"}, {}])
        engine = self.engine(provider)
        self.assertEqual(engine.execute()["one"], "COMPLETED")
        self.assertEqual([(c["role"], c["provider"]) for c in provider.calls],
                         [("developer", "codex"), ("acceptance", "codex"), ("acceptance", "agy")])
        self.assertIsNone(provider.calls[-1]["session"])
        self.assertEqual(engine.state.data["tasks"]["one"]["calls"][-1]["retry"], 1)

    def test_readonly_simple_task_checks_then_one_acceptance(self):
        self.config["acceptance"]["combined_levels"] = ["low"]
        self.task["write_files"] = []
        provider = FakeProvider()
        self.assertEqual(self.engine(provider).execute()["one"], "COMPLETED")
        self.assertEqual([c["role"] for c in provider.calls], ["acceptance"])

    def test_combined_pending_push_resumes_without_new_models(self):
        self.config["acceptance"]["combined_levels"] = ["low"]
        git(self.root, "remote", "set-url", "origin", str(self.base / "missing.git"))
        engine = self.engine(FakeProvider())
        self.assertEqual(engine.execute()["one"], "WAITING")
        self.assertEqual(engine.state.data["tasks"]["one"]["phase"], "publish")
        git(self.root, "remote", "set-url", "origin", str(self.remote))
        provider = FakeProvider()
        self.assertEqual(self.engine(provider).execute(resume=True)["one"], "COMPLETED")
        self.assertEqual(provider.calls, [])

    def test_failed_qa_check_prevents_combined_model_acceptance(self):
        self.config["acceptance"]["combined_levels"] = ["low"]
        self.config["checks"]["ui"]["argv"] = [sys.executable, "-c", "raise SystemExit(1)"]
        provider = FakeProvider()
        self.assertEqual(self.engine(provider).execute()["one"], "BLOCKED")
        self.assertTrue(all(call["role"] == "developer" for call in provider.calls))

    def test_high_risk_keeps_separate_astra_review_and_qa(self):
        self.config["acceptance"]["combined_levels"] = ["low"]
        self.task["risk"] = "high"
        provider = FakeProvider()
        self.assertEqual(self.engine(provider).execute()["one"], "COMPLETED")
        self.assertEqual([(c["role"], c["model"]) for c in provider.calls], [
            ("developer", "gpt-6.1-sol"), ("reviewer", "gpt-6-astra"), ("qa", "gpt-6-astra")])
        self.assertEqual([c["effort"] for c in provider.calls], ["medium", "high", "high"])

    def test_ambiguous_cli_input_count_does_not_discard_repair_session(self):
        def large_usage(result, call, root):
            result["usage"]["input_tokens"] = 900000
            result["usage_scope"] = "CLI-reported counters; per-turn/session scope not guaranteed"
            fail_response("repair once")(result, call, root)
        provider = FakeProvider([large_usage])
        engine = self.engine(provider)
        self.assertEqual(engine.execute()["one"], "COMPLETED")
        self.assertEqual(provider.calls[1]["session"], "session-1")
        self.assertIn('"resume_delta": true', provider.calls[1]["prompt"])
        self.assertFalse(any(c["reason"] == "reported input threshold"
                             for c in engine.state.data["tasks"]["one"]["compactions"]))

    def test_only_explicit_measured_context_can_trigger_input_rotation(self):
        def measured(result, call, root):
            result.update(context_tokens=64000, context_tokens_scope="current_context")
            fail_response("repair once")(result, call, root)
        provider = FakeProvider([measured])
        engine = self.engine(provider)
        self.assertEqual(engine.execute()["one"], "COMPLETED")
        self.assertIsNone(provider.calls[1]["session"])
        self.assertEqual(engine.state.data["tasks"]["one"]["compactions"][0]["reason"],
                         "measured context threshold")

    def test_unqualified_context_counter_does_not_rotate(self):
        def unqualified(result, call, root):
            result.update(context_tokens=900000)
            fail_response("repair once")(result, call, root)
        provider = FakeProvider([unqualified])
        self.assertEqual(self.engine(provider).execute()["one"], "COMPLETED")
        self.assertEqual(provider.calls[1]["session"], "session-1")

    def test_estimated_context_limit_still_rotates(self):
        self.config["sessions"]["max_estimated_tokens"] = 1
        provider = FakeProvider([fail_response("repair once")])
        engine = self.engine(provider)
        self.assertEqual(engine.execute()["one"], "COMPLETED")
        self.assertIsNone(provider.calls[1]["session"])
        self.assertEqual(engine.state.data["tasks"]["one"]["compactions"][0]["reason"],
                         "estimated context threshold")

    def test_complex_finding_increases_developer_effort_in_fresh_session(self):
        def complex_finding(result, call, root):
            fail_response("Ambiguous rollback defect")(result, call, root)
            result["reply"]["finding_complexity"] = "high"
        provider = FakeProvider([{}, complex_finding])
        engine = self.engine(provider)
        self.assertEqual(engine.execute()["one"], "COMPLETED")
        self.assertEqual(provider.calls[0]["effort"], "medium")
        self.assertEqual(provider.calls[2]["effort"], "high")
        self.assertIsNone(provider.calls[2]["session"])

    def test_developer_timeout_cannot_resume_unchanged_request(self):
        provider = FakeProvider([{"status": "FAIL", "category": "timeout", "error": "timeout"}])
        engine = self.engine(provider)
        self.assertEqual(engine.execute()["one"], "WAITING")
        self.assertEqual(len(provider.calls), 1)
        retry = FakeProvider()
        recovered = self.engine(retry)
        self.assertEqual(recovered.execute(resume=True)["one"], "WAITING")
        self.assertEqual(retry.calls, [])
        self.assertTrue(recovered.state.data["tasks"]["one"]["replan_required"])
        self.assertIn("new manifest/run", recovered.state.data["tasks"]["one"]["reason"])

    def test_candidate_acceptance_receives_real_committed_diff_without_developer(self):
        self.task["write_files"] = []
        self.task["candidate_base"] = git(self.root, "rev-parse", "HEAD").decode().strip()
        (self.root / "src/file.txt").write_text("ready candidate\n")
        git(self.root, "add", ".")
        git(self.root, "commit", "-m", "candidate")
        provider = FakeProvider()
        engine = self.engine(provider)
        self.assertEqual(engine.execute()["one"], "COMPLETED")
        self.assertEqual([c["role"] for c in provider.calls], ["reviewer", "qa"])
        for call in provider.calls:
            self.assertIn("-before", call["prompt"])
            self.assertIn("+ready candidate", call["prompt"])
            self.assertIn('"review_scope": "candidate_diff"', call["prompt"])

    def test_empty_candidate_diff_stops_before_spending_model_budget(self):
        self.task["write_files"] = []
        self.task["candidate_base"] = git(self.root, "rev-parse", "HEAD").decode().strip()
        provider = FakeProvider()
        engine = self.engine(provider)
        self.assertEqual(engine.execute()["one"], "BLOCKED")
        self.assertEqual(provider.calls, [])
        self.assertEqual(engine.state.data["tasks"]["one"]["counts"], {})

    def test_candidate_cannot_hide_changed_paths_from_scope_checks(self):
        self.task["write_files"] = []
        self.task["candidate_base"] = git(self.root, "rev-parse", "HEAD").decode().strip()
        (self.root / "src/unlisted.txt").write_text("changed outside declared scope\n")
        git(self.root, "add", ".")
        git(self.root, "commit", "-m", "unlisted change")
        provider = FakeProvider()
        engine = self.engine(provider)
        self.assertEqual(engine.execute()["one"], "BLOCKED")
        self.assertEqual(provider.calls, [])
        self.assertIn("candidate diff paths missing", engine.state.data["tasks"]["one"]["reason"])

    def test_candidate_diff_includes_deleted_input(self):
        self.task["write_files"] = []
        self.task["candidate_base"] = git(self.root, "rev-parse", "HEAD").decode().strip()
        (self.root / "src/file.txt").unlink()
        git(self.root, "add", ".")
        git(self.root, "commit", "-m", "remove obsolete source")
        provider = FakeProvider()
        self.assertEqual(self.engine(provider).execute()["one"], "COMPLETED")
        self.assertIn("-before", provider.calls[0]["prompt"])
        self.assertIn("deleted file mode", provider.calls[0]["prompt"])

    def test_missing_fixture_stops_before_developer(self):
        self.task["files"].append("src/missing-fixture.json")
        provider = FakeProvider()
        engine = self.engine(provider)
        self.assertEqual(engine.execute()["one"], "BLOCKED")
        self.assertEqual(provider.calls, [])

    def test_missing_saved_log_stops_qa_before_model_call(self):
        def remove_log(result, call, root):
            (self.directory / "one/check-2-unit/stdout.log").unlink()
        provider = FakeProvider([{}, remove_log])
        engine = self.engine(provider)
        self.assertEqual(engine.execute()["one"], "BLOCKED")
        self.assertEqual([c["role"] for c in provider.calls], ["developer", "reviewer"])
        self.assertIn("missing saved stdout", engine.state.data["tasks"]["one"]["reason"])

    def test_readonly_interrupted_acceptance_never_resumes_as_developer(self):
        self.task["write_files"] = []
        engine = self.engine(FakeProvider([InterruptedError()]))
        with self.assertRaises(InterruptedError):
            engine.execute()
        provider = FakeProvider()
        self.assertEqual(self.engine(provider).execute(resume=True)["one"], "COMPLETED")
        self.assertEqual([c["role"] for c in provider.calls], ["reviewer", "qa"])

    def test_task_complexity_alone_uses_sol_for_split_acceptance(self):
        self.task["complexity"] = "high"
        provider = FakeProvider()
        self.assertEqual(self.engine(provider).execute()["one"], "COMPLETED")
        self.assertTrue(all(c["model"] == "gpt-6.1-sol" for c in provider.calls))

    def test_complex_finding_escalates_next_acceptance_to_fresh_astra(self):
        self.config["acceptance"]["combined_levels"] = ["low"]
        def complex_finding(result, call, root):
            fail_response("Ambiguous data loss")(result, call, root)
            result["reply"]["finding_complexity"] = "high"
        provider = FakeProvider([patch_response(), complex_finding,
                                 patch_response("after\n", "fixed\n"), {}])
        engine = self.engine(provider)
        self.assertEqual(engine.execute()["one"], "COMPLETED")
        self.assertEqual(provider.calls[-1]["model"], "gpt-6-astra")
        self.assertIsNone(provider.calls[-1]["session"])
        self.assertIn('"acceptance_criteria"', provider.calls[-1]["prompt"])
        self.assertIn("-before", provider.calls[-1]["prompt"])
        self.assertEqual([c["role"] for c in provider.calls], ["developer", "acceptance", "developer", "acceptance"])

    def test_repeated_findings_escalate_without_resetting_budget(self):
        self.config["acceptance"]["combined_levels"] = ["low"]
        provider = FakeProvider([{}, fail_response("first"), {}, fail_response("second"), {}, {}])
        engine = self.engine(provider)
        self.assertEqual(engine.execute()["one"], "COMPLETED")
        self.assertEqual([c["model"] for c in provider.calls if c["role"] == "acceptance"],
                         ["gpt-6.1-sol", "gpt-6.1-sol", "gpt-6-astra"])
        self.assertEqual(engine.state.data["tasks"]["one"]["counts"]["acceptance"], 3)

    def test_real_resume_sends_only_delta_and_errors_for_developer_and_reviewer(self):
        provider = FakeProvider([patch_response(), fail_response("repair this"),
                                 patch_response("after\n", "fixed\n"), {}, {}])
        engine = self.engine(provider)
        self.assertEqual(engine.execute()["one"], "COMPLETED")
        for call in provider.calls[2:4]:
            payload = json.loads(call["prompt"].split("\n", 1)[1].split("\nFull task diff:", 1)[0])
            self.assertTrue(payload["resume_delta"])
            for field in ("acceptance_criteria", "constraints", "architecture", "project_state", "dependency_decisions"):
                self.assertNotIn(field, payload)
            self.assertIn("repair this", payload["errors"])
        self.assertLess(len(provider.calls[2]["prompt"]), len(provider.calls[0]["prompt"]))
        self.assertNotIn("-before", provider.calls[3]["prompt"])

    def test_scope_evidence_is_required_even_when_not_in_criteria(self):
        provider = FakeProvider()
        engine = self.engine(provider)
        record = engine.state.data["tasks"]["one"]
        record["fingerprint"] = "tree"
        record["checks"] = {name: {"status": "PASS", "fingerprint": "tree"} for name in ("unit", "ui")}
        reply = {"status": "PASS", "findings": [], "criteria": [
            {"id": c["id"], "status": "PASS", "evidence": c["checks"]} for c in self.task["acceptance_criteria"]]}
        self.assertFalse(engine.accepts(self.task, record, reply, "acceptance"))


if __name__ == "__main__":
    unittest.main()
