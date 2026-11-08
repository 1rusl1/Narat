"""Explicit contracts, deterministic file discovery and progressive disclosure."""

import json
from pathlib import Path, PurePosixPath
import re
import subprocess

from .storage import checkpoint


PROJECT_START = "<!-- orchestrator:project-state -->"
PROJECT_END = "<!-- /orchestrator:project-state -->"
SUMMARY_START = "<!-- orchestrator:task-summary -->"
SUMMARY_END = "<!-- /orchestrator:task-summary -->"
LEVELS = {"low": 0, "medium": 1, "high": 2}
PROTECTED = (".git", ".agents", ".codex", "tools/automation", "docs/handoff_status.md",
             "docs/validation/automation", "specs/001-plants-ios-mvp/tasks.md", "AGENTS.md")


def safe_path(root, name, writable=False):
    p = PurePosixPath(name)
    if (not name or p.is_absolute() or ".." in p.parts or "\\" in name
            or str(p) != name or any(ord(x) < 32 for x in name)):
        raise ValueError(f"Invalid relative path: {name!r}")
    target = root / name
    if not target.resolve().is_relative_to(root.resolve()):
        raise ValueError(f"Path escapes project: {name}")
    if any(part.is_symlink() for part in [target, *target.parents] if part != root.parent):
        raise ValueError(f"Symlink is not an allowed task file: {name}")
    if writable and (any(name == x or name.startswith(x + "/") for x in PROTECTED)
                     or p.name in ("AGENTS.md", ".env") or p.name.endswith(".local.xcconfig")
                     or p.name.startswith(".env.") or p.suffix in (".key", ".pem", ".p8")):
        raise ValueError(f"Controller-owned or secret file: {name}")
    return target


def nonempty_strings(values):
    return isinstance(values, list) and bool(values) and all(isinstance(x, str) and x.strip() for x in values)


def validate(config, tasks, root):
    if config.get("version") != 1 or not isinstance(tasks, list) or not tasks:
        raise ValueError("Expected version 1 config and a nonempty task list")
    for key in ("max_developer_attempts", "max_review_cycles", "max_qa_cycles", "max_same_failure"):
        if type(config["retry"][key]) is not int or config["retry"][key] < 1:
            raise ValueError(f"Invalid retry budget: {key}")
    if config["sessions"]["policy"] not in ("fresh", "reuse_within_task"):
        raise ValueError("Unknown session policy")
    for key in ("max_turns", "max_estimated_tokens", "max_input_tokens"):
        if type(config["sessions"][key]) is not int or config["sessions"][key] < 1:
            raise ValueError(f"Invalid session limit: {key}")
    for key in ("diff_chars", "error_chars", "max_discovered_files"):
        if type(config["context"][key]) is not int or config["context"][key] < 1:
            raise ValueError(f"Invalid context limit: {key}")
    for role in ("developer", "reviewer", "qa"):
        for level in LEVELS:
            route = config["roles"][role][level]
            if not nonempty_strings(route["models"]) or len(set(route["models"])) != len(route["models"]):
                raise ValueError("Route needs distinct explicitly allowed models")
            if route["provider"] != "codex":
                raise ValueError("Only the installed Codex CLI adapter is supported")
    checks = config["checks"]
    if not checks:
        raise ValueError("Checks cannot be empty")
    for name, check in checks.items():
        if (not re.fullmatch(r"[a-zA-Z0-9_-]+", name) or not nonempty_strings(check["argv"])
                or check["stage"] not in ("static", "build", "unit", "qa")
                or check["mode"] not in ("fixture", "local", "live")
                or not isinstance(check["timeout"], (int, float)) or check["timeout"] <= 0):
            raise ValueError(f"Invalid check: {name}")
    ids = set()
    for task in tasks:
        tid = task["id"]
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]{0,79}", tid) or tid in ids:
            raise ValueError("Task IDs must be unique and filesystem-safe")
        ids.add(tid)
        if (not task["description"].strip() or not nonempty_strings(task["constraints"])
                or not nonempty_strings(task["files"]) or not isinstance(task["write_files"], list)
                or task["risk"] not in LEVELS or task["complexity"] not in LEVELS):
            raise ValueError(f"Incomplete task: {tid}")
        for name in task["files"]:
            safe_path(root, name)
        for name in task["write_files"]:
            safe_path(root, name, writable=True)
        criteria_ids = set()
        if not task["acceptance_criteria"]:
            raise ValueError("Acceptance criteria are required")
        for criterion in task["acceptance_criteria"]:
            if (not criterion["id"] or criterion["id"] in criteria_ids or not criterion["description"].strip()
                    or not nonempty_strings(criterion["checks"]) or criterion["mode"] not in ("fixture", "local", "live")):
                raise ValueError("Every criterion needs unique ID, text, checks and evidence mode")
            criteria_ids.add(criterion["id"])
            for check in criterion["checks"]:
                if check not in checks or checks[check]["mode"] != criterion["mode"]:
                    raise ValueError("Criterion check is missing or has the wrong evidence mode")
        selected_checks(config, task)  # Check policy references before any model call.
    visiting, visited = set(), set()
    by_id = {t["id"]: t for t in tasks}

    def visit(tid):
        if tid in visiting or tid not in by_id:
            raise ValueError("Cyclic or unknown task dependency")
        if tid in visited:
            return
        visiting.add(tid)
        for dependency in by_id[tid]["depends_on"]:
            visit(dependency)
        visiting.remove(tid)
        visited.add(tid)
    for tid in ids:
        visit(tid)


