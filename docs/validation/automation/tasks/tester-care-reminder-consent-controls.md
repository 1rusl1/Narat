# tester-care-reminder-consent-controls

Fix opt-out UI truth and add matched DEBUG controls/evidence for rendered consent tests; Core/receipt policy unchanged.

Подготовлен патч: честный статус очистки при opt-out, scoped DEBUG-контролы, совместимый fake-ledger и регрессии.

Изменённые файлы: ios/Plants/App/PlantsApp.swift, ios/Plants/Features/CareTasks/ReminderConsentFixtureControls.swift, ios/Plants/Features/CareTasks/ReminderConsentFixtures.swift, ios/Plants/Features/CareTasks/ReminderConsentView.swift, ios/PlantsTests/CollectionWireTests.swift.

Вызовы — developer 1, reviewer 1, qa 1. Модели — 772.12 с, проверки — 254.46 с. Повторы моделей — 0, тайм-ауты моделей — 0, тайм-ауты проверок — 0.

Проверки:

- diff-check — PASS (local, exit 0, 0.05 с). Лог `/private/tmp/narat-tester-care-20261119/docs/validation/automation/runs/orchestrator-tester-care-reminder-consent-controls-20261121-01/tester-care-reminder-consent-controls/check-1-diff-check/stdout.log`.
- automation-tests — PASS (fixture, exit 0, 54.13 с). Лог `/private/tmp/narat-tester-care-20261119/docs/validation/automation/runs/orchestrator-tester-care-reminder-consent-controls-20261121-01/tester-care-reminder-consent-controls/check-2-automation-tests/stdout.log`.
- ios-tests — PASS (local, exit 0, 169.75 с). Лог `/private/tmp/narat-tester-care-20261119/docs/validation/automation/runs/orchestrator-tester-care-reminder-consent-controls-20261121-01/tester-care-reminder-consent-controls/check-3-ios-tests/stdout.log`.
- simulator-smoke — PASS (local, exit 0, 30.52 с). Лог `/private/tmp/narat-tester-care-20261119/docs/validation/automation/runs/orchestrator-tester-care-reminder-consent-controls-20261121-01/tester-care-reminder-consent-controls/check-4-simulator-smoke/stdout.log`.

Review и QA подтвердили критерии manifest; это не автоматическое закрытие полной продуктовой задачи.

Решения: ["Unified diff сформирован программно через difflib из текущих файлов; рабочее дерево, Git, handoff и tasks не изменялись.", "Core/Runtime/Bootstrap/Scheduler/receipt/System и исторические assertions сохранены; изменено только разрешённое ожидание off-проекции.", "Обязательные проверки оставлены контроллеру. PASS означает готовность патча к проверкам; rendered UI и живые интеграции не объявлены готовыми."].

Ограничения: подтверждены только явно указанные режимы и критерии. State/metrics: `/private/tmp/narat-tester-care-20261119/docs/validation/automation/runs/orchestrator-tester-care-reminder-consent-controls-20261121-01`.
Следующий шаг: следующая независимая задача manifest; ошибки публикации смотреть в state.json.
