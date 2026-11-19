#!/usr/bin/env python3
"""Read-only environment checks and opt-in CLI/iOS smoke checks. Python 3.11+."""

import argparse
from contextlib import contextmanager
from datetime import datetime, timezone
import fcntl
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import shutil
import signal
import subprocess
import sys
import time
import uuid


ROOT = Path(__file__).resolve().parents[2]
RUNS = ROOT / "docs/validation/automation/runs"
BUNDLED_CODEX = Path("/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex")
SIMULATOR = "32009F39-32EF-426B-A91E-31B368D6C27E"
WELCOME = "PlantsUITests/PlantsUITests/testOrdinaryLaunchShowsPhotoAndCollectionRoutes"
LOCAL_UI_SETTINGS = ["CODE_SIGNING_ALLOWED=NO", "NARAT_SUPABASE_URL=",
                     "NARAT_SUPABASE_PUBLISHABLE_KEY=", "GOOGLE_IOS_CLIENT_ID=",
                     "GOOGLE_SERVER_CLIENT_ID=", "GOOGLE_REVERSED_CLIENT_ID="]


def utc_now():
    return datetime.now(timezone.utc).isoformat()


def write_json(path, value):
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")
    temporary.replace(path)


def new_run_path(base, run_id):
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]{0,79}", run_id):
        raise ValueError("run-id: только буквы, цифры, дефис и подчёркивание, до 80 символов")
    base = base.resolve()
    if not base.is_relative_to(ROOT):
        raise ValueError("Каталог отчётов должен находиться внутри проекта")
    path = base / run_id
    path.mkdir()  # Never overwrite evidence or follow an existing run symlink.
    return path


def stop_process(process):
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait(timeout=5)


@contextmanager
def exclusive_run(base):
    if not base.resolve().is_relative_to(ROOT):
        raise ValueError("Каталог отчётов выходит за пределы проекта")
    base.mkdir(parents=True, exist_ok=True)
    with (base / ".doctor.lock").open("a") as lock:
        inherited = os.environ.get("NARAT_AUTOMATION_LOCK_FD")
        if inherited is not None:
            # Only a real inherited descriptor for this exact lock permits nesting.
            fd = int(inherited)
            actual, expected = os.fstat(fd), os.fstat(lock.fileno())
            if (actual.st_dev, actual.st_ino) == (expected.st_dev, expected.st_ino):
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                yield fd
                return
            # A check may acquire independent fixture/resource locks. Never reuse
            # the controller's descriptor for another path; take a normal lock below.
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError("Другой doctor уже запущен") from None
        yield lock.fileno()


class Doctor:
    def __init__(self, run_dir):
        self.run_dir = run_dir
        self.report = {"schema_version": 1, "run_id": run_dir.name,
                       "started_at": utc_now(), "pid": os.getpid(), "status": "RUNNING", "checks": []}
        self.save()

    def save(self):
        write_json(self.run_dir / "summary.json", self.report)

    def add(self, name, status, **details):
        item = {"name": name, "status": status, **details}
        self.report["checks"].append(item)
        self.save()
        print(f"{status}: {name}", flush=True)
        return item

    def command(self, name, argv, timeout=30, env=None):
        stdout = self.run_dir / f"{name}.stdout.log"
        stderr = self.run_dir / f"{name}.stderr.log"
        record = self.add(name, "RUNNING", argv=[str(x) for x in argv],
                          stdout=stdout.name, stderr=stderr.name, started_at=utc_now())
        started = time.monotonic()
        process = None
        try:
            with stdout.open("w") as out, stderr.open("w") as err:
                process = subprocess.Popen(argv, cwd=ROOT, env=env, stdin=subprocess.DEVNULL,
                                           stdout=out, stderr=err, start_new_session=True)
                record["pid"] = process.pid
                self.save()
                process.wait(timeout=timeout)
            record.update(status="PASS" if process.returncode == 0 else "FAIL",
                          exit_code=process.returncode)
        except subprocess.TimeoutExpired:
            stop_process(process)
            record.update(status="FAIL", error="timeout", timeout_seconds=timeout)
        except (KeyboardInterrupt, InterruptedError):
            if process is not None:
                stop_process(process)
            record.update(status="FAIL", error="interrupted")
            raise
        except OSError as error:
            record.update(status="FAIL", error=str(error))
        finally:
            record["elapsed_seconds"] = round(time.monotonic() - started, 2)
            self.save()
        print(f"{record['status']}: {name} ({record['elapsed_seconds']} с)", flush=True)
        return record

    def read_stdout(self, record):
        return (self.run_dir / record["stdout"]).read_text()

    def finish(self, complete):
        checks = self.report["checks"]
        failed = any(x["status"] in ("FAIL", "RUNNING") for x in checks)
        self.report.update(status="FAIL" if failed else "PASS" if complete else "INCOMPLETE",
                           finished_at=utc_now())
        self.save()
        print(f"Результат: {self.report['status']}; отчёт: {self.run_dir / 'summary.json'}")
        return 1 if failed else 0


