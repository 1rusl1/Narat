# tester-care-reminder-cleanup-failure

Ensure foreign-owner and explicit optout/logout OS cleanup still runs when receipt metadata cannot be read/saved; preserve ordinary untrusted-identity durable-before-remove barriers.

Подготовлен патч очистки при ошибках receipt metadata и три группы регрессий с реальным Store.

Изменённые файлы: ios/Plants/Integrations/Notifications/CareReminderScheduler.swift, ios/PlantsTests/CollectionWireTests.swift.

Вызовы — developer 1, reviewer 1, qa 1. Модели — 421.20 с, проверки — 188.37 с. Повторы моделей — 0, тайм-ауты моделей — 0, тайм-ауты проверок — 0.

Проверки:

- diff-check — PASS (local, exit 0, 0.05 с). Лог `/private/tmp/narat-tester-care-20261119/docs/validation/automation/runs/orchestrator-tester-care-reminder-cleanup-failure-20261120-02/tester-care-reminder-cleanup-failure/check-1-diff-check/stdout.log`.
- ios-tests — PASS (local, exit 0, 163.94 с). Лог `/private/tmp/narat-tester-care-20261119/docs/validation/automation/runs/orchestrator-tester-care-reminder-cleanup-failure-20261120-02/tester-care-reminder-cleanup-failure/check-2-ios-tests/stdout.log`.
- simulator-smoke — PASS (local, exit 0, 24.38 с). Лог `/private/tmp/narat-tester-care-20261119/docs/validation/automation/runs/orchestrator-tester-care-reminder-cleanup-failure-20261120-02/tester-care-reminder-cleanup-failure/check-3-simulator-smoke/stdout.log`.

Review и QA подтвердили критерии manifest; это не автоматическое закрытие полной продуктовой задачи.

Решения: ["Foreign cleanup выполняется до открытия текущего ledger; ошибки metadata остаются видимыми.", "Explicit cleanup сохраняет барьер для неизвестных own canonical ID с valid route и route=nil. При нечитаемом ledger наличие receipt не предполагается.", "Fallback не создаёт cancellation proof; ошибки сохраняют cleanupRequired. Logout без SDK использует существующий путь.", "Добавлены три группы realStore/fakeOS регрессий; существующие assertions не изменены.", "Файлы, Git, handoff и tasks не изменялись. Проверки выполнит контроллер; PASS означает готовность патча к ним, без заявления о Review/QA, Root или runtime."].

Ограничения: подтверждены только явно указанные режимы и критерии. State/metrics: `/private/tmp/narat-tester-care-20261119/docs/validation/automation/runs/orchestrator-tester-care-reminder-cleanup-failure-20261120-02`.
Следующий шаг: следующая независимая задача manifest; ошибки публикации смотреть в state.json.
