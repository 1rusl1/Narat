# t083-account-data-care-plan-purge

Remove only the verified deleting owner’s regimen plans after the accepted journal phase, with neighbor protection.

Подготовлен патч удаления планов после 067 с защитой соседних владельцев и атомарным откатом при блокировке.

Изменённые файлы: supabase/migrations/202611160004_account_deletion_care_plans.sql, supabase/tests/auth_registration_profile.test.sql.

Вызовы — developer 1, reviewer 1, qa 1. Модели — 526.31 с, проверки — 46.21 с. Повторы моделей — 0, тайм-ауты моделей — 0, тайм-ауты проверок — 0.

Проверки:

- deno-check — PASS (local, exit 0, 0.14 с). Лог `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-t083-account-data-care-plan-purge-codex-20261116-32/t083-account-data-care-plan-purge/check-1-deno-check/stdout.log`.
- diff-check — PASS (local, exit 0, 0.04 с). Лог `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-t083-account-data-care-plan-purge-codex-20261116-32/t083-account-data-care-plan-purge/check-2-diff-check/stdout.log`.
- deno-tests — PASS (fixture, exit 0, 4.56 с). Лог `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-t083-account-data-care-plan-purge-codex-20261116-32/t083-account-data-care-plan-purge/check-3-deno-tests/stdout.log`.
- parallel-backend-diagnosis-sql — PASS (fixture, exit 0, 41.48 с). Лог `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-t083-account-data-care-plan-purge-codex-20261116-32/t083-account-data-care-plan-purge/check-4-parallel-backend-diagnosis-sql/stdout.log`.

Review и QA подтвердили критерии manifest; это не автоматическое закрытие полной продуктовой задачи.

Решения: ["В текущей схеме прямой FK находится в task_rules.plan_id; care_tasks связан через rule_id. Защищены обе ступени и оба FK recovery_transitions; прямые входящие FK обнаруживаются через каталог PostgreSQL.", "Любой hold откатывает изменения текущего вызова, включая проверку Storage и вложенную фазу 067. Существующее доказательство не заменяет живую проверку.", "Добавлены rollback-фикстуры для обоих владельцев, всех фактических связей, сохранения решений и receipts, ACL, ошибок и повторов.", "Файлы не изменялись. Проверки выполняет контроллер после применения патча; живые интеграции не запускались."].

Ограничения: подтверждены только явно указанные режимы и критерии. State/metrics: `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-t083-account-data-care-plan-purge-codex-20261116-32`.
Следующий шаг: следующая независимая задача manifest; ошибки публикации смотреть в state.json.
