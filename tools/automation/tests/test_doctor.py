"""Infrastructure checks with fixtures; no model requests or Simulator access."""

import importlib.util
import json
from pathlib import Path
import plistlib
import sys
import tempfile
import unittest


SOURCE = Path(__file__).resolve().parents[1] / "doctor.py"
SPEC = importlib.util.spec_from_file_location("doctor", SOURCE)
doctor = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(doctor)


class DoctorTests(unittest.TestCase):
    def setUp(self):
        doctor.RUNS.mkdir(parents=True, exist_ok=True)
        self.scratch = tempfile.TemporaryDirectory(prefix="fixture-", dir=doctor.RUNS)
        self.base = Path(self.scratch.name)

    def tearDown(self):
        self.scratch.cleanup()

    def test_run_cannot_escape_project_or_overwrite_evidence(self):
        for name in ("../outside", "/tmp/outside", "a/b", ".", ""):
            with self.assertRaises(ValueError):
                doctor.new_run_path(self.base, name)
        target = doctor.new_run_path(self.base, "first")
        (target / "evidence").write_text("keep")
        with self.assertRaises(FileExistsError):
            doctor.new_run_path(self.base, "first")
        self.assertEqual((target / "evidence").read_text(), "keep")
        with self.assertRaises(ValueError):
            doctor.new_run_path(Path("/private/tmp"), "outside-project")

    def test_second_runner_cannot_take_lock(self):
        with doctor.exclusive_run(self.base):
            with self.assertRaises(RuntimeError):
                with doctor.exclusive_run(self.base):
                    self.fail("second runner acquired lock")
        with doctor.exclusive_run(self.base):
            pass

    def test_failed_command_is_logged_and_blocks_pass(self):
        runner = doctor.Doctor(self.base)
        check = runner.command("failure", [sys.executable, "-c",
            "import sys; print('fixture-output'); print('fixture-error', file=sys.stderr); sys.exit(7)"])
        self.assertEqual(check["exit_code"], 7)
        self.assertEqual(check["status"], "FAIL")
        self.assertIn("fixture-output", runner.read_stdout(check))
        self.assertIn("fixture-error", (self.base / check["stderr"]).read_text())
        self.assertEqual(runner.finish(True), 1)
        self.assertEqual(json.loads((self.base / "summary.json").read_text())["status"], "FAIL")

    def test_timeout_stops_command_and_persists_failure(self):
        runner = doctor.Doctor(self.base)
        check = runner.command("timeout", [sys.executable, "-c", "import time; time.sleep(60)"], timeout=0.05)
        self.assertEqual(check["status"], "FAIL")
        self.assertEqual(check["error"], "timeout")
        self.assertLess(check["elapsed_seconds"], 10)
        self.assertEqual(json.loads((self.base / "summary.json").read_text())["checks"][0]["status"], "FAIL")

    def test_missing_executable_is_failure(self):
        runner = doctor.Doctor(self.base)
        check = runner.command("missing", [str(self.base / "not-installed")])
        self.assertEqual(check["status"], "FAIL")

    def test_inventory_does_not_claim_full_pass(self):
        runner = doctor.Doctor(self.base)
        runner.add("inventory", "PASS")
        runner.add("ios", "SKIP")
        self.assertEqual(runner.finish(False), 0)
        self.assertEqual(runner.report["status"], "INCOMPLETE")

    def test_model_reply_must_match_nonce_and_role(self):
        answer = self.base / "answer.json"
        self.assertFalse(doctor.model_reply_ok(answer, "unique", "qa"))
        doctor.write_json(answer, {"nonce": "unique", "role": "qa", "status": "ok"})
        self.assertTrue(doctor.model_reply_ok(answer, "unique", "qa"))
        self.assertFalse(doctor.model_reply_ok(answer, "old", "qa"))
        self.assertFalse(doctor.model_reply_ok(answer, "unique", "developer"))
        answer.write_text("not json")
        self.assertFalse(doctor.model_reply_ok(answer, "unique", "qa"))

    def test_welcome_requires_one_pass_without_skips(self):
        passed = {"result": "Passed", "totalTestCount": 1, "passedTests": 1,
                  "failedTests": 0, "skippedTests": 0}
        self.assertTrue(doctor.welcome_summary_ok(passed))
        for change in ({"passedTests": 0}, {"skippedTests": 1}, {"failedTests": 1},
                       {"totalTestCount": 0}, {"result": "Failed"}):
            self.assertFalse(doctor.welcome_summary_ok({**passed, **change}))
        self.assertFalse(doctor.welcome_summary_ok({}))

    def test_smoke_build_disables_live_client_configuration(self):
        settings = dict(value.split("=", 1) for value in doctor.LOCAL_UI_SETTINGS)
        for key in ("NARAT_SUPABASE_URL", "NARAT_SUPABASE_PUBLISHABLE_KEY",
                    "GOOGLE_IOS_CLIENT_ID", "GOOGLE_SERVER_CLIENT_ID", "GOOGLE_REVERSED_CLIENT_ID"):
            self.assertEqual(settings[key], "")

    def test_built_app_with_live_configuration_is_rejected(self):
        info = self.base / "Info.plist"
        self.assertFalse(doctor.local_ui_info_ok(info))
        info.write_bytes(plistlib.dumps({"NaratSupabaseURL": "", "NaratSupabasePublishableKey": ""}))
        self.assertTrue(doctor.local_ui_info_ok(info))
        info.write_bytes(plistlib.dumps({"NaratSupabaseURL": "https://fixture.invalid"}))
        self.assertFalse(doctor.local_ui_info_ok(info))
        info.write_bytes(b"invalid plist")
        self.assertFalse(doctor.local_ui_info_ok(info))


if __name__ == "__main__":
    unittest.main()
