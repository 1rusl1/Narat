"""CLI adapters (Codex and Agy): exact session IDs, structured output and reported usage only."""

import json
import os
from pathlib import Path
import re
import sqlite3
import time
import urllib.request

from .process import error_excerpt, run
from .storage import atomic_json

BUNDLED_AGY = Path("/Applications/Gemini.app/Contents/Helpers/agy")
DEFAULT_AGY_APP_DATA = Path.home() / ".gemini/antigravity"
AGY_MODEL_EFFORTS = ("low", "medium", "high")


def extract_json_object(text):
    """Parse JSON object from model response, stripping optional markdown fences."""
    cleaned = text.strip()
    if cleaned.startswith("```"):
        cleaned = re.sub(r"^```(?:json)?\s*\n?", "", cleaned, count=1)
        cleaned = re.sub(r"\n?```\s*$", "", cleaned, count=1).strip()
    try:
        return json.loads(cleaned, strict=False)
    except ValueError:
        start, end = cleaned.find("{"), cleaned.rfind("}")
        if start != -1 and end > start:
            return json.loads(cleaned[start:end + 1], strict=False)
        raise


def resolve_agy_model(model, effort):
    """Apply reasoning effort suffix for tiered Agy models if not already explicit."""
    if effort in AGY_MODEL_EFFORTS and re.fullmatch(r"gemini-(?:4-argon|3\.8-flash)", model):
        return f"{model}-{effort}"
    return model


def discover_agy_hub(app_data_dir=DEFAULT_AGY_APP_DATA, root=None):
    """Discover local Gemini.app hub address, CSRF token and project ID."""
    address = os.environ.get("ANTIGRAVITY_LS_ADDRESS")
    csrf = os.environ.get("ANTIGRAVITY_CSRF_TOKEN")
    project_id = os.environ.get("ANTIGRAVITY_PROJECT_ID")
    cli_log = Path(app_data_dir) / "cli.log"
    if not address and cli_log.exists():
        try:
            text = cli_log.read_text(errors="replace")
            matches = re.findall(r"listening on random port at (\d+) for HTTP\b", text)
            if matches:
                address = f"localhost:{matches[-1]}"
        except OSError:
            pass
    if address and not csrf:
        host_port = address.replace("localhost:", "127.0.0.1:")
        try:
            with urllib.request.urlopen(f"http://{host_port}/", timeout=3) as resp:
                html = resp.read(65536).decode("utf-8", errors="replace")
            match = re.search(r'"csrfToken"\s*:\s*"([^"]+)"', html)
            if match:
                csrf = match.group(1)
        except Exception:
            pass
    db_path = Path(app_data_dir) / "conversation_summaries.db"
    if not project_id and db_path.exists():
        try:
            uri_filter = f"%{Path(root).name}%" if root else "%"
            with sqlite3.connect(f"file:{db_path}?mode=ro", uri=True, timeout=3) as conn:
                row = conn.execute(
                    "SELECT project_id FROM conversation_summaries "
                    "WHERE project_id != '' AND workspace_uris LIKE ? "
                    "ORDER BY last_modified_time DESC LIMIT 1",
                    (uri_filter,),
                ).fetchone()
                if not row:
                    row = conn.execute(
                        "SELECT project_id FROM conversation_summaries "
                        "WHERE project_id != '' ORDER BY last_modified_time DESC LIMIT 1"
                    ).fetchone()
                if row:
                    project_id = row[0]
        except Exception:
            pass
    return {"address": address, "csrf": csrf, "project_id": project_id}


