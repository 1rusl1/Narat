# t083-account-retained-deletion-job

Create an exact owner/operation account deletion processing record after verified local prerequisites.

Исправлен порядок подготовки SQL fixture: растение создаётся до перевода владельца в deleting.

Изменённые файлы: supabase/migrations/202611160020_account_deletion_work_anchor.sql, supabase/tests/auth_registration_profile.test.sql.

Вызовы — developer 3, reviewer 1, qa 1. Модели — 403.02 с, проверки — 88.39 с. Повторы моделей — 2, тайм-ауты моделей — 0, тайм-ауты проверок — 0.

Проверки:

- deno-check — PASS (local, exit 0, 0.03 с). Лог `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-t083-account-retained-deletion-job-codex-20261117-59/t083-account-retained-deletion-job/check-5-deno-check/stdout.log`.
- diff-check — PASS (local, exit 0, 0.04 с). Лог `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-t083-account-retained-deletion-job-codex-20261117-59/t083-account-retained-deletion-job/check-6-diff-check/stdout.log`.
- deno-tests — PASS (fixture, exit 0, 4.11 с). Лог `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-t083-account-retained-deletion-job-codex-20261117-59/t083-account-retained-deletion-job/check-7-deno-tests/stdout.log`.
- parallel-backend-diagnosis-sql — PASS (fixture, exit 0, 64.69 с). Лог `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-t083-account-retained-deletion-job-codex-20261117-59/t083-account-retained-deletion-job/check-8-parallel-backend-diagnosis-sql/stdout.log`.

Review и QA подтвердили критерии manifest; это не автоматическое закрытие полной продуктовой задачи.

Решения: ["Причина SQL-сбоя подтверждена: enforce_plant_collection_cap запрещает создание растения для deleting-владельца. Fixture теперь создаёт растение при active; проверка cross-owner hold сохранена.", "Успешные Deno и diff проверки повторно не запускались. Исправление передаётся controller для проверки; миграция не изменена."].

Ограничения: подтверждены только явно указанные режимы и критерии. State/metrics: `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-t083-account-retained-deletion-job-codex-20261117-59`.
Следующий шаг: следующая независимая задача manifest; ошибки публикации смотреть в state.json.
