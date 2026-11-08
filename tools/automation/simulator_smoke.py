#!/usr/bin/env python3
"""Stage 2: build/launch via MobileBuildMCP, inspect/tap/capture via Mobile MCP."""

import argparse
from contextlib import ExitStack
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import shutil
import signal
import struct
import sys
import time
import uuid

from doctor import Doctor, LOCAL_UI_SETTINGS, ROOT, RUNS, SIMULATOR, exclusive_run, local_ui_info_ok, new_run_path, write_json
from mcp_client import MCPError, StdioMCP


def text_content(result):
    return "\n".join(x.get("text", "") for x in result.get("content", []) if x.get("type") == "text")


def elements_from_result(result):
    text = text_content(result)
    prefix = "Found these elements on screen: "
    if not text.startswith(prefix):
        raise MCPError("Unexpected Mobile MCP accessibility response")
    elements = json.loads(text[len(prefix):])
    if not isinstance(elements, list) or not all(isinstance(x, dict) for x in elements):
        raise MCPError("Accessibility response must be an array of elements")
    return elements


def element_by_id(elements, identifier):
    matches = [x for x in elements if x.get("identifier") == identifier or x.get("name") == identifier]
    if len(matches) != 1 or matches[0].get("enabled") is False:
        raise MCPError(f"Expected one enabled element {identifier}, found {len(matches)}")
    return matches[0]


def wait_for_ui(mobile, device, required, timeout=30):
    deadline = time.monotonic() + timeout
    while True:
        elements = elements_from_result(mobile.call("mobile_list_elements_on_screen", {"device": device, "format": "json"}, 90))
        try:
            for identifier in required: element_by_id(elements, identifier)
            return elements
        except MCPError:
            if time.monotonic() >= deadline: raise
            time.sleep(1)


def png_evidence(path):
    data = path.read_bytes()
    if len(data) < 24 or data[:8] != b"\x89PNG\r\n\x1a\n" or data[12:16] != b"IHDR":
        raise MCPError("Screenshot is not a PNG")
    if b"IDAT" not in data or not data.endswith(b"\x00\x00\x00\x00IEND\xaeB`\x82"):
        raise MCPError("Screenshot PNG is incomplete")
    width, height = struct.unpack(">II", data[16:24])
    if not width or not height: raise MCPError("Empty screenshot dimensions")
    return {"path": path.name, "width": width, "height": height, "sha256": hashlib.sha256(data).hexdigest()}


