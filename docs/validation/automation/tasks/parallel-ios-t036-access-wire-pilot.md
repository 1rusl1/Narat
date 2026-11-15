# parallel-ios-t036-access-wire-pilot

One bounded T036 canonical monthly-access decode/transport scenario using accepted SQL/wire6d689b7: preserve owner/sharedmonthly/nullableunknown/camelCase modes/rawtimestamps and fetch through real existing PlantsAPIClient with captured bound auth. No repository/UI/billing/liveGET activation. Exactly one throughput pilot task; terminal or timeout stops the lane.

Подготовлен патч канонического monthly-access DTO, защищённого GET и семи новых тестовых методов.

Изменённые файлы: ios/Plants/Data/Remote/APIModels.swift, ios/Plants/Data/Remote/PlantsAPIClient.swift, ios/PlantsTests/CollectionWireTests.swift.

Проверки:

- diff-check: PASS, local, exit 0; log `/Users/ruslansabirov/.codex/worktrees/d09a/Plants/docs/validation/automation/runs/orchestrator-parallel-ios-t036-access-wire-pilot-20261110-01/parallel-ios-t036-access-wire-pilot/check-1-diff-check/stdout.log`
- ios-tests: PASS, local, exit 0; log `/Users/ruslansabirov/.codex/worktrees/d09a/Plants/docs/validation/automation/runs/orchestrator-parallel-ios-t036-access-wire-pilot-20261110-01/parallel-ios-t036-access-wire-pilot/check-2-ios-tests/stdout.log`
- simulator-smoke: PASS, local, exit 0; log `/Users/ruslansabirov/.codex/worktrees/d09a/Plants/docs/validation/automation/runs/orchestrator-parallel-ios-t036-access-wire-pilot-20261110-01/parallel-ios-t036-access-wire-pilot/check-3-simulator-smoke/stdout.log`

Review и QA подтвердили критерии manifest; это не автоматическое закрытие полной продуктовой задачи.

Решения: ["Патч ограничен тремя разрешёнными файлами; существующие сценарии и legacy DTO сохранены.", "Использованы семь согласованных fixtures, существующие SQLTimestamp, SyncSessionAuthority и mock-транспорты.", "Файлы и Git не изменялись. Проверки, применение патча и независимые Review/QA выполняет controller.", "Production GET не активирован; live-интеграции и завершение T036/T163 не заявляются."].

Ограничения: подтверждены только явно указанные режимы и критерии. State/metrics: `/Users/ruslansabirov/.codex/worktrees/d09a/Plants/docs/validation/automation/runs/orchestrator-parallel-ios-t036-access-wire-pilot-20261110-01`.
Следующий шаг: следующая независимая задача manifest; ошибки публикации смотреть в state.json.
