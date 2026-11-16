# t083-account-data-photo-rows-purge

Remove only verified deleting owner photo data rows after cleanup and saved dependencies.

Исправлено формирование имён таблиц в динамическом SQL: OID преобразуются в regclass.

Изменённые файлы: supabase/migrations/202611160013_account_deletion_photo_rows.sql, supabase/tests/auth_registration_profile.test.sql.

Вызовы — developer 2, reviewer 1, qa 1. Модели — 615.66 с, проверки — 72.17 с. Повторы моделей — 1, тайм-ауты моделей — 0, тайм-ауты проверок — 0.

Проверки:

- deno-check — PASS (local, exit 0, 0.14 с). Лог `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-t083-account-data-photo-rows-purge-codex-20261116-47/t083-account-data-photo-rows-purge/check-5-deno-check/stdout.log`.
- diff-check — PASS (local, exit 0, 0.02 с). Лог `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-t083-account-data-photo-rows-purge-codex-20261116-47/t083-account-data-photo-rows-purge/check-6-diff-check/stdout.log`.
- deno-tests — PASS (fixture, exit 0, 4.60 с). Лог `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-t083-account-data-photo-rows-purge-codex-20261116-47/t083-account-data-photo-rows-purge/check-7-deno-tests/stdout.log`.
- parallel-backend-diagnosis-sql — PASS (fixture, exit 0, 58.87 с). Лог `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-t083-account-data-photo-rows-purge-codex-20261116-47/t083-account-data-photo-rows-purge/check-8-parallel-backend-diagnosis-sql/stdout.log`.

Review и QA подтвердили критерии manifest; это не автоматическое закрытие полной продуктовой задачи.

Решения: ["Лог подтвердил причину: числовой OID 16448 подставлялся после JOIN вместо имени таблицы.", "Исправлены оба каталожных обхода: родительских и дочерних FK.", "Успешные проверки не повторялись; SQL clean/upgrade повторяет контроллер.", "Файлы и Git не изменялись."].

Ограничения: подтверждены только явно указанные режимы и критерии. State/metrics: `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-t083-account-data-photo-rows-purge-codex-20261116-47`.
Следующий шаг: следующая независимая задача manifest; ошибки публикации смотреть в state.json.