def run_smoke(doctor, device):
    with ExitStack() as stack:
        build = stack.enter_context(StdioMCP("build", doctor.run_dir))
        mobile = stack.enter_context(StdioMCP("mobile", doctor.run_dir))
        for name, client in [("build", build), ("mobile", mobile)]:
            info = client.initialize()
            listing = client.tools()
            doctor.add(f"{name}-handshake", "PASS", server=info["serverInfo"], tool_count=len(listing))
        derived = ROOT / "DerivedData/Automation"
        build.call("session_set_defaults", {"projectPath": str(ROOT / "ios/Plants.xcodeproj"),
            "scheme": "Plants", "configuration": "Debug", "simulatorId": device,
            "simulatorPlatform": "iOS Simulator", "derivedDataPath": str(derived),
            "preferXcodebuild": True, "bundleId": "app.narat.plants", "persist": False})
        listing = build.call("list_sims", {"enabled": True})["structuredContent"]["data"]["simulators"]
        selected = [x for x in listing if x["simulatorId"] == device and x["isAvailable"] and x["runtime"].startswith("iOS ")]
        if len(selected) != 1: raise MCPError("Selected local iOS Simulator is unavailable")
        if selected[0]["state"] != "Booted": build.call("boot_sim", {}, 180)
        devices = json.loads(text_content(mobile.call("mobile_list_available_devices", {})))["devices"]
        if not any(x["id"] == device and x["type"] == "simulator" for x in devices):
            raise MCPError("Mobile MCP does not see the selected local Simulator")
        doctor.add("selected-simulator", "PASS", device=selected[0])
        print("Building Plants via MCP…", flush=True)
        extra = ["-clonedSourcePackagesDirPath", str(derived / "SourcePackages"),
                 "-packageCachePath", str(derived / "PackageCache"),
                 "-onlyUsePackageVersionsFromResolvedFile", "-skipPackageUpdates", *LOCAL_UI_SETTINGS]
        result = build.call("build_sim", {"extraArgs": extra}, 1200)["structuredContent"]["data"]
        if result["summary"]["status"] != "SUCCEEDED": raise MCPError("Build did not succeed")
        log = Path(result["artifacts"]["buildLogPath"]).expanduser().resolve()
        if not log.is_relative_to(ROOT): raise MCPError("Build log escaped the project; check runtime launcher")
        shutil.copyfile(log, doctor.run_dir / "xcodebuild.log")
        doctor.add("mcp-build", "PASS", duration_ms=result["summary"]["durationMs"], log="xcodebuild.log")
        response = build.call("get_sim_app_path", {"platform": "iOS Simulator"})
        app = Path(response["structuredContent"]["data"]["artifacts"]["appPath"]).resolve()
        if not app.is_relative_to(derived) or not local_ui_info_ok(app / "Info.plist"):
            raise MCPError("Built app path or backend isolation is invalid")
        doctor.add("local-ui-configuration", "PASS", app_path=str(app))
        build.call("install_app_sim", {"appPath": str(app)}, 120)
        # The first UI-agent startup can foreground SpringBoard. Warm it before launching Narat.
        mobile.call("mobile_list_elements_on_screen", {"device": device, "format": "json"}, 120)
        doctor.add("ui-agent-ready", "PASS")
        build.call("launch_app_sim", {}, 90)
        welcome = wait_for_ui(mobile, device, ["welcome.title", "welcome.intent.problem", "welcome.intent.care"])
        write_json(doctor.run_dir / "welcome.elements.json", welcome)
        before = doctor.run_dir / "welcome.png"
        mobile.call("mobile_save_screenshot", {"device": device, "saveTo": str(before)}, 90)
        doctor.add("welcome-ui", "PASS", screenshot=png_evidence(before))
        # Re-read immediately before tapping: refs are valid for the current layout only.
        welcome = wait_for_ui(mobile, device, ["welcome.intent.care"])
        target = element_by_id(welcome, "welcome.intent.care")
        if not target.get("ref"): raise MCPError("The care button has no native element ref")
        mobile.call("mobile_click_on_screen_at_coordinates", {"device": device, "ref": target["ref"]})
        after_elements = wait_for_ui(mobile, device, ["care.method.title", "care.method.scan", "care.method.catalogue"])
        if any(x.get("identifier") == "welcome.intent.care" for x in after_elements):
            raise MCPError("Welcome care button is still visible after navigation")
        write_json(doctor.run_dir / "care-method.elements.json", after_elements)
        after = doctor.run_dir / "care-method.png"
        mobile.call("mobile_save_screenshot", {"device": device, "saveTo": str(after)}, 90)
        proof = png_evidence(after)
        if proof["sha256"] == png_evidence(before)["sha256"]: raise MCPError("Screenshots did not change")
        doctor.add("care-navigation", "PASS", tapped_identifier="welcome.intent.care", screenshot=proof,
                   mode="local-ui; backend disabled; locale acceptance not performed")


def main():
    parser = argparse.ArgumentParser(description="MCP build + real Simulator tap/screenshot smoke")
    parser.add_argument("--simulator", default=SIMULATOR)
    parser.add_argument("--run-id", default="mcp-" + datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-" + uuid.uuid4().hex[:6])
    args = parser.parse_args()
    def interrupted(signum, frame): raise InterruptedError(f"signal {signum}")
    signal.signal(signal.SIGTERM, interrupted)
    try:
        with exclusive_run(RUNS):
            doctor = Doctor(new_run_path(RUNS, args.run_id))
            doctor.report["scope"] = "stage-2-mcp-simulator-smoke"
            try:
                run_smoke(doctor, args.simulator)
                return doctor.finish(True)
            except (KeyboardInterrupt, InterruptedError):
                doctor.add("simulator-smoke", "FAIL", reason="interrupted")
                doctor.finish(False)
                return 130
            except (MCPError, OSError, ValueError, KeyError, TypeError) as error:
                doctor.add("simulator-smoke", "FAIL", reason=str(error))
                return doctor.finish(False)
    except (OSError, ValueError, RuntimeError) as error:
        print(str(error), file=sys.stderr)
        return 2


if __name__ == "__main__": sys.exit(main())
