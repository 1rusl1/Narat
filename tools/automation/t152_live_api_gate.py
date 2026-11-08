#!/usr/bin/env python3
"""Verify T152 safe refusal on live deployed narat-staging plants-api."""

import argparse
import json
import os
from pathlib import Path
import re
import signal
import urllib.error
import urllib.parse
import urllib.request
import uuid

from doctor import Doctor, ROOT, RUNS, exclusive_run, new_run_path


EXPECTED_PROJECT_REF = "ijwnyjdomwvnzmmcurkt"
DEFAULT_XCCONFIG = ROOT / "ios/Configuration/Auth.local.xcconfig"


def parse_xcconfig(text):
    values = {}
    for raw_line in text.splitlines():
        line = raw_line.split("//", 1)[0].strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        cleaned = value.strip().replace("$()", "").replace("${}", "")
        values[key.strip()] = cleaned
    return values


def load_staging_config(xcconfig_path=DEFAULT_XCCONFIG, env=None):
    source = env if env is not None else os.environ
    file_values = {}
    if Path(xcconfig_path).is_file():
        file_values = parse_xcconfig(Path(xcconfig_path).read_text())
    url = (source.get("NARAT_SUPABASE_URL") or file_values.get("NARAT_SUPABASE_URL") or "").strip().rstrip("/")
    key = (source.get("NARAT_SUPABASE_PUBLISHABLE_KEY")
           or file_values.get("NARAT_SUPABASE_PUBLISHABLE_KEY") or "").strip()
    if not url or not key:
        raise ValueError("Missing NARAT_SUPABASE_URL or NARAT_SUPABASE_PUBLISHABLE_KEY")
    parsed = urllib.parse.urlparse(url)
    host = parsed.hostname or ""
    match = re.fullmatch(r"([a-z0-9]+)\.supabase\.co", host)
    project_ref = match.group(1) if match else ""
    if parsed.scheme != "https" or project_ref != EXPECTED_PROJECT_REF:
        raise ValueError(f"Unexpected staging URL or project_ref: {url!r}")
    return {"base_url": url, "publishable_key": key, "project_ref": project_ref}


def health_payload_ok(status, payload, expected_locale):
    return (
        status == 200
        and isinstance(payload, dict)
        and payload.get("status") == "ok"
        and payload.get("version") == "3.0.0"
        and payload.get("locale") == expected_locale
    )


def unauthorized_payload_ok(status, payload, expected_locale):
    if status != 401 or not isinstance(payload, dict) or set(payload.keys()) != {"error"}:
        return False
    err = payload.get("error")
    if not isinstance(err, dict):
        return False
    msg = str(err.get("message") or "")
    locale_ok = ("Nieprawidłowy" in msg or "Wymagane" in msg) if expected_locale == "pl" else (
        "Invalid" in msg or "Authentication" in msg
    )
    return (
        err.get("code") == "UNAUTHORIZED"
        and err.get("retryable") is False
        and locale_ok
    )


def unavailable_payload_ok(status, payload, expected_locale, route):
    if status != 503 or not isinstance(payload, dict) or set(payload.keys()) != {"error"}:
        return False
    if any(forbidden in payload for forbidden in ("status", "committed", "replayed", "items", "server_watermark")):
        return False
    err = payload.get("error")
    if not isinstance(err, dict):
        return False
    msg = str(err.get("message") or "")
    if route == "sync":
        locale_ok = "Synchronizacja jest tymczasowo niedostępna" in msg if expected_locale == "pl" else (
            "Synchronization is temporarily unavailable" in msg
        )
    else:
        locale_ok = "Zapisywanie jest tymczasowo niedostępne" in msg if expected_locale == "pl" else (
            "Saving is temporarily unavailable" in msg
        )
    return (
        err.get("code") == "INTERNAL_ERROR"
        and err.get("retryable") is True
        and locale_ok
    )


def postgrest_denied_ok(status, payload):
    return (
        status in (401, 403, 404)
        and isinstance(payload, dict)
        and not isinstance(payload.get("items"), list)
        and payload.get("status") != "committed"
    )


