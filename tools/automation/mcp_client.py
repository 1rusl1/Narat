"""Small synchronous MCP stdio client for the local, serial Simulator smoke.

No sampling, elicitation or remote transports. All calls have a bounded timeout.
Protocol: https://modelcontextprotocol.io/specification/2025-06-18/basic/transports
"""

import json
import os
from pathlib import Path
import selectors
import shutil
import subprocess
import time

from doctor import ROOT, stop_process, write_json


PACKAGES = Path(__file__).resolve().parent / "node_modules"


def server_command(name):
    entry = {
        "build": Path(__file__).with_name("run_build_mcp.mjs"),
        "mobile": PACKAGES / "@mobilenext/mobile-mcp/lib/index.js",
    }[name]
    if not entry.is_file() or not (PACKAGES / "mobilebuildmcp/package.json").exists():
        raise RuntimeError("Сначала выполните npm ci --prefix tools/automation --ignore-scripts")
    node = shutil.which("node")
    if not node:
        raise RuntimeError("Node.js отсутствует в PATH")
    return [node, str(entry)]


def server_environment():
    cache = ROOT / "tools/automation/.cache"
    cache.mkdir(parents=True, exist_ok=True)
    return dict(os.environ, MOBILEBUILDMCP_SENTRY_DISABLED="true",
                XCODEBUILDMCP_SENTRY_DISABLED="true", XDG_CACHE_HOME=str(cache),
                MOBILECLI_HOME=str(cache / "mobilecli"), MOBILEMCP_DISABLE_TELEMETRY="1",
                MOBILEWRIGHT_DISABLE_TELEMETRY="1", npm_config_cache=str(cache / "npm"))


class MCPError(RuntimeError):
    pass


class StdioMCP:
    def __init__(self, name, run_dir, command=None, env=None):
        self.name = name
        self.run_dir = Path(run_dir)
        self.counter = 0
        self.buffer = b""
        self.selector = selectors.DefaultSelector()
        self.stderr = (self.run_dir / f"{name}.stderr.log").open("wb")
        self.wire = (self.run_dir / f"{name}.rpc.jsonl").open("w")
        self.process = None
        try:
            self.process = subprocess.Popen(command or server_command(name), cwd=ROOT,
                env=env or server_environment(), stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                stderr=self.stderr, start_new_session=True)
            self.selector.register(self.process.stdout, selectors.EVENT_READ)
        except BaseException:
            self.close()
            raise

    def send(self, message):
        self.wire.write(json.dumps({"direction": "send", "message": message}) + "\n")
        self.wire.flush()
        payload = (json.dumps(message) + "\n").encode()
        self.process.stdin.write(payload)
        self.process.stdin.flush()

    def receive(self, deadline):
        while b"\n" not in self.buffer:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not self.selector.select(remaining):
                raise MCPError(f"{self.name}: timeout waiting for MCP response")
            chunk = os.read(self.process.stdout.fileno(), 65536)
            if not chunk:
                raise MCPError(f"{self.name}: server exited before the response")
            self.buffer += chunk
            if len(self.buffer) > 64 * 1024 * 1024:
                raise MCPError("MCP message exceeds 64 MiB")
        line, self.buffer = self.buffer.split(b"\n", 1)
        try:
            message = json.loads(line)
        except (ValueError, UnicodeError) as error:
            raise MCPError(f"{self.name}: invalid JSON on stdout") from error
        if not isinstance(message, dict) or message.get("jsonrpc") != "2.0":
            raise MCPError(f"{self.name}: invalid JSON-RPC message")
        self.wire.write(json.dumps({"direction": "receive", "message": message}) + "\n")
        self.wire.flush()
        return message

    def request(self, method, params=None, timeout=60):
        self.counter += 1
        request_id = self.counter
        self.send({"jsonrpc": "2.0", "id": request_id, "method": method, "params": params or {}})
        deadline = time.monotonic() + timeout
        while True:
            message = self.receive(deadline)
            if "method" in message:
                if "id" in message:
                    # Advertise no capabilities and never let a server ask the model/user to act.
                    result = {"result": {}} if message["method"] == "ping" else {
                        "error": {"code": -32601, "message": "Client capability is not supported"}}
                    self.send({"jsonrpc": "2.0", "id": message["id"], **result})
                continue
            if message.get("id") != request_id:
                raise MCPError(f"{self.name}: response ID differs from the outstanding request")
            if "error" in message:
                raise MCPError(f"{self.name}: RPC error: {message['error']}")
            if "result" not in message:
                raise MCPError(f"{self.name}: response has no result")
            return message["result"]

    def initialize(self):
        info = self.request("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
            "clientInfo": {"name": "narat-simulator-smoke", "version": "0.1.0"}})
        if info.get("protocolVersion") != "2025-06-18":
            raise MCPError(f"Unsupported negotiated MCP protocol: {info.get('protocolVersion')}")
        self.send({"jsonrpc": "2.0", "method": "notifications/initialized"})
        write_json(self.run_dir / f"{self.name}.initialize.json", info)
        return info

    def tools(self):
        tools = []
        params = {}
        seen = set()
        for _ in range(20):
            page = self.request("tools/list", params)
            tools.extend(page.get("tools", []))
            cursor = page.get("nextCursor")
            if not cursor:
                write_json(self.run_dir / f"{self.name}.tools.json", tools)
                return tools
            if cursor in seen:
                raise MCPError("Repeated tools/list cursor")
            seen.add(cursor)
            params = {"cursor": cursor}
        raise MCPError("Too many tools/list pages")

    def call(self, name, arguments, timeout=60):
        result = self.request("tools/call", {"name": name, "arguments": arguments}, timeout)
        write_json(self.run_dir / f"{self.name}.{self.counter:03d}.{name}.json", result)
        if result.get("isError") or result.get("structuredContent", {}).get("didError"):
            text = "\n".join(x.get("text", "") for x in result.get("content", []))
            raise MCPError(f"{name}: {text[:2000]}")
        return result

    def close(self):
        if self.process is not None:
            if self.process.stdin:
                self.process.stdin.close()
            try:
                self.process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                stop_process(self.process)
            if self.process.stdout:
                self.process.stdout.close()
        self.selector.close()
        self.stderr.close()
        self.wire.close()

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.close()
