# t083-account-data-plant-rows-purge

Remove only verified owner plant rows once every applicable data dependency is approved.

Исправлена подготовка fixture: удалённое растение создаётся до перехода аккаунта в deleting.

Изменённые файлы: supabase/migrations/202611160014_account_deletion_plant_rows.sql, supabase/tests/auth_registration_profile.test.sql.

Вызовы — developer 2, reviewer 1, qa 1. Модели — 793.66 с, проверки — 75.97 с. Повторы моделей — 1, тайм-ауты моделей — 0, тайм-ауты проверок — 0.

Проверки:

- deno-check — PASS (local, exit 0, 0.15 с). Лог `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-t083-account-data-plant-rows-purge-codex-20261116-48/t083-account-data-plant-rows-purge/check-5-deno-check/stdout.log`.
- diff-check — PASS (local, exit 0, 0.05 с). Лог `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-t083-account-data-plant-rows-purge-codex-20261116-48/t083-account-data-plant-rows-purge/check-6-diff-check/stdout.log`.
- deno-tests — PASS (fixture, exit 0, 4.32 с). Лог `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-t083-account-data-plant-rows-purge-codex-20261116-48/t083-account-data-plant-rows-purge/check-7-deno-tests/stdout.log`.
- parallel-backend-diagnosis-sql — PASS (fixture, exit 0, 62.97 с). Лог `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-t083-account-data-plant-rows-purge-codex-20261116-48/t083-account-data-plant-rows-purge/check-8-parallel-backend-diagnosis-sql/stdout.log`.

Review и QA подтвердили критерии manifest; это не автоматическое закрытие полной продуктовой задачи.

Решения: ["Причина SQL-сбоя подтверждена логом: enforce_plant_collection_cap запрещает INSERT после начала удаления аккаунта.", "Основное растение fixture выбирается через photo_assets, чтобы дополнительный tombstone не влиял на выбор.", "Успешные проверки не повторялись; повторный SQL-прогон выполняет контроллер. Файлы и Git не изменялись."].

Ограничения: подтверждены только явно указанные режимы и критерии. State/metrics: `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-t083-account-data-plant-rows-purge-codex-20261116-48`.
Следующий шаг: следующая независимая задача manifest; ошибки публикации смотреть в state.json.
