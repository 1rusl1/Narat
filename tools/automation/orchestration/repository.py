"""One controller owns patch application and publication. Never reset/clean/stash."""

import difflib
import hashlib
from pathlib import Path
import subprocess

from .context import safe_path
from .storage import digest


def git(root, *args, input_bytes=None):
    result = subprocess.run(["git", *args], cwd=root, input=input_bytes, capture_output=True, timeout=120)
    if result.returncode:
        raise RuntimeError(result.stderr.decode(errors="replace")[-3000:] or f"Git exit {result.returncode}")
    return result.stdout


def manifest(root):
    paths = git(root, "ls-files", "-z", "--cached", "--others", "--exclude-standard").split(b"\0")
    result = {}
    for raw in sorted(set(paths) - {b""}):
        name = raw.decode()
        path = root / name
        if path.is_symlink():
            result[name] = "symlink:" + str(path.readlink())
        elif path.is_file():
            with path.open("rb") as stream:
                content_hash = hashlib.file_digest(stream, "sha256").hexdigest()
            result[name] = f"{path.stat().st_mode & 0o777}:{content_hash}"
        else:
            result[name] = "deleted"
    return result


def fingerprint(root):
    return digest(manifest(root))


def contents(root, paths):
    result = {}
    for name in paths:
        path = safe_path(root, name, writable=True)
        if path.exists():
            if path.stat().st_size > 2_000_000:
                raise ValueError(f"Task text file too large for patch mode: {name}")
            result[name] = path.read_text()  # Binary edits need a separate deterministic tool.
        else:
            result[name] = None
    return result


def diff(before, after):
    parts = []
    for name in sorted(before.keys() | after.keys()):
        old, new = before.get(name), after.get(name)
        if old == new:
            continue
        lines = difflib.unified_diff((old or "").splitlines(keepends=True),
                                     (new or "").splitlines(keepends=True),
                                     fromfile="a/" + name if old is not None else "/dev/null",
                                     tofile="b/" + name if new is not None else "/dev/null")
        parts.append(f"diff --git a/{name} b/{name}\n")
        if old is None:
            parts.append("new file mode 100644\n")
        elif new is None:
            parts.append("deleted file mode 100644\n")
        for line in lines:
            parts.append(line if line.endswith("\n") else line + "\n\\ No newline at end of file\n")
    return "".join(parts)


def normalize_patch(text):
    lines = text.splitlines()
    out = []
    for i, line in enumerate(lines):
        if i + 1 < len(lines) and (line.startswith("--- a/") or line == "--- /dev/null"):
            nxt = lines[i + 1]
            if nxt.startswith("+++ b/") or nxt == "+++ /dev/null":
                a_path = line[4:] if line.startswith("--- a/") else "a/" + nxt[6:]
                b_path = nxt[4:] if nxt.startswith("+++ b/") else "b/" + line[6:]
                prev_headers = [x for x in out[-3:] if x.startswith("diff --git ")]
                if not prev_headers:
                    out.append(f"diff --git {a_path} {b_path}")
                    if line == "--- /dev/null":
                        out.append("new file mode 100644")
                    elif nxt == "+++ /dev/null":
                        out.append("deleted file mode 100644")
        out.append(line)
    return "\n".join(out) + "\n"


def apply_patch(root, text, allowed):
    if not text.strip():
        return []
    if any(marker in text for marker in ("GIT binary patch", "Binary files", "mode 120000", "mode 160000",
                                        "rename from ", "rename to ", "copy from ", "copy to ")):
        raise ValueError("Only ordinary text patches are supported")
    data = normalize_patch(text).encode()
    numstat = git(root, "apply", "--recount", "--numstat", "-z", input_bytes=data)
    paths = []
    for entry in numstat.split(b"\0"):
        if not entry:
            continue
        parts = entry.decode().split("\t", 2)
        if len(parts) != 3 or parts[0] == "-" or parts[1] == "-":
            raise ValueError("Invalid text patch statistics")
        name = parts[2]
        safe_path(root, name, writable=True)
        if name not in allowed:
            raise ValueError(f"Patch outside the allowed task scope: {name}")
        paths.append(name)
    if not paths:
        raise ValueError("Empty patch has no applicable files")
    git(root, "apply", "--recount", "--check", "--whitespace=error-all", input_bytes=data)
    git(root, "apply", "--recount", "--whitespace=error-all", input_bytes=data)
    return sorted(set(paths))


def require_clean(root):
    if git(root, "status", "--porcelain").strip():
        raise ValueError("A new queue requires a clean Git tree; save existing work first")


def changed_paths(root):
    tracked = git(root, "diff", "HEAD", "--name-only", "-z").split(b"\0")
    new = git(root, "ls-files", "--others", "--exclude-standard", "-z").split(b"\0")
    return sorted({p.decode() for p in tracked + new if p})
