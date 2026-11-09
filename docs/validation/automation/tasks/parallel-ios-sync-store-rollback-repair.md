# parallel-ios-sync-store-rollback-repair

Repair actual LocalStore failed-save atomicity: memory checkpoint must remain old after SQLite read-only save failure. Then independently accept FULL canonical A2 engine/disk/session candidate.

Подготовлен точечный patch: изоляция SwiftData-контекстов устраняет утечку checkpoint после failed save; регрессии усилены.

Изменённые файлы: ios/Plants/Data/Local/LocalStore.swift, ios/PlantsTests/CollectionWireTests.swift.

Проверки:

- diff-check: PASS, local, exit 0; log `/Users/ruslansabirov/.codex/worktrees/d09a/Plants/docs/validation/automation/runs/orchestrator-parallel-ios-sync-store-20261109-04/parallel-ios-sync-store-rollback-repair/check-1-diff-check/stdout.log`
- deno-tests: PASS, fixture, exit 0; log `/Users/ruslansabirov/.codex/worktrees/d09a/Plants/docs/validation/automation/runs/orchestrator-parallel-ios-sync-store-20261109-04/parallel-ios-sync-store-rollback-repair/check-2-deno-tests/stdout.log`
- ios-tests: PASS, local, exit 0; log `/Users/ruslansabirov/.codex/worktrees/d09a/Plants/docs/validation/automation/runs/orchestrator-parallel-ios-sync-store-20261109-04/parallel-ios-sync-store-rollback-repair/check-3-ios-tests/stdout.log`
- simulator-smoke: PASS, local, exit 0; log `/Users/ruslansabirov/.codex/worktrees/d09a/Plants/docs/validation/automation/runs/orchestrator-parallel-ios-sync-store-20261109-04/parallel-ios-sync-store-rollback-repair/check-4-simulator-smoke/stdout.log`

Review и QA подтвердили критерии manifest; это не автоматическое закрытие полной продуктовой задачи.

Решения: ["Запись окна выполняется отдельным контекстом с отключённым autosave; последующие чтения получают сохранённое состояние. Проверки session generation и cancellation внутри публикации сохранены.", "Усилены существующие тесты: реальные ошибки Cocoa 513 при full refresh и delta, сохранность checkpoint/profile/entitlement/entities/outbox, независимое открытие диска и следующий запрос с исходным since; успешные изменения видны тому же LocalStore.", "APIModels и nullable encoder не изменены. Canonical-путь требует bindSyncSession при входе/обновлении сессии и bindSyncSession(nil) при выходе; UI/repository-интеграция остаётся отдельной работой.", "Проверки не запускались: patch готов для команд контроллера, затем полного Review/QA A2. Файлы, Git, handoff и tasks не изменялись; live/UI и T162/T025/T026/T149 не объявляются завершёнными."].

Ограничения: подтверждены только явно указанные режимы и критерии. State/metrics: `/Users/ruslansabirov/.codex/worktrees/d09a/Plants/docs/validation/automation/runs/orchestrator-parallel-ios-sync-store-20261109-04`.
Следующий шаг: следующая независимая задача manifest; ошибки публикации смотреть в state.json.
