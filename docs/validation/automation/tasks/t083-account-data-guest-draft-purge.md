# t083-account-data-guest-draft-purge

Safely purge guest drafts whose ownership and replay dependencies have been verified.

Исправлено формирование TAP-плана после rollback fixtures.

Изменённые файлы: supabase/migrations/202611160017_account_deletion_guest_drafts.sql, supabase/tests/auth_registration_profile.test.sql.

Вызовы — developer 2, reviewer 1, qa 1. Модели — 465.11 с, проверки — 90.95 с. Повторы моделей — 1, тайм-ауты моделей — 0, тайм-ауты проверок — 0.

Проверки:

- deno-check — PASS (local, exit 0, 0.13 с). Лог `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-t083-account-data-guest-draft-purge-codex-20261116-53/t083-account-data-guest-draft-purge/check-5-deno-check/stdout.log`.
- diff-check — PASS (local, exit 0, 0.04 с). Лог `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-t083-account-data-guest-draft-purge-codex-20261116-53/t083-account-data-guest-draft-purge/check-6-diff-check/stdout.log`.
- deno-tests — PASS (fixture, exit 0, 4.78 с). Лог `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-t083-account-data-guest-draft-purge-codex-20261116-53/t083-account-data-guest-draft-purge/check-7-deno-tests/stdout.log`.
- parallel-backend-diagnosis-sql — PASS (fixture, exit 0, 67.07 с). Лог `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-t083-account-data-guest-draft-purge-codex-20261116-53/t083-account-data-guest-draft-purge/check-8-parallel-backend-diagnosis-sql/stdout.log`.

Review и QA подтвердили критерии manifest; это не автоматическое закрытие полной продуктовой задачи.

Решения: ["Причина Invalid TAP plan: завершающий rollback восстанавливал curr_test pgTAP, сохраняя номера уже выданных assertions в sequence.", "Добавлена проверка отсутствия fixture-аккаунтов вне rollback: она также синхронизирует счётчик перед finish().", "Успешные проверки не повторялись; SQL clean/upgrade повторно запускает controller. Файлы и Git не изменялись."].

Ограничения: подтверждены только явно указанные режимы и критерии. State/metrics: `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-t083-account-data-guest-draft-purge-codex-20261116-53`.
Следующий шаг: следующая независимая задача manifest; ошибки публикации смотреть в state.json.