def model_reply_ok(path, nonce, role):
    try:
        return json.loads(path.read_text()) == {"nonce": nonce, "role": role, "status": "ok"}
    except (OSError, ValueError):
        return False


def welcome_summary_ok(summary):
    return (summary.get("result") == "Passed" and summary.get("totalTestCount") == 1
            and summary.get("passedTests") == 1 and summary.get("failedTests") == 0
            and summary.get("skippedTests") == 0)


def local_ui_info_ok(path):
    try:
        data = plistlib.loads(path.read_bytes())
        return isinstance(data, dict) and not any(data.get(key) for key in (
            "NaratSupabaseURL", "NaratSupabasePublishableKey", "GIDClientID", "GIDServerClientID"))
    except (OSError, ValueError, plistlib.InvalidFileException):
        return False


def check_models(doctor, codex, args):
    # No inherited desktop MCP pipes or session identifiers. Keep existing auth storage.
    env = {key: value for key, value in os.environ.items()
           if not key.startswith(("CODEX_", "CUA_", "BROWSER_USE_")) or key == "CODEX_HOME"}
    sessions = []
    for role, model in [("developer", args.developer_model), ("qa", args.qa_model)]:
        nonce = uuid.uuid4().hex
        schema = doctor.run_dir / f"{role}.schema.json"
        answer = doctor.run_dir / f"{role}.answer.json"
        write_json(schema, {"type": "object", "additionalProperties": False,
                            "properties": {"nonce": {"type": "string", "enum": [nonce]},
                                           "role": {"type": "string", "enum": [role]},
                                           "status": {"type": "string", "enum": ["ok"]}},
                            "required": ["nonce", "role", "status"]})
        prompt = ("This is only a CLI connectivity smoke check, not a development stage. "
                  "Do not use tools, inspect files, change files, update handoff or run Git. "
                  f'Return only JSON: {{"nonce":"{nonce}","role":"{role}","status":"ok"}}')
        record = doctor.command(f"model-{role}", [codex, "--no-daemon", "-a", "never", "exec",
            "--ignore-user-config", "--ephemeral", "--sandbox", "read-only", "--cd", str(ROOT),
            "--model", model, "-c", 'model_reasoning_effort="low"',
            "-c", "features.apps=false", "-c", "features.hooks=false",
            "-c", 'web_search="disabled"', "--json", "--output-schema", str(schema),
            "--output-last-message", str(answer), prompt], timeout=args.model_timeout, env=env)
        valid = record["status"] == "PASS" and model_reply_ok(answer, nonce, role)
        session = None
        try:
            events = [json.loads(line) for line in doctor.read_stdout(record).splitlines() if line.strip()]
            session = next((e.get("thread_id") for e in events if e.get("type") == "thread.started"), None)
            valid = valid and any(e.get("type") == "turn.completed" for e in events)
            # A connectivity check must not perform repository/tool work.
            valid = valid and not any(e.get("item", {}).get("type") in (
                "command_execution", "file_change", "mcp_tool_call", "web_search") for e in events)
        except (OSError, ValueError):
            valid = False
        doctor.add(f"model-{role}-response", "PASS" if valid and session else "FAIL",
                   requested_model=model, session_id=session, answer=answer.name)
        sessions.append(session)
    doctor.add("independent-model-sessions", "PASS" if all(sessions) and len(set(sessions)) == 2 else "FAIL")


