# tester-care-reminder-consent-binding

Repair original consent-presentation SDK/locale/scope authority and deterministic stale-callback regression; A whole-union acceptance follows.

Исправлена причина трёх падений регрессии: после смены локали тест теперь публикует соответствующий EN-снимок через настоящий LocalStore.

Изменённые файлы: ios/Plants/App/PlantsApp.swift, ios/Plants/Features/CareTasks/ReminderConsentView.swift, ios/Plants/Features/Catalogue/GuestCatalogueView.swift, ios/Plants/Integrations/Notifications/CareReminderLifecycle.swift, ios/PlantsTests/CollectionWireTests.swift.

Вызовы — developer 2, reviewer 1, qa 1. Модели — 505.19 с, проверки — 343.02 с. Повторы моделей — 1, тайм-ауты моделей — 0, тайм-ауты проверок — 0.

Проверки:

- diff-check — PASS (local, exit 0, 0.05 с). Лог `/private/tmp/narat-tester-care-20261119/docs/validation/automation/runs/orchestrator-tester-care-reminder-consent-binding-20261121-01/tester-care-reminder-consent-binding/check-3-diff-check/stdout.log`.
- ios-tests — PASS (local, exit 0, 149.14 с). Лог `/private/tmp/narat-tester-care-20261119/docs/validation/automation/runs/orchestrator-tester-care-reminder-consent-binding-20261121-01/tester-care-reminder-consent-binding/check-4-ios-tests/stdout.log`.
- simulator-smoke — PASS (local, exit 0, 28.88 с). Лог `/private/tmp/narat-tester-care-20261119/docs/validation/automation/runs/orchestrator-tester-care-reminder-consent-binding-20261121-01/tester-care-reminder-consent-binding/check-5-simulator-smoke/stdout.log`.

Review и QA подтвердили критерии manifest; это не автоматическое закрытие полной продуктовой задачи.

Решения: ["Лог unit подтверждает три падения только для locale: тест передавал PL-снимок в EN-контекст, поэтому планировщик корректно исключал кандидатов.", "Исправлены только данные новой регрессии; assertions, production-код и защита соответствия локали сохранены.", "Проверки повторно не запускались; патч готов для проверок controller. Полная приёмка A остаётся отдельным этапом."].

Ограничения: подтверждены только явно указанные режимы и критерии. State/metrics: `/private/tmp/narat-tester-care-20261119/docs/validation/automation/runs/orchestrator-tester-care-reminder-consent-binding-20261121-01`.
Следующий шаг: следующая независимая задача manifest; ошибки публикации смотреть в state.json.
