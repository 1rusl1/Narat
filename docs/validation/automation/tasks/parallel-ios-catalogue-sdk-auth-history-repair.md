# parallel-ios-catalogue-sdk-auth-history-repair

Fix persistent SDK session-history guard after terminal refresh cleanup; independently accept FULL unaccepted real SDK connection candidate with production initial-session and repeated-call regressions.

Подготовлен патч постоянной защиты истории SDK-сессии и регрессия terminal cleanup. Готово к проверкам контроллера.

Изменённые файлы: ios/Plants/Features/Catalogue/GuestCatalogueView.swift, ios/PlantsTests/CatalogueConnectionTests.swift.

Проверки:

- diff-check: PASS, local, exit 0; log `/Users/ruslansabirov/.codex/worktrees/d09a/Plants/docs/validation/automation/runs/orchestrator-parallel-ios-catalogue-sdk-session-20261110-02/parallel-ios-catalogue-sdk-auth-history-repair/check-1-diff-check/stdout.log`
- ios-tests: PASS, local, exit 0; log `/Users/ruslansabirov/.codex/worktrees/d09a/Plants/docs/validation/automation/runs/orchestrator-parallel-ios-catalogue-sdk-session-20261110-02/parallel-ios-catalogue-sdk-auth-history-repair/check-2-ios-tests/stdout.log`
- simulator-smoke: PASS, local, exit 0; log `/Users/ruslansabirov/.codex/worktrees/d09a/Plants/docs/validation/automation/runs/orchestrator-parallel-ios-catalogue-sdk-session-20261110-02/parallel-ios-catalogue-sdk-auth-history-repair/check-3-simulator-smoke/stdout.log`

Review и QA подтвердили критерии manifest; это не автоматическое закрытие полной продуктовой задачи.

Решения: ["История сессии сохраняется на весь срок connection: начальное состояние берётся из реального SDK, обновления — синхронно из SDK callbacks.", "Один новый XCTest покрывает восемь сценариев: оба cleanup-кода, anonymous/permanent, очистку до первого sessionOwner и во время него, повторные вызовы и отсутствие изменений SQLite.", "Существующие тесты, включая production initial-session regression, сохранены. Проверки выполняет контроллер; файлы, Git, handoff и tasks не изменялись."].

Ограничения: подтверждены только явно указанные режимы и критерии. State/metrics: `/Users/ruslansabirov/.codex/worktrees/d09a/Plants/docs/validation/automation/runs/orchestrator-parallel-ios-catalogue-sdk-session-20261110-02`.
Следующий шаг: следующая независимая задача manifest; ошибки публикации смотреть в state.json.
