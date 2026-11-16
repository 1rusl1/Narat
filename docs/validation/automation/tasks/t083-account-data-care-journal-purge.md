# t083-account-data-care-journal-purge

Remove the deleting owner's journal facts, observations, and tasks after verified Storage and leaf cleanup, with cross-owner FK protection.

Подготовлен SQL-патч удаления журнала с защитой всех семи входящих FK и rollback-фикстурами.

Изменённые файлы: supabase/migrations/202611150067_account_deletion_care_journal.sql, supabase/tests/auth_registration_profile.test.sql.

Вызовы — developer 2, reviewer 1, qa 1. Модели — н/д, проверки — 48.98 с. Повторы моделей — 1, тайм-ауты моделей — 0, тайм-ауты проверок — 0.

Проверки:

- deno-check — PASS (local, exit 0, 0.14 с). Лог `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-t083-account-data-care-journal-purge-codex-20261115-28/t083-account-data-care-journal-purge/check-1-deno-check/stdout.log`.
- diff-check — PASS (local, exit 0, 0.04 с). Лог `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-t083-account-data-care-journal-purge-codex-20261115-28/t083-account-data-care-journal-purge/check-2-diff-check/stdout.log`.
- deno-tests — PASS (fixture, exit 0, 4.49 с). Лог `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-t083-account-data-care-journal-purge-codex-20261115-28/t083-account-data-care-journal-purge/check-3-deno-tests/stdout.log`.
- parallel-backend-diagnosis-sql — PASS (fixture, exit 0, 44.30 с). Лог `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-t083-account-data-care-journal-purge-codex-20261115-28/t083-account-data-care-journal-purge/check-4-parallel-backend-diagnosis-sql/stdout.log`.

Review и QA подтвердили критерии manifest; это не автоматическое закрытие полной продуктовой задачи.

Решения: ["Учтена дополнительная связь care_tasks.completed_entry_id → care_entries.", "Использованы строковые блокировки родителей и входящих ссылок. Межвладельческая связь возвращает false с откатом изменений текущего вызова.", "Фикстуры покрывают семь исторических межвладельческих FK, атомарный откат, сохранность соседей, запрос и receipt, ACL и повторные вызовы.", "Файлы и Git не изменялись. Проверки выполнит контроллер после применения патча."].

Ограничения: подтверждены только явно указанные режимы и критерии. State/metrics: `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-t083-account-data-care-journal-purge-codex-20261115-28`.
Следующий шаг: следующая независимая задача manifest; ошибки публикации смотреть в state.json.