def ios_command(args):
    """One source of build settings for doctor and the orchestrator's iOS gate."""
    derived = ROOT / "DerivedData/Automation"
    if not derived.resolve().is_relative_to(ROOT):
        raise ValueError("DerivedData должен находиться внутри проекта")
    return ["xcodebuild", "-project", str(ROOT / "ios/Plants.xcodeproj"), "-scheme", "Plants",
            "-destination", f"platform=iOS Simulator,id={args.simulator}",
            "-destination-timeout", "60", "-derivedDataPath", str(derived),
            "-clonedSourcePackagesDirPath", str(derived / "SourcePackages"),
            "-packageCachePath", str(derived / "PackageCache"),
            "-onlyUsePackageVersionsFromResolvedFile", "-skipPackageUpdates",
            "-parallel-testing-enabled", "NO", *LOCAL_UI_SETTINGS]


def check_ios(doctor, args):
    devices = doctor.command("simulators", ["xcrun", "simctl", "list", "devices", "available", "--json"])
    if devices["status"] != "PASS":
        doctor.add("ios-smoke", "FAIL", reason="CoreSimulator недоступен; сборка и UI не запускались")
        return
    data = json.loads(doctor.read_stdout(devices))
    selected = [(runtime, device) for runtime, values in data["devices"].items() for device in values
                if device["udid"] == args.simulator and device.get("isAvailable")]
    if len(selected) != 1:
        doctor.add("selected-simulator", "FAIL", udid=args.simulator, reason="UDID недоступен")
        return
    runtime, device = selected[0]
    doctor.add("selected-simulator", "PASS", runtime=runtime, device=device)
    if device["state"] != "Booted":
        if doctor.command("simulator-boot", ["xcrun", "simctl", "boot", args.simulator])["status"] != "PASS":
            return
    if doctor.command("simulator-ready", ["xcrun", "simctl", "bootstatus", args.simulator, "-b"], 180)["status"] != "PASS":
        return
    derived = ROOT / "DerivedData/Automation"
    common = ios_command(args)
    doctor.add("local-ui-configuration", "INFO", settings=LOCAL_UI_SETTINGS,
               note="Подключение Supabase/Google отключено build settings только для smoke-сборки")
    build = doctor.command("ios-build", [*common, "build-for-testing"], args.build_timeout)
    if build["status"] != "PASS":
        doctor.add("welcome-ui", "SKIP", reason="Сборка не прошла")
        return
    info = derived / "Build/Products/Debug-iphonesimulator/Plants.app/Info.plist"
    isolated = local_ui_info_ok(info)
    doctor.add("local-ui-configuration-verified", "PASS" if isolated else "FAIL",
               info_plist=str(info.relative_to(ROOT)),
               scope="Параметры подключения пусты в собранном приложении")
    if not isolated:
        doctor.add("welcome-ui", "SKIP", reason="Не подтверждена изоляция от live backend")
        return
    result = doctor.run_dir / "welcome.xcresult"
    test = doctor.command("welcome-ui", [*common, "-only-testing:" + WELCOME,
        "-testLanguage", "en", "-testRegion", "PL", "-resultBundlePath", str(result),
        "test-without-building"], args.test_timeout)
    if test["status"] != "PASS":
        return
    report = doctor.command("welcome-result", ["xcrun", "xcresulttool", "get", "test-results",
                                               "summary", "--path", str(result), "--compact"])
    valid = report["status"] == "PASS" and welcome_summary_ok(json.loads(doctor.read_stdout(report)))
    doctor.add("welcome-acceptance", "PASS" if valid else "FAIL", test=WELCOME,
               mode="local-ui-en", result_bundle=result.name,
               scope="Только обычный welcome: фото, определение, каталог и коллекция; без live backend")


