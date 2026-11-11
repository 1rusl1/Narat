"""Short reports derived from the saved run state."""

from collections import Counter

from .metrics import summarize


def seconds(value):
    return "н/д" if value is None else f"{value:.2f} с"


def activity(record):
    totals = summarize([record])["total_including_retries"]
    roles = Counter(call["agent"] for call in record["calls"])
    calls = ", ".join(f"{role} {count}" for role, count in roles.items()) or "0"
    check_timeouts = totals["check_timeouts"]
    return (f"Вызовы — {calls}. Модели — {seconds(totals['agent_elapsed_seconds'])}, "
            f"проверки — {seconds(totals['check_elapsed_seconds'])}. "
            f"Повторы моделей — {totals['retries']}, тайм-ауты моделей — {totals['agent_timeouts']}, "
            f"тайм-ауты проверок — {check_timeouts if check_timeouts is not None else 'н/д'}.")


def check_results(record):
    return [f"- {name} — {check['status']} ({check['mode']}, exit {check['exit_code']}, {seconds(check.get('elapsed_seconds'))}). "
            f"Лог `{check['stdout']}`."
            for name, check in record.get("checks", {}).items()]


def run_summary(data, directory, task_id=None):
    lines = [f"## {directory.name}", ""]
    for invocation in data.get("invocations", []):
        lines.append(f"Запуск {invocation['started_at']} · {seconds(invocation.get('elapsed_seconds'))}.")
    for name, record in data["tasks"].items():
        if task_id and name != task_id:
            continue
        lines.extend(["", f"**{name}** — {record['status']} ({record['phase']}).", activity(record)])
        if record.get("reason"):
            lines.append(record["reason"])
        if record.get("changed_files"):
            lines.append("Изменённые файлы — " + ", ".join(f"`{path}`" for path in record["changed_files"]) + ".")
        commit = (record.get("publication") or {}).get("commit")
        if commit:
            label = "Опубликованный коммит" if record["status"] == "COMPLETED" else "Локальный коммит"
            lines.append(f"{label} `{commit}`.")
        checks = check_results(record)
        if checks:
            lines.extend(["", *checks])
    lines.extend(["", f"Состояние и метрики сохранены в `{directory}`."])
    return "\n".join(lines)
