# parallel-backend-t163-registration-anchors

T163 recovery B1a: ONLY immutable registration anchor + UTC month window; no usage/import/admission in this patch. Keep implementation bounded.

Подготовлен ограниченный патч: неизменяемые якоря регистрации, UTC-окна и 54 pgTAP-проверки.

Изменённые файлы: supabase/migrations/202611090005_registration_quotas.sql, supabase/tests/registration_anchors.test.sql.

Проверки:

- deno-check: PASS, local, exit 0; log `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-parallel-backend-quota-sql-20261109-02/parallel-backend-t163-registration-anchors/check-1-deno-check/stdout.log`
- diff-check: PASS, local, exit 0; log `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-parallel-backend-quota-sql-20261109-02/parallel-backend-t163-registration-anchors/check-2-diff-check/stdout.log`
- automation-tests: PASS, fixture, exit 0; log `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-parallel-backend-quota-sql-20261109-02/parallel-backend-t163-registration-anchors/check-3-automation-tests/stdout.log`
- deno-tests: PASS, fixture, exit 0; log `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-parallel-backend-quota-sql-20261109-02/parallel-backend-t163-registration-anchors/check-4-deno-tests/stdout.log`
- parallel-backend-quota-anchors: PASS, fixture, exit 0; log `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-parallel-backend-quota-sql-20261109-02/parallel-backend-t163-registration-anchors/check-5-parallel-backend-quota-anchors/stdout.log`

Review и QA подтвердили критерии manifest; это не автоматическое закрытие полной продуктовой задачи.

Решения: ["Файлы и Git не изменялись; патч предназначен для применения контроллером.", "Обязательные проверки не запускались согласно заданию; PASS означает готовность к проверкам контроллера.", "Legacy получает NULL/unresolved; первое подтверждённое значение и его источник сохраняются при повторах.", "NULL и бесконечные значения окна отклоняются; для времени до регистрации сохраняется прежнее поведение первого окна.", "Ledger, reconciliation и admission остаются следующими срезами; live-интеграции не заявляются."].

Ограничения: подтверждены только явно указанные режимы и критерии. State/metrics: `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-parallel-backend-quota-sql-20261109-02`.
Следующий шаг: следующая независимая задача manifest; ошибки публикации смотреть в state.json.