def agy_transcript_events(path, min_step=0):
    """Parse Agy transcript.jsonl entries from min_step onwards (preferring transcript_full.jsonl when present)."""
    result = {"completed": False, "errors": [], "usage": {}, "quota": None, "answer_text": None, "steps": 0}
    tokens = ("input_tokens", "output_tokens", "cached_input_tokens")
    usages = []
    full_path = path.with_name("transcript_full.jsonl")
    source_path = full_path if full_path.exists() else path
    try:
        with source_path.open() as stream:
            for line in stream:
                try:
                    event = json.loads(line)
                except ValueError:
                    continue
                if not isinstance(event, dict):
                    continue
                idx = event.get("step_index", 0)
                result["steps"] = max(result["steps"], idx + 1 if isinstance(idx, int) else 0)
                if isinstance(idx, int) and idx < min_step:
                    continue
                status = event.get("status")
                kind = event.get("type")
                if status == "ERROR":
                    result["errors"].append(json.dumps(event, ensure_ascii=False)[-2000:])
                if kind == "PLANNER_RESPONSE" and status == "DONE":
                    usages.append({
                        "input_tokens": event.get("input_tokens"),
                        "output_tokens": event.get("output_tokens"),
                        "cached_input_tokens": event.get("cache_read_tokens"),
                    })
                    if not event.get("tool_calls") and isinstance(event.get("content"), str):
                        result["completed"] = True
                        result["answer_text"] = event["content"]
    except OSError:
        pass
    for key in tokens:
        value = usages[-1].get(key) if usages and isinstance(usages[-1], dict) else None
        result["usage"][key] = value if type(value) is int and value >= 0 else None
    result["usage_scope"] = "CLI-reported counters; per-turn/session scope not guaranteed"
    return result


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
    if re.search(r"unauthorized|authentication|not logged in|invalid.*(?:token|api.key)|unauthenticated|401\b", text):
        return "auth"
    if re.search(r"usage.limit|quota.exceeded|rate.limit|too many requests|resource_exhausted|429\b", text):
        return "limit"
    if re.search(r"model.*(?:unavailable|not found|not supported)|503\b|service unavailable|hub unavailable", text):
        return "unavailable"
    if re.search(r"session.*(?:not found|missing)|thread.*not found|conversation.*not found|cascade not found", text):
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

    def invoke(self, root, directory, task, fingerprint, prompt, model, effort, session=None, ephemeral=False, provider=None):
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


