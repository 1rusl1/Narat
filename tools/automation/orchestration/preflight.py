"""Read-only preparation checks before spending model quota; never build or run models."""

import json
from pathlib import Path
import plistlib
import subprocess

from .context import safe_path
from .repository import git


def candidate_comparison(root, task, record):
    base = task.get("candidate_base")
    if not base:
        return None, set()
    head = record["base_head"]
    git(root, "merge-base", "--is-ancestor", base, head)
    paths = {p.decode() for p in git(root, "diff", "--name-only", "-z", base, head, "--").split(b"\0") if p}
    if not paths:
        raise ValueError("Preflight: candidate_base has no comparative diff; use an explicit snapshot audit")
    if not paths <= set(task["files"]):
        raise ValueError("Preflight: candidate diff paths missing from files: " + ", ".join(sorted(paths - set(task["files"]))))
    deleted = {p.decode() for p in git(root, "diff", "--diff-filter=D", "--name-only", "-z", base, head, "--").split(b"\0") if p}
    text = git(root, "diff", "--no-ext-diff", "--no-textconv", base, head, "--").decode()
    return text, deleted


def _swift_membership(root, policy, paths):
    """Resolve actual file references and source phases, not basename/comment matches.

    Supports the project's explicit PBX groups. Unknown/synchronized layouts fail
    closed rather than claiming source inclusion without inspecting their rules.
    """
    targets = policy.get("swift_targets", {})
    wanted = {}
    for name in paths:
        if not name.endswith(".swift") or not (root / name).is_file():
            continue  # New files are checked after the patch; deleted ones need no membership.
        prefixes = [p for p in targets if name.startswith(p)]
        if prefixes:
            wanted[(root / name).resolve()] = targets[max(prefixes, key=len)]
    if not wanted:
        return
    project = safe_path(root, policy["xcode_project"])
    try:
        data = plistlib.loads(project.read_bytes())
    except plistlib.InvalidFileException:
        result = subprocess.run(["plutil", "-convert", "json", "-o", "-", "--", str(project)],
                                capture_output=True, timeout=10)
        if result.returncode:
            raise ValueError("Preflight: cannot parse Xcode project")
        data = json.loads(result.stdout)
    objects = data["objects"]
    project_object = objects[data["rootObject"]]
    paths_by_id = {}

    def walk(ref, parent, ancestors):
        if ref in ancestors:
            raise ValueError("Preflight: cyclic Xcode group")
        obj = objects[ref]
        tree = obj.get("sourceTree", "<group>")
        if tree == "SOURCE_ROOT":
            parent = project.parent.parent
        elif tree != "<group>":
            return  # Products/SDK references are not local Swift sources.
        path = (parent / obj.get("path", "")).resolve()
        paths_by_id[ref] = path
        for child in obj.get("children", []):
            walk(child, path, ancestors | {ref})

    walk(project_object["mainGroup"], project.parent.parent, set())
    membership = {}
    for ref in project_object["targets"]:
        target = objects[ref]
        sources = set()
        for phase_id in target.get("buildPhases", []):
            phase = objects[phase_id]
            if phase.get("isa") == "PBXSourcesBuildPhase":
                for build_id in phase.get("files", []):
                    file_id = objects[build_id].get("fileRef")
                    if file_id in paths_by_id:
                        sources.add(paths_by_id[file_id])
        membership[target["name"]] = sources
    for path, target in wanted.items():
        if path not in membership.get(target, set()):
            raise ValueError(f"Preflight: {path.relative_to(root)} absent from {target} Sources; "
                             "controller must update target membership before checks/models")


def swift_membership(root, policy, paths):
    try:
        _swift_membership(root, policy, paths)
    except (KeyError, TypeError, plistlib.InvalidFileException) as error:
        raise ValueError("Preflight: unsupported/malformed Xcode project") from error


def verify_inputs(root, config, task, record, role, deleted_files=()):
    for name in set(task["files"]) - set(task["write_files"]):
        if not safe_path(root, name).exists() and name not in deleted_files:
            raise ValueError(f"Preflight: missing task input {name}")
    for name in task.get("evidence_files", []):
        path = safe_path(root, name)
        if not path.is_file() or not path.stat().st_size:
            raise ValueError(f"Preflight: missing/empty evidence file {name}")
    swift_membership(root, config.get("preflight", {}),
                     set(task["files"] + task["write_files"] + record.get("changed_files", [])))
    if role != "developer":
        for check in record.get("checks", {}).values():
            for stream in ("stdout", "stderr"):
                path = Path(check.get(stream, ""))
                if not path.is_absolute() or not path.is_file():
                    raise ValueError(f"Preflight: missing saved {stream} for {check['name']}")
