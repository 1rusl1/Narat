# parallel-ios-retire-slot-writers

Retire remaining Swift FreeSelection/free-slot encoders while keeping historical decode and exact persisted legacy rows/payloads. No collection business or UI redesign.

Подготовлен патч: устаревшие typed-записи отключены, историческое чтение сохранено. Добавлены четыре теста, включая дисковое хранение и generic replay.

Изменённые файлы: ios/Plants/Data/Remote/APIModels.swift, ios/Plants/Domain/PlantTypes.swift, ios/PlantsTests/SyncPersistenceTests.swift.

Проверки:

- diff-check: PASS, local, exit 0; log `/Users/ruslansabirov/.codex/worktrees/d09a/Plants/docs/validation/automation/runs/orchestrator-parallel-ios-retire-slot-writers-20261110-01/parallel-ios-retire-slot-writers/check-1-diff-check/stdout.log`
- ios-tests: PASS, local, exit 0; log `/Users/ruslansabirov/.codex/worktrees/d09a/Plants/docs/validation/automation/runs/orchestrator-parallel-ios-retire-slot-writers-20261110-01/parallel-ios-retire-slot-writers/check-2-ios-tests/stdout.log`
- simulator-smoke: PASS, local, exit 0; log `/Users/ruslansabirov/.codex/worktrees/d09a/Plants/docs/validation/automation/runs/orchestrator-parallel-ios-retire-slot-writers-20261110-01/parallel-ios-retire-slot-writers/check-3-simulator-smoke/stdout.log`

Review и QA подтвердили критерии manifest; это не автоматическое закрытие полной продуктовой задачи.

Решения: ["FreeSelection переведён в Decodable; кодирование selectFreePlants отклоняется через EncodingError.", "ProfileDTO и BasicCareMembership читают исторические поля и используют false/nil/0 при их отсутствии; encoding сохраняет остальные поля и прежнее поведение optional.", "Добавлены четыре теста без изменения существующих: legacy/current/null JSON, сохранность остальных значений, enum и дисковый reopen с точными байтами и generic replay.", "Файлы и Git не изменялись. Build, unit tests и Simulator выполняет контроллер; PASS означает готовность патча к этим проверкам."].

Ограничения: подтверждены только явно указанные режимы и критерии. State/metrics: `/Users/ruslansabirov/.codex/worktrees/d09a/Plants/docs/validation/automation/runs/orchestrator-parallel-ios-retire-slot-writers-20261110-01`.
Следующий шаг: следующая независимая задача manifest; ошибки публикации смотреть в state.json.
