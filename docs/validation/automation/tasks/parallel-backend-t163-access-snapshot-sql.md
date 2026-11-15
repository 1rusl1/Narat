# parallel-backend-t163-access-snapshot-sql

B2 authoritative SQL snapshot only: one shared monthly pool, server eligibility/anchor/history, no job creation/reservation or JS forecasting.

SQL012 не требует исправлений. Подготовлен патч недостающих pgTAP-сценариев для проверок контроллером.

Изменённые файлы: supabase/tests/registration_access.test.sql.

Проверки:

- deno-check: PASS, local, exit 0; log `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-parallel-backend-quota-api-sql-20261110-07/parallel-backend-t163-access-snapshot-sql/check-1-deno-check/stdout.log`
- diff-check: PASS, local, exit 0; log `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-parallel-backend-quota-api-sql-20261110-07/parallel-backend-t163-access-snapshot-sql/check-2-diff-check/stdout.log`
- automation-tests: PASS, fixture, exit 0; log `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-parallel-backend-quota-api-sql-20261110-07/parallel-backend-t163-access-snapshot-sql/check-3-automation-tests/stdout.log`
- deno-tests: PASS, fixture, exit 0; log `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-parallel-backend-quota-api-sql-20261110-07/parallel-backend-t163-access-snapshot-sql/check-4-deno-tests/stdout.log`
- parallel-backend-cap-regression: PASS, fixture, exit 0; log `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-parallel-backend-quota-api-sql-20261110-07/parallel-backend-t163-access-snapshot-sql/check-5-parallel-backend-cap-regression/stdout.log`
- parallel-backend-quota-access: PASS, fixture, exit 0; log `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-parallel-backend-quota-api-sql-20261110-07/parallel-backend-t163-access-snapshot-sql/check-6-parallel-backend-quota-access/stdout.log`

Review и QA подтвердили критерии manifest; это не автоматическое закрытие полной продуктовой задачи.

Решения: ["Просмотрены SQL012, полный существующий тест и зависимости SQL005/006/008/009/011; предикат истории SQL012 соответствует SQL008.", "Патч добавляет fixtures исчерпания общего paid-пула, неизвестной регистрации, глобально неразрешимой истории, leap/microsecond boundaries и нормализации скопированного starter через GET с сопоставлением реальным RPC.", "Файлы и Git не изменялись. Проверки не запускались; обязательные проверки и конкурентные прогоны выполняет контроллер. PASS означает готовность патча к проверкам; live-интеграции не подтверждены."].

Ограничения: подтверждены только явно указанные режимы и критерии. State/metrics: `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-parallel-backend-quota-api-sql-20261110-07`.
Следующий шаг: следующая независимая задача manifest; ошибки публикации смотреть в state.json.