def http_json(url, method="GET", headers=None, body=None, timeout=20):
    data = None if body is None else json.dumps(body).encode("utf-8")
    req_headers = {"Accept": "application/json", **(headers or {})}
    if data is not None:
        req_headers.setdefault("Content-Type", "application/json")
    request = urllib.request.Request(url, data=data, headers=req_headers, method=method)
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            raw = response.read().decode("utf-8")
            return response.status, json.loads(raw) if raw else None
    except urllib.error.HTTPError as error:
        raw = error.read().decode("utf-8")
        try:
            parsed = json.loads(raw) if raw else None
        except ValueError:
            parsed = {"raw": raw}
        return error.code, parsed


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--xcconfig", default=str(DEFAULT_XCCONFIG))
    args = parser.parse_args()

    def interrupted(signum, frame):
        raise InterruptedError(f"signal {signum}")

    signal.signal(signal.SIGTERM, interrupted)
    with exclusive_run(RUNS):
        runner = Doctor(new_run_path(RUNS, args.run_id))
        try:
            cfg = load_staging_config(Path(args.xcconfig))
            base = cfg["base_url"]
            pub = cfg["publishable_key"]
            runner.add("staging-config", "PASS", mode="live", project_ref=cfg["project_ref"], base_url=base)

            for loc in ("en", "pl"):
                status, payload = http_json(
                    f"{base}/functions/v1/plants-api/health",
                    headers={"X-Client-Locale": loc},
                )
                ok = health_payload_ok(status, payload, loc)
                runner.add(f"health-{loc}", "PASS" if ok else "FAIL", mode="live",
                           http_status=status, response=payload)
                if not ok:
                    return runner.finish(False)

            for loc in ("en", "pl"):
                for token_case, auth_header in (("missing", {}), ("invalid", {"Authorization": "Bearer invalid-token"})):
                    for route, method, body in (
                        ("sync", "GET", None),
                        ("commands", "POST", {"operation_id": str(uuid.uuid4()), "command_name": "care.record", "payload": {}}),
                    ):
                        status, payload = http_json(
                            f"{base}/functions/v1/plants-api/{route}",
                            method=method,
                            headers={"X-Client-Locale": loc, **auth_header},
                            body=body,
                        )
                        ok = unauthorized_payload_ok(status, payload, loc)
                        runner.add(f"guard-{route}-{token_case}-{loc}", "PASS" if ok else "FAIL",
                                   mode="live", http_status=status, response=payload)
                        if not ok:
                            return runner.finish(False)

            auth_status, auth_payload = http_json(
                f"{base}/auth/v1/signup",
                method="POST",
                headers={"apikey": pub},
                body={"data": {}},
            )
            token = (auth_payload or {}).get("access_token") if isinstance(auth_payload, dict) else None
            user = (auth_payload or {}).get("user") if isinstance(auth_payload, dict) else None
            owner_id = user.get("id") if isinstance(user, dict) else None
            auth_ok = auth_status == 200 and bool(token) and bool(owner_id)
            runner.add("anonymous-signup", "PASS" if auth_ok else "FAIL", mode="live",
                       http_status=auth_status, owner_id=owner_id)
            if not auth_ok:
                return runner.finish(False)

            prof_status, prof_payload = http_json(
                f"{base}/rest/v1/profiles?id=eq.{owner_id}&select=id,account_state,anonymous",
                headers={"apikey": pub, "Authorization": f"Bearer {token}"},
            )
            prof_ok = (
                prof_status == 200
                and isinstance(prof_payload, list)
                and len(prof_payload) == 1
                and prof_payload[0].get("id") == owner_id
                and prof_payload[0].get("account_state") == "active"
                and prof_payload[0].get("anonymous") is True
            )
            runner.add("anonymous-profile", "PASS" if prof_ok else "FAIL", mode="live",
                       http_status=prof_status, profile=prof_payload)
            if not prof_ok:
                return runner.finish(False)

            for loc in ("en", "pl"):
                sync_status, sync_payload = http_json(
                    f"{base}/functions/v1/plants-api/sync",
                    headers={"Authorization": f"Bearer {token}", "X-Client-Locale": loc},
                )
                sync_ok = unavailable_payload_ok(sync_status, sync_payload, loc, "sync")
                runner.add(f"live-sync-503-{loc}", "PASS" if sync_ok else "FAIL",
                           mode="live", http_status=sync_status, response=sync_payload)
                if not sync_ok:
                    return runner.finish(False)

            operation_id = str(uuid.uuid4())
            plant_id = str(uuid.uuid4())
            for attempt, loc in ((1, "en"), (2, "en"), (3, "pl")):
                cmd_status, cmd_payload = http_json(
                    f"{base}/functions/v1/plants-api/commands",
                    method="POST",
                    headers={
                        "Authorization": f"Bearer {token}",
                        "X-Client-Locale": loc,
                        "X-Operation-Id": operation_id,
                    },
                    body={
                        "operation_id": operation_id,
                        "command_name": "care.record",
                        "plant_id": plant_id,
                        "payload": {"action_type": "water", "performed_date": "2026-11-08"},
                    },
                )
                cmd_ok = unavailable_payload_ok(cmd_status, cmd_payload, loc, "commands")
                runner.add(f"live-commands-503-attempt-{attempt}-{loc}", "PASS" if cmd_ok else "FAIL",
                           mode="live", http_status=cmd_status, operation_id=operation_id, response=cmd_payload)
                if not cmd_ok:
                    return runner.finish(False)

            rpc_sync_status, rpc_sync_payload = http_json(
                f"{base}/rest/v1/rpc/fetch_sync_delta",
                method="POST",
                headers={"apikey": pub, "Authorization": f"Bearer {token}"},
                body={"p_owner_id": owner_id},
            )
            rpc_save_status, rpc_save_payload = http_json(
                f"{base}/rest/v1/rpc/save_operation_receipt",
                method="POST",
                headers={"apikey": pub, "Authorization": f"Bearer {token}"},
                body={
                    "p_owner_id": owner_id,
                    "p_operation_id": operation_id,
                    "p_command_name": "care.record",
                    "p_payload_hash": "0" * 64,
                    "p_response_payload": {"status": "committed"},
                },
            )
            bypass_denied = (
                postgrest_denied_ok(rpc_sync_status, rpc_sync_payload)
                and postgrest_denied_ok(rpc_save_status, rpc_save_payload)
            )
            runner.add("client-rpc-bypass-denied", "PASS" if bypass_denied else "FAIL",
                       mode="live", owner_id=owner_id, operation_id=operation_id,
                       fetch_sync_delta_status=rpc_sync_status,
                       save_operation_receipt_status=rpc_save_status)
            return runner.finish(bypass_denied)
        except (KeyboardInterrupt, InterruptedError):
            runner.add("t152-live-api", "FAIL", reason="interrupted")
            runner.finish(False)
            return 130
        except (OSError, ValueError, KeyError) as error:
            runner.add("t152-live-api", "FAIL", reason=str(error))
            return runner.finish(False)


if __name__ == "__main__":
    raise SystemExit(main())
