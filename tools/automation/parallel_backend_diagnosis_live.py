"""Run one owner-scoped photo diagnosis on the documented staging project."""
import argparse
import hashlib
import json
import re
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from pathlib import Path

from t152_live_api_gate import EXPECTED_PROJECT_REF, load_staging_config


class SmokeError(ValueError):
    pass


class RejectRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--photo", required=True, type=Path, help="Authorized normalized JPEG, up to 10 MiB")
    parser.add_argument("--session-file", required=True, type=Path, help="Private synthetic account JSON, mode 0600")
    parser.add_argument("--xcconfig", required=True, type=Path, help="Staging public client configuration")
    parser.add_argument("--run-id", required=True, help="Reuse the same ID to retry the same photo without another job")
    args = parser.parse_args()
    if not re.fullmatch(r"[a-zA-Z0-9_-]{1,64}", args.run_id):
        raise SmokeError("Invalid smoke run ID.")
    if args.session_file.stat().st_mode & 0o077:
        raise SmokeError("The synthetic login file must be private.")
    login = json.loads(args.session_file.read_text())
    if not re.fullmatch(r"diagnosis-[a-f0-9]{14}@example[.]test", login.get("email", "")):
        raise SmokeError("Only the dedicated synthetic diagnosis account is supported.")
    owner = str(uuid.UUID(login["owner_id"]))
    if not 3 <= args.photo.stat().st_size <= 10 * 1024 * 1024:
        raise SmokeError("Photo size must be within the approved limit.")
    photo = args.photo.read_bytes()
    if not photo.startswith(b"\xff\xd8\xff"):
        raise SmokeError("Expected a normalized JPEG.")
    config = load_staging_config(args.xcconfig)
    base = config["base_url"]
    if base != f"https://{EXPECTED_PROJECT_REF}.supabase.co":
        raise SmokeError("The diagnosis smoke is restricted to the documented staging origin.")
    opener = urllib.request.build_opener(RejectRedirects)

    def request(label, path, method="GET", body=None, token=None, accepted=(200,)):
        url = urllib.parse.urljoin(base, path)
        parsed = urllib.parse.urlparse(url)
        if (parsed.scheme, parsed.netloc) != ("https", f"{EXPECTED_PROJECT_REF}.supabase.co"):
            raise SmokeError("Refused a request outside the staging origin.")
        headers = {"apikey": config["publishable_key"], "X-Client-Locale": "en"}
        if token:
            headers["Authorization"] = f"Bearer {token}"
        if isinstance(body, bytes):
            headers["Content-Type"] = "image/jpeg"
            data = body
        elif body is not None:
            headers["Content-Type"] = "application/json"
            data = json.dumps(body).encode()
        else:
            data = None
        try:
            req = urllib.request.Request(url, headers=headers, data=data, method=method)
            with opener.open(req, timeout=15) as response:
                status = response.status
                value = json.load(response)
        except urllib.error.HTTPError as error:
            status = error.code
            if status not in accepted:
                raise SmokeError(f"{label} returned HTTP {status}.") from None
            try:
                with error:
                    value = json.load(error)
            except (OSError, ValueError):
                raise SmokeError(f"{label} response could not be verified.") from None
        except (OSError, ValueError):
            raise SmokeError(f"{label} response could not be verified.") from None
        if status not in accepted:
            raise SmokeError(f"{label} returned unexpected HTTP {status}.")
        return value

    session = request("Password sign-in", "/auth/v1/token?grant_type=password", "POST",
                      {k: login[k] for k in ("email", "password")})
    if session["user"]["id"] != owner or session["user"].get("is_anonymous") is not False:
        raise SmokeError("The verified identity does not match the synthetic permanent account.")
    token = session["access_token"]
    api = "/functions/v1/plants-api"
    digest = hashlib.sha256(photo).hexdigest()
    namespace = f"{EXPECTED_PROJECT_REF}/{owner}/{args.run_id}/{digest}"
    upload_id = str(uuid.uuid5(uuid.NAMESPACE_URL, namespace + "/upload"))
    operation_id = str(uuid.uuid5(uuid.NAMESPACE_URL, namespace + "/diagnosis"))
    ticket = request("Upload ticket", api + "/media/upload-ticket", "POST", {
        "operation_id": upload_id, "mime_type": "image/jpeg", "byte_size": len(photo), "content_sha256": digest,
    }, token)
    asset = str(uuid.UUID(ticket["photo_asset_id"]))
    upload = urllib.parse.urlparse(ticket["signed_upload_url"])
    if upload.path != f"{api}/media/uploads/{asset}" or ticket["storage_bucket"] != "analysis-inputs":
        raise SmokeError("Unexpected upload ticket path or bucket.")
    # The same run can resume after the original signed URL expired. Check
    # completion before resending bytes for a photo that may already be ready.
    ready = request("Photo completion", api + "/media/complete", "POST",
                    {"photo_asset_id": asset}, token, accepted=(200, 409))
    if ready.get("state") != "ready":
        ready = request("Private photo upload", ticket["signed_upload_url"], "PUT", photo, token)
    if ready != {"photo_asset_id": asset, "state": "ready"}:
        raise SmokeError("The upload did not return the expected ready photo.")
    started = time.monotonic()
    created = request("Diagnosis create", api + "/analysis/jobs", "POST", {
        "operation_id": operation_id, "mode": "diagnosis", "photo_asset_id": asset,
    }, token, accepted=(200, 202, 503))
    if "error" in created:
        if created["error"].get("code") == "PROVIDER_UNAVAILABLE":
            raise SmokeError("Diagnosis create returned HTTP 503 (PROVIDER_UNAVAILABLE).")
        raise SmokeError("Diagnosis create returned HTTP 503.")
    job = str(uuid.UUID(created["job_id"]))
    deadline = time.monotonic() + 65
    while time.monotonic() < deadline:
        value = request("Diagnosis status", f"{api}/analysis/jobs/{job}", token=token)
        status = value.get("status")
        if value.get("job_id") != job or value.get("mode") != "diagnosis":
            raise SmokeError("Diagnosis status did not match the requested job.")
        if status == "succeeded":
            result = value.get("result") or {}
            if (result.get("job_id") != job or result.get("mode") != "diagnosis" or
                    not isinstance(result.get("analysis_receipt"), str) or
                    result.get("identification_status") not in ("identified", "genus_only", "unknown", "out_of_scope") or
                    result.get("diagnosis_status") not in ("problem_detected", "healthy", "insufficient_data", "out_of_scope") or
                    value.get("quota_state") not in ("consumed", "released")):
                raise SmokeError("Terminal diagnosis result failed wire validation.")
            print(json.dumps({
                "status": "succeeded", "job_id": job, "quota_state": value["quota_state"],
                "quota_kind": value.get("quota_kind"),
                "elapsed_seconds": round(time.monotonic() - started, 2),
                "identification_status": result["identification_status"],
                "diagnosis_status": result["diagnosis_status"],
                "plant_id": result.get("plant_id"),
                "plant_display_name": result.get("plant_display_name"),
                "selected_condition_id": result.get("selected_condition_id"),
                "condition_display_name": result.get("condition_display_name"),
            }))
            return
        if status in ("failed", "expired"):
            code = value.get("error_code")
            code = code if isinstance(code, str) and re.fullmatch(r"[A-Z0-9_]{1,80}", code) else "UNKNOWN_ERROR"
            raise SmokeError(f"Staging diagnosis {job} {status}: {code}.")
        if status not in ("queued", "running"):
            raise SmokeError("Unrecognized job status.")
        time.sleep(1.5)
    raise SmokeError("Diagnosis polling exceeded the smoke deadline.")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, KeyError, TypeError) as error:
        if isinstance(error, SmokeError):
            raise SystemExit(str(error)) from None
        raise SystemExit("Staging diagnosis smoke could not verify the input or response.") from None
