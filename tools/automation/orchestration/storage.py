"""Durable state and bounded retry accounting, independent of a model provider."""

import hashlib
import json
import os
from pathlib import Path
import tempfile


def digest(value):
    if not isinstance(value, bytes):
        value = json.dumps(value, sort_keys=True, ensure_ascii=False).encode()
    return hashlib.sha256(value).hexdigest()


def atomic_text(path, text):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix=".write-", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as stream:
            stream.write(text)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, path)
        directory = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def atomic_json(path, value):
    atomic_text(path, json.dumps(value, ensure_ascii=False, indent=2) + "\n")


class State:
    def __init__(self, path, config, tasks):
        self.path = Path(path)
        identity = digest({"config": config, "tasks": tasks})
        if self.path.exists():
            self.data = json.loads(self.path.read_text())
            if self.data.get("identity") != identity or self.data.get("version") != 1:
                raise ValueError("Manifest/config changed: use a new run ID")
        else:
            self.data = {"version": 1, "identity": identity, "tasks": {
                task["id"]: {"status": "PENDING", "phase": "developer", "counts": {},
                             "sessions": {}, "checks": {}, "calls": [], "failures": [],
                             "feedback": [], "summary": {}, "compactions": []}
                for task in tasks}}
            self.save()

    def save(self):
        atomic_json(self.path, self.data)

    def reserve(self, task_id, role, maximum):
        task = self.data["tasks"][task_id]
        count = task["counts"].get(role, 0)
        if count >= maximum:
            task.update(status="BLOCKED", reason=f"Retry budget exhausted: {role}")
            self.save()
            return False
        task["counts"][role] = count + 1  # Persist before spending quota / starting a child.
        self.save()
        return True

    def failure(self, task_id, fingerprint, error, max_same):
        task = self.data["tasks"][task_id]
        signature = digest({"tree": fingerprint, "error": error})
        task["failures"].append(signature)
        repeats = sum(x == signature for x in task["failures"])
        if repeats >= max_same:
            task.update(status="BLOCKED", reason="No progress: repeated error on unchanged files")
        task["feedback"] = error if isinstance(error, list) else [error]
        self.save()
        return task["status"] != "BLOCKED"


def checkpoint(task, record):
    """Retain structured conclusions, never tool transcripts or model reasoning."""
    return {"goal": task["description"], "acceptance_criteria": task["acceptance_criteria"],
            "constraints": task["constraints"], "files": record.get("changed_files", []),
            "decisions": record.get("summary", {}).get("decisions", []),
            "changes": record.get("summary", {}).get("summary", ""),
            "unresolved": record.get("feedback", []),
            "tests": record.get("checks", {}), "next_action": record["phase"]}
