# v19-ios-refresh-rejection

Repair reviewer P2: a permanent refresh rejection removes the queue item but is incorrectly shown as a successful refresh in the English card.

Исправлены контекст и формат патча. Отклонённое обновление показывает ошибку; подтверждённый результат отделён от pending и отсутствующей операции.

Изменённые файлы: ios/Plants/Data/Repositories/CollectionRepository.swift, ios/Plants/Data/Sync/SyncEngine.swift, ios/Plants/Features/Catalogue/GuestCatalogueView.swift, ios/PlantsTests/CollectionWireTests.swift.

Вызовы — developer 2, reviewer 1, qa 1. Модели — 500.57 с, проверки — 262.13 с. Повторы моделей — 1, тайм-ауты моделей — 0, тайм-ауты проверок — 0.

Проверки:

- diff-check — PASS (local, exit 0, 0.04 с). Лог `/Users/ruslansabirov/.codex/worktrees/d09a/Plants/docs/validation/automation/runs/orchestrator-v19-ios-refresh-rejection-codex-20261115-02/v19-ios-refresh-rejection/check-1-diff-check/stdout.log`.
- ios-tests — PASS (local, exit 0, 115.77 с). Лог `/Users/ruslansabirov/.codex/worktrees/d09a/Plants/docs/validation/automation/runs/orchestrator-v19-ios-refresh-rejection-codex-20261115-02/v19-ios-refresh-rejection/check-2-ios-tests/stdout.log`.
- simulator-smoke — PASS (local, exit 0, 34.69 с). Лог `/Users/ruslansabirov/.codex/worktrees/d09a/Plants/docs/validation/automation/runs/orchestrator-v19-ios-refresh-rejection-codex-20261115-02/v19-ios-refresh-rejection/check-3-simulator-smoke/stdout.log`.
- v19-care-ui — PASS (fixture, exit 0, 111.64 с). Лог `/Users/ruslansabirov/.codex/worktrees/d09a/Plants/docs/validation/automation/runs/orchestrator-v19-ios-refresh-rejection-codex-20261115-02/v19-ios-refresh-rejection/check-4-v19-care-ui/stdout.log`.

Review и QA подтвердили критерии manifest; это не автоматическое закрытие полной продуктовой задачи.

Решения: ["Все удаляемые строки и контекст каждого блока сверены с текущими файлами без записи на диск.", "Постоянный отказ передаётся только соответствующему прямому refresh-вызову; фоновый drain сохраняет прежнее поведение.", "Регрессия покрывает четыре постоянных отказа, retryable-ответ, точный повтор запроса, paused receipt и отсутствие операции. Restart-тест дополнен проверками исходов.", "Сборка, unit- и UI-тесты оставлены контроллеру."].

Ограничения: подтверждены только явно указанные режимы и критерии. State/metrics: `/Users/ruslansabirov/.codex/worktrees/d09a/Plants/docs/validation/automation/runs/orchestrator-v19-ios-refresh-rejection-codex-20261115-02`.
Следующий шаг: следующая независимая задача manifest; ошибки публикации смотреть в state.json.
