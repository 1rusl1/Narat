# t083-unlink-installation-owner

Remove only the deleted owner alias from shared installation quota records.

Исправлена подготовка SQL-фикстуры. Растение создаётся до перевода владельца в deleting.

Изменённые файлы: supabase/migrations/202611160019_account_deletion_installation_unlink.sql, supabase/tests/auth_registration_profile.test.sql.

Вызовы — developer 3, reviewer 1, qa 1. Модели — 525.57 с, проверки — 82.75 с. Повторы моделей — 2, тайм-ауты моделей — 0, тайм-ауты проверок — 0.

Проверки:

- deno-check — PASS (local, exit 0, 0.02 с). Лог `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-t083-unlink-installation-owner-codex-20261116-58/t083-unlink-installation-owner/check-5-deno-check/stdout.log`.
- diff-check — PASS (local, exit 0, 0.04 с). Лог `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-t083-unlink-installation-owner-codex-20261116-58/t083-unlink-installation-owner/check-6-diff-check/stdout.log`.
- deno-tests — PASS (fixture, exit 0, 4.03 с). Лог `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-t083-unlink-installation-owner-codex-20261116-58/t083-unlink-installation-owner/check-7-deno-tests/stdout.log`.
- parallel-backend-diagnosis-sql — PASS (fixture, exit 0, 60.05 с). Лог `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-t083-unlink-installation-owner-codex-20261116-58/t083-unlink-installation-owner/check-8-parallel-backend-diagnosis-sql/stdout.log`.

Review и QA подтвердили критерии manifest; это не автоматическое закрытие полной продуктовой задачи.

Решения: ["Лог подтвердил отказ enforce_plant_collection_cap при создании растения владельцу в deleting. Подготовка растения перенесена перед запросом удаления, проверка чужой зависимости сохранена.", "Deno, diff-check и Deno-тесты прошли по данным контроллера. Исправленный SQL-путь проверит контроллер."].

Ограничения: подтверждены только явно указанные режимы и критерии. State/metrics: `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-t083-unlink-installation-owner-codex-20261116-58`.
Следующий шаг: следующая независимая задача manifest; ошибки публикации смотреть в state.json.
