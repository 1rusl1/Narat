# tester-care-reminder-lifecycle-core

Add a small independent owner-scoped care reminder lifecycle core with cache-only signals, background hold and per-owner consent; no App/Root wiring or settings UI yet.

Исправлена expiry-фикстура: deadline допустим на момент серверного snapshot, но истёк к моменту локального чтения.

Изменённые файлы: ios/Plants/Integrations/Notifications/CareReminderLifecycle.swift, ios/PlantsTests/CollectionWireTests.swift.

Вызовы — developer 2, reviewer 1, qa 1. Модели — 769.63 с, проверки — 312.82 с. Повторы моделей — 1, тайм-ауты моделей — 0, тайм-ауты проверок — 0.

Проверки:

- diff-check — PASS (local, exit 0, 0.05 с). Лог `/private/tmp/narat-tester-care-20261119/docs/validation/automation/runs/orchestrator-tester-care-reminder-lifecycle-core-20261120-01/tester-care-reminder-lifecycle-core/check-3-diff-check/stdout.log`.
- ios-tests — PASS (local, exit 0, 138.86 с). Лог `/private/tmp/narat-tester-care-20261119/docs/validation/automation/runs/orchestrator-tester-care-reminder-lifecycle-core-20261120-01/tester-care-reminder-lifecycle-core/check-4-ios-tests/stdout.log`.
- simulator-smoke — PASS (local, exit 0, 24.19 с). Лог `/private/tmp/narat-tester-care-20261119/docs/validation/automation/runs/orchestrator-tester-care-reminder-lifecycle-core-20261120-01/tester-care-reminder-lifecycle-core/check-5-simulator-smoke/stdout.log`.

Review и QA подтвердили критерии manifest; это не автоматическое закрытие полной продуктовой задачи.

Решения: ["Лог подтверждает единственный сбой среди 420 тестов: invalidPage в новой expiry-фикстуре. Остальные четыре lifecycle-теста прошли.", "Причина подтверждена валидатором: при automationAllowed deadline должен быть позже serverNow. Новый deadline удовлетворяет этому условию и остаётся раньше внедрённых локальных часов.", "Production-код и прежние assertions сохранены. Проверки повторно не запускались; патч готов к проверкам контроллера."].

Ограничения: подтверждены только явно указанные режимы и критерии. State/metrics: `/private/tmp/narat-tester-care-20261119/docs/validation/automation/runs/orchestrator-tester-care-reminder-lifecycle-core-20261120-01`.
Следующий шаг: следующая независимая задача manifest; ошибки публикации смотреть в state.json.
