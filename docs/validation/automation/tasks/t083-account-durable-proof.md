# t083-account-durable-proof

Persist a minimal private durable prerequisite proof for later account purge, without removing any Auth/profile rows or finalizing deletion.

Подготовлены migration021 и rollback-фикстуры для приватного durable proof без финализации удаления.

Изменённые файлы: supabase/migrations/202611170021_account_deletion_durable_proof.sql, supabase/tests/auth_registration_profile.test.sql.

Вызовы — developer 2, reviewer 1, qa 1. Модели — 418.21 с, проверки — 76.36 с. Повторы моделей — 1, тайм-ауты моделей — 0, тайм-ауты проверок — 0.

Проверки:

- deno-check — PASS (local, exit 0, 1.02 с). Лог `/private/tmp/narat-backend-proof-20261117/docs/validation/automation/runs/orchestrator-t083-account-durable-proof-20261117-62/t083-account-durable-proof/check-1-deno-check/stdout.log`.
- diff-check — PASS (local, exit 0, 0.04 с). Лог `/private/tmp/narat-backend-proof-20261117/docs/validation/automation/runs/orchestrator-t083-account-durable-proof-20261117-62/t083-account-durable-proof/check-2-diff-check/stdout.log`.
- deno-tests — PASS (fixture, exit 0, 5.71 с). Лог `/private/tmp/narat-backend-proof-20261117/docs/validation/automation/runs/orchestrator-t083-account-durable-proof-20261117-62/t083-account-durable-proof/check-3-deno-tests/stdout.log`.
- parallel-backend-diagnosis-sql — PASS (fixture, exit 0, 69.58 с). Лог `/private/tmp/narat-backend-proof-20261117/docs/validation/automation/runs/orchestrator-t083-account-durable-proof-20261117-62/t083-account-durable-proof/check-4-parallel-backend-diagnosis-sql/stdout.log`.

Review и QA подтвердили критерии manifest; это не автоматическое закрытие полной продуктовой задачи.

Решения: ["Файлы и Git не изменялись; обязательные проверки запускает controller после применения патча.", "Replay повторно вызывает 020; конфликт сохранённых полей откатывает всю цепочку текущего вызова.", "Фикстуры проверяют сохранность proof после удаления disposable request/receipt/job. Auth/profile не удаляются; независимость от них проверяется отсутствием FK.", "Retention, claim/quota purge и финализация удаления остаются отдельными решениями."].

Ограничения: подтверждены только явно указанные режимы и критерии. State/metrics: `/private/tmp/narat-backend-proof-20261117/docs/validation/automation/runs/orchestrator-t083-account-durable-proof-20261117-62`.
Следующий шаг: следующая независимая задача manifest; ошибки публикации смотреть в state.json.
