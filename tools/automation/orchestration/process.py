"""Bounded subprocess execution. Raw output stays on disk, not in prompts."""

import os
import re
import subprocess
import time

from doctor import stop_process


def tail(path, size=32768):
    if not path.exists():
        return ""
    with path.open("rb") as stream:
        stream.seek(max(0, path.stat().st_size - size))
        return stream.read(size).decode("utf-8", errors="replace")


def error_excerpt(paths, limit):
    lines = "\n".join(tail(p) for p in paths).splitlines()
    relevant = [line for line in lines if re.search(
        r"error|fail|exception|denied|limit|unavailable|timeout|:\d+(:\d+)?", line, re.I)]
    return "\n".join(dict.fromkeys(relevant or lines[-20:]))[-limit:]


def run(argv, cwd, directory, timeout, input_text=None, lock_fd=None):
    directory.mkdir(parents=True, exist_ok=True)
    out, err = directory / "stdout.log", directory / "stderr.log"
    # Preserve login storage, not desktop sessions, app pipes or a caller's lock claim.
    env = {k: v for k, v in os.environ.items()
           if (not k.startswith(("CODEX_", "CUA_", "BROWSER_USE_", "NARAT_AUTOMATION_LOCK_"))
               or k == "CODEX_HOME")}
    if lock_fd is not None:
        env["NARAT_AUTOMATION_LOCK_FD"] = str(lock_fd)
    started = time.monotonic()
    record = {"argv": argv, "stdout": str(out), "stderr": str(err), "status": "FAIL", "exit_code": None}
    process = None
    try:
        with out.open("w") as stdout, err.open("w") as stderr:
            process = subprocess.Popen(argv, cwd=cwd, env=env, stdin=subprocess.PIPE,
                                       stdout=stdout, stderr=stderr, start_new_session=True,
                                       pass_fds=() if lock_fd is None else (lock_fd,))
            process.communicate(input=None if input_text is None else input_text.encode(), timeout=timeout)
        record.update(exit_code=process.returncode, status="PASS" if process.returncode == 0 else "FAIL")
    except subprocess.TimeoutExpired:
        stop_process(process)
        record["error"] = "timeout"
    except (KeyboardInterrupt, InterruptedError):
        if process is not None:
            stop_process(process)
        record["error"] = "interrupted"
        raise
    except OSError as error:
        record["error"] = str(error)
    finally:
        record["elapsed_seconds"] = round(time.monotonic() - started, 3)
        from .storage import atomic_json
        atomic_json(directory / "process.json", record)
    return record
