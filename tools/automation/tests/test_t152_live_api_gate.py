"""Fixture tests for T152 live staging API gate helpers; no network calls."""

from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from t152_live_api_gate import (
    EXPECTED_PROJECT_REF,
    health_payload_ok,
    load_staging_config,
    parse_xcconfig,
    postgrest_denied_ok,
    unauthorized_payload_ok,
    unavailable_payload_ok,
)


class T152LiveAPIGateTests(unittest.TestCase):
    def test_parse_xcconfig_strips_xcode_empty_variable_escape_and_comments(self):
        raw = (
            "// Comment line\n"
            "NARAT_SUPABASE_URL = https:/$()/ijwnyjdomwvnzmmcurkt.supabase.co // inline\n"
            "NARAT_SUPABASE_PUBLISHABLE_KEY = sb_publishable_test_key\n"
        )
        parsed = parse_xcconfig(raw)
        self.assertEqual(parsed["NARAT_SUPABASE_URL"], "https://ijwnyjdomwvnzmmcurkt.supabase.co")
        self.assertEqual(parsed["NARAT_SUPABASE_PUBLISHABLE_KEY"], "sb_publishable_test_key")

    def test_load_staging_config_validates_project_ref(self):
        with tempfile.TemporaryDirectory() as tmp:
            xcconfig = Path(tmp) / "Auth.local.xcconfig"
            xcconfig.write_text(
                f"NARAT_SUPABASE_URL = https:/$()/{EXPECTED_PROJECT_REF}.supabase.co\n"
                "NARAT_SUPABASE_PUBLISHABLE_KEY = sb_publishable_example\n"
            )
            cfg = load_staging_config(xcconfig, env={})
            self.assertEqual(cfg["project_ref"], EXPECTED_PROJECT_REF)
            self.assertEqual(cfg["base_url"], f"https://{EXPECTED_PROJECT_REF}.supabase.co")

            wrong = Path(tmp) / "Wrong.xcconfig"
            wrong.write_text(
                "NARAT_SUPABASE_URL = https://otherproject.supabase.co\n"
                "NARAT_SUPABASE_PUBLISHABLE_KEY = sb_publishable_example\n"
            )
            with self.assertRaises(ValueError):
                load_staging_config(wrong, env={})

    def test_health_and_unauthorized_and_unavailable_validators(self):
        self.assertTrue(health_payload_ok(200, {"status": "ok", "version": "3.0.0", "locale": "en"}, "en"))
        self.assertFalse(health_payload_ok(200, {"status": "ok", "version": "3.0.0", "locale": "pl"}, "en"))
        self.assertFalse(health_payload_ok(500, {"status": "ok", "version": "3.0.0", "locale": "en"}, "en"))

        unauth_en = {"error": {"code": "UNAUTHORIZED", "message": "Invalid or expired session token.", "retryable": False}}
        unauth_pl = {"error": {"code": "UNAUTHORIZED", "message": "Nieprawidłowy lub wygasły token sesji.", "retryable": False}}
        self.assertTrue(unauthorized_payload_ok(401, unauth_en, "en"))
        self.assertTrue(unauthorized_payload_ok(401, unauth_pl, "pl"))
        self.assertFalse(unauthorized_payload_ok(200, unauth_en, "en"))
        self.assertFalse(unauthorized_payload_ok(401, {"error": {"code": "UNAUTHORIZED", "message": "Invalid", "retryable": True}}, "en"))

        sync_503_en = {
            "error": {
                "code": "INTERNAL_ERROR",
                "message": "Synchronization is temporarily unavailable. Please try again later.",
                "retryable": True,
            }
        }
        cmd_503_pl = {
            "error": {
                "code": "INTERNAL_ERROR",
                "message": "Zapisywanie jest tymczasowo niedostępne. Spróbuj ponownie później.",
                "retryable": True,
            }
        }
        self.assertTrue(unavailable_payload_ok(503, sync_503_en, "en", "sync"))
        self.assertTrue(unavailable_payload_ok(503, cmd_503_pl, "pl", "commands"))
        self.assertFalse(unavailable_payload_ok(200, {"status": "committed"}, "en", "commands"))
        self.assertFalse(unavailable_payload_ok(503, {**sync_503_en, "items": []}, "en", "sync"))

        self.assertTrue(postgrest_denied_ok(403, {"code": "42501", "message": "permission denied"}))
        self.assertFalse(postgrest_denied_ok(200, {"status": "committed"}))


if __name__ == "__main__":
    unittest.main()