def level(task):
    return max((task["risk"], task["complexity"]), key=LEVELS.get)


def selected_checks(config, task):
    names = set(config["required_checks"][level(task)])
    for criterion in task["acceptance_criteria"]:
        names.update(criterion["checks"])
    # Scope requirements cannot be dropped by omitting them from a criterion.
    for prefix, required in config.get("scope_checks", {}).items():
        if any(p.startswith(prefix) for p in task["files"] + task["write_files"]):
            names.update(required)
    if not names or not names <= config["checks"].keys():
        raise ValueError("Missing required check definition")
    order = {"static": 0, "build": 1, "unit": 2, "qa": 3}
    return sorted(names, key=lambda n: (order[config["checks"][n]["stage"]], n))


def section(text, start, end):
    if text.count(start) != 1 or text.count(end) != 1:
        raise ValueError("Handoff needs exactly one explicit Project State section")
    return text.split(start, 1)[1].split(end, 1)[0].strip()


def project_state(root):
    return section((root / "docs/handoff_status.md").read_text(), PROJECT_START, PROJECT_END)


def discover(root, task, changed, maximum):
    # Explicit paths and changed files are never truncated. Search results are only hints.
    explicit = list(dict.fromkeys(task["files"] + task["write_files"] + changed))
    candidates = []
    for term in task.get("search_terms", [])[:8]:
        if not isinstance(term, str) or not term.strip():
            continue
        try:
            result = subprocess.run(["rg", "-l", "-F", "--", term, "ios", "supabase"],
                                    cwd=root, capture_output=True, text=True, timeout=10)
            candidates.extend(result.stdout.splitlines())
        except (FileNotFoundError, subprocess.TimeoutExpired):
            break
    return explicit + [p for p in dict.fromkeys(candidates) if p not in explicit][:maximum]


def make_packet(root, config, task, record, role, diff="", diff_path=None, dependencies=None):
    paths = discover(root, task, record.get("changed_files", []), config["context"]["max_discovered_files"])
    payload = {"task_id": task["id"], "role": role, "description": task["description"],
               "acceptance_criteria": task["acceptance_criteria"], "constraints": task["constraints"],
               "architecture": config["architecture"], "project_state": project_state(root),
               "relevant_paths": paths, "allowed_write_files": task["write_files"],
               "dependency_decisions": dependencies or [], "checkpoint": checkpoint(task, record),
               "fingerprint": record.get("fingerprint", ""),
               "full_diff_path": str(diff_path) if diff_path else None,
               "diff": diff[:config["context"]["diff_chars"]],
               "diff_truncated": len(diff) > config["context"]["diff_chars"]}
    instructions = (
        "Work only on this task. Do not load history or the full handoff by default. "
        "Read additional files and applicable AGENTS.md/constitution/spec sections when necessary. "
        "Task criteria and architecture are mandatory. You are read-only: do not change files, "
        "run Git mutations, commit, push, or update handoff/tasks. The controller owns writes. "
        "Do not launch other agents or external MCP servers. Do not rerun successful checks without cause. "
        "Return only JSON matching the output schema. No reasoning transcripts or full command logs. "
        "Developer: return a unified git patch (or empty string if no change is needed), concise summary, "
        "decisions and unresolved findings. Only listed allowed_write_files may be patched. "
        "Reviewer: inspect the diff, criteria, regressions, architecture, state/error handling, performance "
        "and security; read full_diff_path if truncated. On re-review verify previous findings against "
        "the delta; expand to full task diff for high risk/new risks. QA: inspect real evidence paths from "
        "checks, including screenshots where relevant. Never infer a live result from fixtures. "
        "Reviewer/QA: patch must be empty; PASS requires every criterion explicitly PASS with evidence "
        "check IDs. If unable to verify, return BLOCKED. Echo task_id and fingerprint exactly.\n")
    return instructions + json.dumps(payload, ensure_ascii=False, indent=2)
