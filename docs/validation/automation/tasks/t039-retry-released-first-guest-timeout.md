# t039-retry-released-first-guest-timeout

Make the existing Retry action recover a released first-diagnosis timeout.

Подготовлен Retry для подтверждённого released timeout первой диагностики с сохранением фото, ответов и языка.

Изменённые файлы: ios/Plants/App/PlantsApp.swift, ios/Plants/Features/Analysis/AnalysisFlowModel.swift, ios/Plants/Features/Analysis/PreliminaryResultView.swift, ios/PlantsTests/CollectionWireTests.swift.

Вызовы — developer 1, reviewer 1, qa 1. Модели — 383.89 с, проверки — 142.96 с. Повторы моделей — 0, тайм-ауты моделей — 0, тайм-ауты проверок — 0.

Проверки:

- diff-check — PASS (local, exit 0, 0.05 с). Лог `/private/tmp/narat-ios-initial-context-20261116/docs/validation/automation/runs/orchestrator-t039-retry-released-first-guest-timeout-ios-codex-20261116-27/t039-retry-released-first-guest-timeout/check-1-diff-check/stdout.log`.
- deno-tests — PASS (fixture, exit 0, 4.47 с). Лог `/private/tmp/narat-ios-initial-context-20261116/docs/validation/automation/runs/orchestrator-t039-retry-released-first-guest-timeout-ios-codex-20261116-27/t039-retry-released-first-guest-timeout/check-2-deno-tests/stdout.log`.
- ios-tests — PASS (local, exit 0, 109.12 с). Лог `/private/tmp/narat-ios-initial-context-20261116/docs/validation/automation/runs/orchestrator-t039-retry-released-first-guest-timeout-ios-codex-20261116-27/t039-retry-released-first-guest-timeout/check-3-ios-tests/stdout.log`.
- simulator-smoke — PASS (local, exit 0, 29.32 с). Лог `/private/tmp/narat-ios-initial-context-20261116/docs/validation/automation/runs/orchestrator-t039-retry-released-first-guest-timeout-ios-codex-20261116-27/t039-retry-released-first-guest-timeout/check-4-simulator-smoke/stdout.log`.

Review и QA подтвердили критерии manifest; это не автоматическое закрытие полной продуктовой задачи.

Решения: ["Новый create ID выделяется только после канонического expired/ANALYSIS_TIMEOUT/released; повтор использует подтверждённую загрузку и frozen request.", "Для небезопасного expired Retry скрыт; добавлены EN/PL сообщения с сохранением accessibility identifiers.", "Добавлены регрессии для локального timeout, потерянных ответов, повторных нажатий, смены владельца и исключения repeat/identification.", "Файлы и Git не изменялись. Проверки Swift и EN/PL Simulator выполнит controller; живые интеграции не запускались."].

Ограничения: подтверждены только явно указанные режимы и критерии. State/metrics: `/private/tmp/narat-ios-initial-context-20261116/docs/validation/automation/runs/orchestrator-t039-retry-released-first-guest-timeout-ios-codex-20261116-27`.
Следующий шаг: следующая независимая задача manifest; ошибки публикации смотреть в state.json.
