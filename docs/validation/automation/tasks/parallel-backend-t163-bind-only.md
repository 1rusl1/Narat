# parallel-backend-t163-bind-only

T163 binding-only: replace actual installation owner bind RPC; OR starter history, preserve valid in-progress leases, never reset registration/monthly spend.

Подготовлено исправление преждевременного расходования starter при bind и 18 дополнительных pgTAP-проверок.

Изменённые файлы: supabase/migrations/202611090010_installation_quota_bind.sql, supabase/tests/registration_bind.test.sql.

Проверки:

- deno-check: PASS, local, exit 0; log `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-parallel-backend-quota-sql-20261109-05/parallel-backend-t163-bind-only/check-7-deno-check/stdout.log`
- diff-check: PASS, local, exit 0; log `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-parallel-backend-quota-sql-20261109-05/parallel-backend-t163-bind-only/check-8-diff-check/stdout.log`
- automation-tests: PASS, fixture, exit 0; log `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-parallel-backend-quota-sql-20261109-05/parallel-backend-t163-bind-only/check-9-automation-tests/stdout.log`
- deno-tests: PASS, fixture, exit 0; log `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-parallel-backend-quota-sql-20261109-05/parallel-backend-t163-bind-only/check-10-deno-tests/stdout.log`
- parallel-backend-cap-regression: PASS, fixture, exit 0; log `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-parallel-backend-quota-sql-20261109-05/parallel-backend-t163-bind-only/check-11-parallel-backend-cap-regression/stdout.log`
- parallel-backend-quota-bind: PASS, fixture, exit 0; log `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-parallel-backend-quota-sql-20261109-05/parallel-backend-t163-bind-only/check-12-parallel-backend-quota-bind/stdout.log`

Review и QA подтвердили критерии manifest; это не автоматическое закрытие полной продуктовой задачи.

Решения: ["Патч изменяет существующие два файла вместо повторного создания: устранена причина ошибки already exists.", "reserved+succeeded сохраняет блокирующий указатель до settlement; consumed и first_starter_success_at восстанавливаются только по quota_state=consumed.", "Подготовлены 113 pgTAP-проверок, включая non-billable settlement после bind, повтор starter и последующее billable consumption.", "Файлы, Git, handoff и tasks не изменялись. Обязательные проверки не запускались; их выполняет controller после применения патча.", "PASS означает готовность патча к проверкам. Полная T163, B2/API, положительный guest claim и live остаются открытыми."].

Ограничения: подтверждены только явно указанные режимы и критерии. State/metrics: `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-parallel-backend-quota-sql-20261109-05`.
Следующий шаг: следующая независимая задача manifest; ошибки публикации смотреть в state.json.