def positive_int(value):
    value = int(value)
    if value < 1:
        raise argparse.ArgumentTypeError("Значение должно быть положительным")
    return value


def main():
    parser = argparse.ArgumentParser(description="Проверка окружения Narat без дополнительных Python-пакетов")
    parser.add_argument("--run-id", default=datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-" + uuid.uuid4().hex[:6])
    parser.add_argument("--codex", help="Путь к CLI; иначе PATH, затем встроенный CLI ChatGPT.app")
    parser.add_argument("--check-models", action="store_true", help="Два коротких реальных запроса Codex")
    parser.add_argument("--check-ios", action="store_true", help="Сборка и один welcome XCUITest")
    parser.add_argument("--developer-model", default="gpt-6.1-sol")
    parser.add_argument("--qa-model", default="gpt-6-astra")
    parser.add_argument("--simulator", default=SIMULATOR)
    parser.add_argument("--model-timeout", type=positive_int, default=180)
    parser.add_argument("--build-timeout", type=positive_int, default=1200)
    parser.add_argument("--test-timeout", type=positive_int, default=300)
    args = parser.parse_args()
    if platform.system() != "Darwin":
        parser.error("Для iOS-окружения требуется macOS")
    if not (ROOT / "ios/Plants.xcodeproj").is_dir():
        parser.error("Не найден существующий Xcode project")
    # Handle SIGTERM just like Ctrl-C, including stopping the current child group.
    def interrupted(signum, frame):
        raise InterruptedError(f"signal {signum}")
    signal.signal(signal.SIGTERM, interrupted)
    try:
        with exclusive_run(RUNS):
            doctor = Doctor(new_run_path(RUNS, args.run_id))
            try:
                codex = args.codex or shutil.which("codex") or str(BUNDLED_CODEX)
                doctor.report["configuration"] = {"codex": codex, "developer_model": args.developer_model,
                                                   "qa_model": args.qa_model, "simulator": args.simulator}
                for name, argv in [("macos", ["sw_vers"]), ("python", [sys.executable, "--version"]),
                    ("codex-version", [codex, "--version"]), ("codex-auth", [codex, "login", "status"]),
                    ("codex-exec-help", [codex, "exec", "--help"]),
                    ("xcode", ["xcodebuild", "-version"]), ("xcode-path", ["xcode-select", "-p"]),
                    ("xcodegen", ["xcodegen", "--version"]), ("node", ["node", "--version"]),
                    ("npm", ["npm", "--version"]), ("git-head", ["git", "rev-parse", "HEAD"]),
                    ("git-status", ["git", "status", "--short"])]:
                    doctor.command(name, argv)
                terminal_env = dict(os.environ, PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin")
                # A missing bare command is advisory: the explicit bundled CLI remains usable.
                doctor.command("terminal-path", ["/bin/zsh", "-lic",
                    'if command -v codex; then codex --version; else print "codex отсутствует в PATH; используется явный путь"; fi'], env=terminal_env)
                doctor.add("optional-tools", "INFO", paths={x: shutil.which(x) for x in
                    ("mobilebuildmcp", "xcodebuildmcp", "mobile-mcp", "maestro", "idb")},
                    note="Отсутствие optional tools не блокирует этап 1; MCP handshake — этап 2")
                if args.check_models:
                    check_models(doctor, codex, args)
                else:
                    doctor.add("model-smoke", "SKIP", reason="Нужен --check-models")
                if args.check_ios:
                    check_ios(doctor, args)
                else:
                    doctor.add("ios-smoke", "SKIP", reason="Нужен --check-ios")
                return doctor.finish(args.check_models and args.check_ios)
            except (KeyboardInterrupt, InterruptedError):
                doctor.add("run", "FAIL", reason="Прервано (Ctrl-C или сигнал); дочерний процесс остановлен")
                doctor.finish(False)
                return 130
            except (OSError, ValueError, KeyError) as error:
                doctor.add("run", "FAIL", reason=str(error))
                return doctor.finish(False)
    except (OSError, ValueError, RuntimeError) as error:
        print(f"Ошибка: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
