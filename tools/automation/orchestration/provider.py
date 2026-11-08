"""Codex CLI adapter: exact session IDs, structured output and reported usage only."""

import json
from pathlib import Path
import re

from .process import error_excerpt, run
from .storage import atomic_json


REPLY_SCHEMA = {
    "type": "object", "additionalProperties": False,
    "properties": {
        "task_id": {"type": "string"}, "fingerprint": {"type": "string"},
        "status": {"type": "string", "enum": ["PASS", "FAIL", "BLOCKED"]},
        "summary": {"type": "string"}, "patch": {"type": "string"},
        "decisions": {"type": "array", "items": {"type": "string"}},
        "findings": {"type": "array", "description": "Only actionable unresolved defects. Must be [] for PASS; put informational notes in decisions.", "items": {"type": "string"}},
        "criteria": {"type": "array", "items": {
            "type": "object", "additionalProperties": False,
            "properties": {"id": {"type": "string"},
                           "status": {"type": "string", "enum": ["PASS", "FAIL", "BLOCKED"]},
                           "evidence": {"type": "array", "items": {"type": "string"}}},
            "required": ["id", "status", "evidence"]}}},
    "required": ["task_id", "fingerprint", "status", "summary", "patch", "decisions", "findings", "criteria"]}


def validate_reply(reply, task, fingerprint):
    if not isinstance(reply, dict) or set(reply) != set(REPLY_SCHEMA["required"]):
        raise ValueError("Invalid reply fields")
    if reply["task_id"] != task["id"] or reply["fingerprint"] != fingerprint:
        raise ValueError("Stale response or wrong task")
    if reply["status"] not in ("PASS", "FAIL", "BLOCKED"):
        raise ValueError("Invalid response status")
    for key in ("summary", "patch"):
        if not isinstance(reply[key], str):
            raise ValueError("Invalid response string")
    for key in ("decisions", "findings"):
        if not isinstance(reply[key], list) or not all(isinstance(x, str) for x in reply[key]):
            raise ValueError("Invalid response list")
    if not isinstance(reply["criteria"], list):
        raise ValueError("Invalid criteria response")
    for criterion in reply["criteria"]:
        if (not isinstance(criterion, dict) or set(criterion) != {"id", "status", "evidence"}
                or not isinstance(criterion["id"], str) or criterion["status"] not in ("PASS", "FAIL", "BLOCKED")
                or not isinstance(criterion["evidence"], list)
                or not all(isinstance(x, str) for x in criterion["evidence"])):
            raise ValueError("Invalid criterion evidence")
    return reply


def events(path):
    result = {"session_id": None, "completed": False, "errors": [], "usage": {}, "quota": None}
    tokens = ("input_tokens", "output_tokens", "cached_input_tokens")
    usages = []
    try:
        with path.open() as stream:
            for line in stream:
                try:
                    event = json.loads(line)
                except ValueError:
                    continue
                if not isinstance(event, dict):
                    continue
                kind = event.get("type")
                if kind == "thread.started":
                    result["session_id"] = event.get("thread_id")
                elif kind == "turn.completed":
                    result["completed"] = True
                    usages.append(event.get("usage", {}))
                elif kind in ("error", "turn.failed"):
                    result["errors"].append(json.dumps(event, ensure_ascii=False)[-2000:])
                elif kind in ("account.rate_limits.updated", "rate_limits.updated"):
                    result["quota"] = event.get("rate_limits")  # Only provider-reported data.
    except OSError:
        pass
    for key in tokens:
        value = usages[-1].get(key) if usages and isinstance(usages[-1], dict) else None
        result["usage"][key] = value if type(value) is int and value >= 0 else None
    result["usage_scope"] = "CLI-reported counters; per-turn/session scope not guaranteed"
    return result


def classify(message):
    # Used only for a failed invocation, never for text in a successful model answer.
    text = message.lower()
    if re.search(r"unauthorized|authentication|not logged in|invalid.*(?:token|api.key)|401\b", text):
        return "auth"
    if re.search(r"usage.limit|quota.exceeded|rate.limit|too many requests|429\b", text):
        return "limit"
    if re.search(r"model.*(?:unavailable|not found|not supported)|503\b|service unavailable", text):
        return "unavailable"
    if re.search(r"session.*(?:not found|missing)|thread.*not found", text):
        return "session_lost"
    if "timeout" in text:
        return "timeout"
    return "cli_error"


class Codex:
    name = "codex"

    def __init__(self, executable, timeout=900):
        self.executable, self.timeout = str(executable), timeout

    def command(self, root, directory, model, effort, session=None, ephemeral=False):
        argv = [self.executable, "--no-daemon", "-a", "never", "exec", "--ignore-user-config",
                "--sandbox", "read-only", "--cd", str(root),
                "-c", "features.apps=false", "-c", "features.hooks=false",
                "-c", 'web_search="disabled"', "-c", f"model_reasoning_effort={json.dumps(effort)}"]
        if session:
            if not re.fullmatch(r"[a-zA-Z0-9_-]+", session):
                raise ValueError("Invalid explicit CLI session ID")
            argv += ["resume", session]
        elif ephemeral:
            argv += ["--ephemeral"]
        argv += ["--model", model, "--json", "--output-schema", str(directory / "schema.json"),
                 "--output-last-message", str(directory / "answer.json"), "-"]
        return argv

    def invoke(self, root, directory, task, fingerprint, prompt, model, effort, session=None, ephemeral=False):
        directory.mkdir(parents=True, exist_ok=False)
        atomic_json(directory / "schema.json", REPLY_SCHEMA)
        (directory / "prompt.txt").write_text(prompt)
        result = run(self.command(root, directory, model, effort, session, ephemeral), root,
                     directory, self.timeout, input_text=prompt)
        parsed = events(directory / "stdout.log")
        result.update(parsed)
        error = error_excerpt([directory / "stderr.log"], 3000)
        try:
            reply = validate_reply(json.loads((directory / "answer.json").read_text()), task, fingerprint)
        except (OSError, ValueError, TypeError) as exc:
            reply = None
            error += "\n" + str(exc)
        if result["status"] != "PASS" or not parsed["completed"] or parsed["errors"] or not reply:
            message = "\n".join(parsed["errors"] + [error, result.get("error", "")])
            result.update(status="FAIL", category=classify(message), error=message[-3000:])
        result["reply"] = reply
        return result
