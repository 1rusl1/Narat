#!/usr/bin/env python3
"""Install the locked Mobile MCP helper on a local iOS Simulator (Apple Silicon)."""

import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import platform
import shutil
import signal
import sys
import urllib.request
import uuid

from doctor import Doctor, ROOT, RUNS, SIMULATOR, exclusive_run, new_run_path
from mcp_client import server_environment


LOCK_PATH = Path(__file__).with_name("mobile-agent.lock.json")


def checksum(path):
    with path.open("rb") as source: return hashlib.file_digest(source, "sha256").hexdigest()


def download_verified(lock, directory):
    target = directory / lock["filename"]
    if target.exists() and checksum(target) == lock["sha256"]: return target
    request = urllib.request.Request(lock["url"], headers={"Accept": "application/octet-stream", "User-Agent": "narat-local-setup"})
    partial = target.with_suffix(".partial")
    directory.mkdir(parents=True, exist_ok=True)
    with urllib.request.urlopen(request, timeout=45) as source, partial.open("wb") as out:
        shutil.copyfileobj(source, out)
    if checksum(partial) != lock["sha256"]: raise ValueError("UI agent SHA256 mismatch; installation stopped")
    partial.replace(target)
    return target


def setup(doctor, device):
    if (platform.system(), platform.machine()) != ("Darwin", "arm64"):
        raise ValueError("Current UI-agent lock supports macOS Apple Silicon only")
    lock = json.loads(LOCK_PATH.read_text())
    package = Path(__file__).with_name("node_modules") / "@mobilenext/mobilecli-darwin-arm64"
    if json.loads((package / "package.json").read_text())["version"] != lock["mobilecli_version"]:
        raise ValueError("Review UI-agent version before updating mobilecli")
    cli = package / "mobilecli-darwin-arm64"
    listing = doctor.command("simulators", ["xcrun", "simctl", "list", "devices", "available", "--json"])
    if listing["status"] != "PASS": raise RuntimeError("Simulator unavailable")
    devices = json.loads(doctor.read_stdout(listing))["devices"]
    if not any(d["udid"] == device for runtime, ds in devices.items() if ".iOS-" in runtime for d in ds):
        raise ValueError("Target must be an available local iOS Simulator")
    env = server_environment()
    status = doctor.command("agent-before", [str(cli), "agent", "status", "--device", device], env=env)
    # mobilecli uses exit 0 + status=fail to report an absent helper. Record this explicitly.
    before = json.loads(doctor.read_stdout(status))
    if before.get("status") == "ok":
        if before.get("data", {}).get("agent", {}).get("version") != lock["agent_version"]:
            raise ValueError("Another UI-agent version is installed; review before replacing it")
    else:
        if before.get("status") != "fail" or before.get("data", {}).get("message") != "Agent is not installed on the device":
            raise RuntimeError("Could not determine whether the UI agent is installed")
        status.update(status="INFO", expected_absence=True)
        doctor.save()
        archive = download_verified(lock, ROOT / "tools/automation/.cache/mobilecli")
        doctor.add("agent-archive", "PASS", sha256=checksum(archive), version=lock["agent_version"])
        install = doctor.command("agent-install", [str(cli), "apps", "install", str(archive), "--device", device], 90, env=env)
        if install["status"] != "PASS": raise RuntimeError("UI agent installation failed")
    result = doctor.command("agent-after", [str(cli), "agent", "status", "--device", device], env=env)
    data = json.loads(doctor.read_stdout(result)) if result["status"] == "PASS" else {}
    if data.get("status") != "ok" or data.get("data", {}).get("agent", {}).get("version") != lock["agent_version"]:
        raise ValueError("Installed UI agent version was not confirmed")
    doctor.add("agent-version-confirmed", "PASS", device=device, version=lock["agent_version"])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--simulator", default=SIMULATOR)
    parser.add_argument("--run-id", default="agent-" + datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-" + uuid.uuid4().hex[:6])
    args = parser.parse_args()
    def interrupted(signum, frame): raise InterruptedError(f"signal {signum}")
    signal.signal(signal.SIGTERM, interrupted)
    try:
        with exclusive_run(RUNS):
            doctor = Doctor(new_run_path(RUNS, args.run_id))
            doctor.report["scope"] = "mobile-ui-agent-setup"
            try:
                setup(doctor, args.simulator)
                return doctor.finish(True)
            except (KeyboardInterrupt, InterruptedError):
                doctor.add("agent-setup", "FAIL", reason="interrupted")
                doctor.finish(False)
                return 130
            except (OSError, ValueError, RuntimeError, KeyError) as error:
                doctor.add("agent-setup", "FAIL", reason=str(error))
                return doctor.finish(False)
    except (OSError, ValueError, RuntimeError) as error:
        print(error, file=sys.stderr)
        return 2


if __name__ == "__main__": sys.exit(main())