class Agy:
    """Antigravity / Gemini.app CLI adapter via local hub agentapi with read-only research profile."""
    name = "agy"

    def __init__(self, executable=BUNDLED_AGY, timeout=900, app_data_dir=DEFAULT_AGY_APP_DATA, poll_interval=0.2):
        self.executable = str(executable)
        self.timeout = timeout
        self.app_data_dir = Path(app_data_dir)
        self.poll_interval = poll_interval

    def command(self, root, directory, model, effort, session=None, ephemeral=False, prompt=""):
        resolved_model = resolve_agy_model(model, effort)
        if session:
            if not re.fullmatch(r"[a-zA-Z0-9_-]+", session):
                raise ValueError("Invalid explicit Agy session ID")
            return [self.executable, "agentapi", "send-message", session, prompt]
        return [self.executable, "agentapi", "new-conversation", f"--model={resolved_model}",
                "--profile=research", "--title=Orchestrator Task", prompt]

    def transcript_path(self, session_id):
        return self.app_data_dir / "brain" / session_id / ".system_generated/logs/transcript.jsonl"

    def _is_conversation_idle(self, session_id):
        db_path = self.app_data_dir / "conversation_summaries.db"
        if not db_path.exists():
            return True
        try:
            with sqlite3.connect(f"file:{db_path}?mode=ro", uri=True, timeout=2) as conn:
                row = conn.execute(
                    "SELECT status, not_fully_idle FROM conversation_summaries WHERE conversation_id = ?",
                    (session_id,),
                ).fetchone()
                if not row:
                    return True
                status, not_fully_idle = row
                return status == "CASCADE_RUN_STATUS_IDLE" and not bool(not_fully_idle)
        except Exception:
            return True

    def invoke(self, root, directory, task, fingerprint, prompt, model, effort, session=None, ephemeral=False, provider=None):
        directory.mkdir(parents=True, exist_ok=False)
        atomic_json(directory / "schema.json", REPLY_SCHEMA)
        schema_prompt = (
            prompt + "\n\nCRITICAL: Return ONLY a raw JSON object matching this exact JSON Schema "
            "(no markdown fences, no commentary):\n" + json.dumps(REPLY_SCHEMA)
        )
        (directory / "prompt.txt").write_text(schema_prompt)
        hub = discover_agy_hub(self.app_data_dir, root)
        extra_env = {}
        if hub.get("address"):
            extra_env["ANTIGRAVITY_LS_ADDRESS"] = hub["address"]
        if hub.get("csrf"):
            extra_env["ANTIGRAVITY_CSRF_TOKEN"] = hub["csrf"]
        if hub.get("project_id"):
            extra_env["ANTIGRAVITY_PROJECT_ID"] = hub["project_id"]
        min_step = 0
        if session:
            tpath = self.transcript_path(session)
            if tpath.exists():
                min_step = agy_transcript_events(tpath, min_step=0)["steps"]
        started = time.monotonic()
        argv = self.command(root, directory, model, effort, session, ephemeral, prompt=schema_prompt)
        result = run(argv, root, directory, self.timeout, extra_env=extra_env)
        stdout_text = (directory / "stdout.log").read_text(errors="replace") if (directory / "stdout.log").exists() else ""
        session_id = session
        rpc_error = None
        try:
            payload = json.loads(stdout_text) if stdout_text.strip() else {}
            if isinstance(payload, dict):
                if payload.get("error"):
                    rpc_error = str(payload["error"])
                new_conv = payload.get("response", {}).get("newConversation", {})
                if new_conv.get("conversationId"):
                    session_id = new_conv["conversationId"]
        except ValueError:
            pass
        parsed = {"completed": False, "errors": [], "usage": {"input_tokens": None, "output_tokens": None, "cached_input_tokens": None},
                  "quota": None, "answer_text": None, "usage_scope": "CLI-reported counters; per-turn/session scope not guaranteed"}
        if rpc_error:
            parsed["errors"].append(rpc_error)
        elif result["status"] == "PASS" and session_id:
            tpath = self.transcript_path(session_id)
            deadline = started + self.timeout
            while time.monotonic() < deadline:
                if tpath.exists():
                    parsed = agy_transcript_events(tpath, min_step=min_step)
                    if parsed["errors"] or (parsed["completed"] and self._is_conversation_idle(session_id)):
                        break
                time.sleep(self.poll_interval)
            else:
                result["error"] = "timeout"
        result["elapsed_seconds"] = round(time.monotonic() - started, 3)
        result["session_id"] = session_id
        result.update({k: parsed[k] for k in ("completed", "errors", "usage", "quota", "usage_scope")})
        error_logs = [directory / "stderr.log"]
        if result["status"] != "PASS" or not session_id:
            error_logs.append(directory / "stdout.log")
        error = error_excerpt(error_logs, 3000)
        reply = None
        if parsed.get("answer_text"):
            try:
                answer_obj = extract_json_object(parsed["answer_text"])
                atomic_json(directory / "answer.json", answer_obj)
                reply = validate_reply(answer_obj, task, fingerprint)
            except (OSError, ValueError, TypeError) as exc:
                error += "\n" + str(exc)
        else:
            error += "\nMissing model answer in Agy transcript"
        if result["status"] != "PASS" or not parsed["completed"] or parsed["errors"] or not reply or result.get("error") == "timeout":
            message = "\n".join(parsed["errors"] + [error, result.get("error", "")])
            result.update(status="FAIL", category=classify(message), error=message[-3000:])
        result["reply"] = reply
        return result


class MultiProvider:
    """Routes model invocations to the configured CLI adapter ('codex' or 'agy')."""

    def __init__(self, providers, default="codex"):
        self.providers = dict(providers)
        self.default = default

    def invoke(self, root, directory, task, fingerprint, prompt, model, effort, session=None, ephemeral=False, provider=None):
        name = provider or self.default
        if ":" in model and provider is None:
            prefix, rest = model.split(":", 1)
            if prefix in self.providers:
                name, model = prefix, rest
        adapter = self.providers.get(name)
        if adapter is None:
            raise ValueError(f"Unsupported provider: {name}")
        return adapter.invoke(root, directory, task, fingerprint, prompt, model, effort,
                              session=session, ephemeral=ephemeral)
