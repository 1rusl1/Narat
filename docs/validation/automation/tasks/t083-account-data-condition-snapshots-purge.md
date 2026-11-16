# t083-account-data-condition-snapshots-purge

Remove verified deleting owner condition snapshots across their legacy and canonical references.

Исправлена коллизия версии snapshot в повреждённом тестовом графе.

Изменённые файлы: supabase/migrations/202611160012_account_deletion_condition_snapshots.sql, supabase/tests/auth_registration_profile.test.sql.

Вызовы — developer 2, reviewer 1, qa 1. Модели — 546.52 с, проверки — 68.78 с. Повторы моделей — 1, тайм-ауты моделей — 0, тайм-ауты проверок — 0.

Проверки:

- deno-check — PASS (local, exit 0, 0.13 с). Лог `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-t083-account-data-condition-snapshots-purge-codex-20261116-46/t083-account-data-condition-snapshots-purge/check-5-deno-check/stdout.log`.
- diff-check — PASS (local, exit 0, 0.02 с). Лог `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-t083-account-data-condition-snapshots-purge-codex-20261116-46/t083-account-data-condition-snapshots-purge/check-6-diff-check/stdout.log`.
- deno-tests — PASS (fixture, exit 0, 4.66 с). Лог `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-t083-account-data-condition-snapshots-purge-codex-20261116-46/t083-account-data-condition-snapshots-purge/check-7-deno-tests/stdout.log`.
- parallel-backend-diagnosis-sql — PASS (fixture, exit 0, 55.55 с). Лог `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-t083-account-data-condition-snapshots-purge-codex-20261116-46/t083-account-data-condition-snapshots-purge/check-8-parallel-backend-diagnosis-sql/stdout.log`.

Review и QA подтвердили критерии manifest; это не автоматическое закрытие полной продуктовой задачи.

Решения: ["Причина SQL-сбоя подтверждена: fixture переносил snapshot с версией 1 к растению, уже имеющему эту версию. Теперь выбирается свободная версия с сохранением проверки чужого родителя.", "Успешные проверки не повторялись. Повторный clean/upgrade SQL gate выполняет контроллер; файлы и Git не изменялись."].

Ограничения: подтверждены только явно указанные режимы и критерии. State/metrics: `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-t083-account-data-condition-snapshots-purge-codex-20261116-46`.
Следующий шаг: следующая независимая задача manifest; ошибки публикации смотреть в state.json.
