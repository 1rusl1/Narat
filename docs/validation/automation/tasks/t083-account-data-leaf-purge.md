# t083-account-data-leaf-purge

Implement the first local account data cleanup phase, limited to verified owner-owned leaf rows.

Исправлена фикстура notification_claims — добавлена существующая installation_access для соблюдения внешнего ключа.

Изменённые файлы: supabase/migrations/202611150066_account_deletion_care_leaves.sql, supabase/tests/auth_registration_profile.test.sql.

Вызовы — developer 2, reviewer 1, qa 1. Модели — 359.25 с, проверки — 62.29 с. Повторы моделей — 1, тайм-ауты моделей — 0, тайм-ауты проверок — 0.

Проверки:

- deno-check — PASS (local, exit 0, 0.08 с). Лог `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-t083-account-data-leaf-purge-codex-20261115-27/t083-account-data-leaf-purge/check-5-deno-check/stdout.log`.
- diff-check — PASS (local, exit 0, 0.04 с). Лог `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-t083-account-data-leaf-purge-codex-20261115-27/t083-account-data-leaf-purge/check-6-diff-check/stdout.log`.
- deno-tests — PASS (fixture, exit 0, 4.35 с). Лог `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-t083-account-data-leaf-purge-codex-20261115-27/t083-account-data-leaf-purge/check-7-deno-tests/stdout.log`.
- parallel-backend-diagnosis-sql — PASS (fixture, exit 0, 49.55 с). Лог `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-t083-account-data-leaf-purge-codex-20261115-27/t083-account-data-leaf-purge/check-8-parallel-backend-diagnosis-sql/stdout.log`.

Review и QA подтвердили критерии manifest; это не автоматическое закрытие полной продуктовой задачи.

Решения: ["Для каждого fixture-владельца создаётся отдельная installation_access, используемая обеими notification_claims.", "Успешные проверки повторно не запускались. Исправленный SQL проверит контроллер."].

Ограничения: подтверждены только явно указанные режимы и критерии. State/metrics: `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-t083-account-data-leaf-purge-codex-20261115-27`.
Следующий шаг: следующая независимая задача manifest; ошибки публикации смотреть в state.json.
