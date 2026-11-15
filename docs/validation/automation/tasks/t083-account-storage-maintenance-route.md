# t083-account-storage-maintenance-route

Bind the accepted single Storage batch helper to a service-only account maintenance route.

Подготовлены служебный маршрут Storage, миграция 064 и изолированные Deno/pgTAP fixtures.

Изменённые файлы: supabase/functions/_shared/tests/account_deletion_storage_test.ts, supabase/functions/plants-api/index.ts, supabase/migrations/202611150064_account_deletion_storage_service.sql, supabase/tests/auth_registration_profile.test.sql.

Вызовы — developer 1, reviewer 1, qa 1. Модели — 447.21 с, проверки — 43.59 с. Повторы моделей — 0, тайм-ауты моделей — 0, тайм-ауты проверок — 0.

Проверки:

- deno-check — PASS (local, exit 0, 0.84 с). Лог `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-t083-account-storage-maintenance-route-codex-20261115-25/t083-account-storage-maintenance-route/check-1-deno-check/stdout.log`.
- diff-check — PASS (local, exit 0, 0.02 с). Лог `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-t083-account-storage-maintenance-route-codex-20261115-25/t083-account-storage-maintenance-route/check-2-diff-check/stdout.log`.
- deno-tests — PASS (fixture, exit 0, 4.95 с). Лог `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-t083-account-storage-maintenance-route-codex-20261115-25/t083-account-storage-maintenance-route/check-3-deno-tests/stdout.log`.
- parallel-backend-diagnosis-sql — PASS (fixture, exit 0, 37.78 с). Лог `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-t083-account-storage-maintenance-route-codex-20261115-25/t083-account-storage-maintenance-route/check-4-parallel-backend-diagnosis-sql/stdout.log`.

Review и QA подтвердили критерии manifest; это не автоматическое закрытие полной продуктовой задачи.

Решения: ["Маршрут использует существующую проверку service bearer/apikey перед публичным Auth и вызовами helper.", "Допускается пустое тело запроса. Непустое тело и query-параметры отклоняются.", "Маркер 064 хранится в COMMENT функции. pgTAP проверяет фактическое выполнение ролями и сохраняет проверки исторического состояния 063.", "Проверки выполняет контроллер после применения патча. T082/T083 остаются открытыми."].

Ограничения: подтверждены только явно указанные режимы и критерии. State/metrics: `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-t083-account-storage-maintenance-route-codex-20261115-25`.
Следующий шаг: следующая независимая задача manifest; ошибки публикации смотреть в state.json.
