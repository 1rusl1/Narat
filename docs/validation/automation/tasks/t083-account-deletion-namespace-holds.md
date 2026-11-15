# t083-account-deletion-namespace-holds

Detect untracked private objects and unfinished guest transfers before an account purge can be considered complete.

Исправлена фикстура, нарушавшая неизменность регистрации постоянного аккаунта.

Изменённые файлы: supabase/migrations/202611150062_account_deletion_namespace_holds.sql, supabase/tests/auth_registration_profile.test.sql.

Вызовы — developer 3, reviewer 1, qa 1. Модели — 536.69 с, проверки — 57.27 с. Повторы моделей — 2, тайм-ауты моделей — 0, тайм-ауты проверок — 0.

Проверки:

- diff-check — PASS (local, exit 0, 0.02 с). Лог `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-t083-account-deletion-namespace-holds-codex-20261115-22/t083-account-deletion-namespace-holds/check-4-diff-check/stdout.log`.
- deno-tests — PASS (fixture, exit 0, 5.01 с). Лог `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-t083-account-deletion-namespace-holds-codex-20261115-22/t083-account-deletion-namespace-holds/check-5-deno-tests/stdout.log`.
- parallel-backend-diagnosis-sql — PASS (fixture, exit 0, 44.82 с). Лог `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-t083-account-deletion-namespace-holds-codex-20261115-22/t083-account-deletion-namespace-holds/check-6-parallel-backend-diagnosis-sql/stdout.log`.

Review и QA подтвердили критерии manifest; это не автоматическое закрытие полной продуктовой задачи.

Решения: ["Проверка анонимного владельца использует существующую фикстуру 902 с каноническими запросом и receipt.", "Причина REGISTRATION_ANCHOR_IMMUTABLE подтверждена защитным триггером и контекстом ошибки.", "Успешные проверки повторно не запускались. SQL-проверку выполняет контроллер.", "T082/T083 остаются открытыми."].

Ограничения: подтверждены только явно указанные режимы и критерии. State/metrics: `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-t083-account-deletion-namespace-holds-codex-20261115-22`.
Следующий шаг: следующая независимая задача manifest; ошибки публикации смотреть в state.json.
