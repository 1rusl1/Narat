# v19-routine-undo-outbox

Persist owner routine soil-check reversal through loss, restart and canonical sync before acknowledging it.

Исправлен порядок изменений в sync fixture, из-за которого корректный replay оставался pending.

Изменённые файлы: ios/Plants/Data/Local/LocalStore.swift, ios/Plants/Data/Repositories/CollectionRepository.swift, ios/Plants/Data/Sync/SyncEngine.swift, ios/PlantsTests/CollectionWireTests.swift.

Вызовы — developer 3, reviewer 1, qa 1. Модели — 943.30 с, проверки — 258.71 с. Повторы моделей — 2, тайм-ауты моделей — 0, тайм-ауты проверок — 0.

Проверки:

- diff-check — PASS (local, exit 0, 0.04 с). Лог `/Users/ruslansabirov/.codex/worktrees/d09a/Plants/docs/validation/automation/runs/orchestrator-v19-routine-undo-outbox-codex-20261115-09/v19-routine-undo-outbox/check-3-diff-check/stdout.log`.
- ios-tests — PASS (local, exit 0, 102.91 с). Лог `/Users/ruslansabirov/.codex/worktrees/d09a/Plants/docs/validation/automation/runs/orchestrator-v19-routine-undo-outbox-codex-20261115-09/v19-routine-undo-outbox/check-4-ios-tests/stdout.log`.
- simulator-smoke — PASS (local, exit 0, 35.87 с). Лог `/Users/ruslansabirov/.codex/worktrees/d09a/Plants/docs/validation/automation/runs/orchestrator-v19-routine-undo-outbox-codex-20261115-09/v19-routine-undo-outbox/check-5-simulator-smoke/stdout.log`.

Review и QA подтвердили критерии manifest; это не автоматическое закрытие полной продуктовой задачи.

Решения: ["Причина установлена: fixture добавлял reversal после task, нарушая обязательный порядок canonical sync по timestamp/entity/id.", "Добавлена проверка watermark для каждой попытки: отрицательные сценарии должны проверять связи после успешной синхронизации.", "Успешные проверки не повторялись; ios-tests запускает контроллер. Файлы не изменялись. T160/T171 остаются открытыми."].

Ограничения: подтверждены только явно указанные режимы и критерии. State/metrics: `/Users/ruslansabirov/.codex/worktrees/d09a/Plants/docs/validation/automation/runs/orchestrator-v19-routine-undo-outbox-codex-20261115-09`.
Следующий шаг: следующая независимая задача manifest; ошибки публикации смотреть в state.json.
