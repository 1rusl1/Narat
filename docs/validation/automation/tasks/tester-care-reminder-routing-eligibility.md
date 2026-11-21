# tester-care-reminder-routing-eligibility

Add pure post-fire current-occurrence notification route eligibility with exact owner/plant/subject/source date matching; no native or Root wiring.

Подготовлен чистый валидатор текущего occurrence и четыре группы регрессионных тестов.

Изменённые файлы: ios/Plants/Integrations/Notifications/CareReminderRouting.swift, ios/PlantsTests/CollectionWireTests.swift.

Вызовы — developer 1, reviewer 1, qa 1. Модели — 389.95 с, проверки — 241.19 с. Повторы моделей — 0, тайм-ауты моделей — 0, тайм-ауты проверок — 0.

Проверки:

- diff-check — PASS (local, exit 0, 0.02 с). Лог `/private/tmp/narat-tester-care-20261119/docs/validation/automation/runs/orchestrator-tester-care-reminder-routing-eligibility-20261122-01/tester-care-reminder-routing-eligibility/check-1-diff-check/stdout.log`.
- automation-tests — PASS (fixture, exit 0, 45.66 с). Лог `/private/tmp/narat-tester-care-20261119/docs/validation/automation/runs/orchestrator-tester-care-reminder-routing-eligibility-20261122-01/tester-care-reminder-routing-eligibility/check-2-automation-tests/stdout.log`.
- ios-tests — PASS (local, exit 0, 165.73 с). Лог `/private/tmp/narat-tester-care-20261119/docs/validation/automation/runs/orchestrator-tester-care-reminder-routing-eligibility-20261122-01/tester-care-reminder-routing-eligibility/check-3-ios-tests/stdout.log`.
- simulator-smoke — PASS (local, exit 0, 29.78 с). Лог `/private/tmp/narat-tester-care-20261119/docs/validation/automation/runs/orchestrator-tester-care-reminder-routing-eligibility-20261122-01/tester-care-reminder-routing-eligibility/check-4-simulator-smoke/stdout.log`.

Review и QA подтвердили критерии manifest; это не автоматическое закрытие полной продуктовой задачи.

Решения: ["Право чтения определяется через sharedPlan.currentOccurrences с точным сравнением ID, owner, plant, kind/subject и sourceDueYMD.", "Неопределённое или несогласованное состояние возвращает hold; известный careData authorizationDenied, expiry или отсутствие текущей задачи — drop.", "Изменены только два разрешённых файла в предлагаемом патче; существующие тесты и helper defaults сохранены.", "Патч сформирован difflib из фактических файлов без записи. Проверки выполняет контроллер.", "D2/D3: native callbacks, startup, SDK/epoch fences, Root/navigation и System delivery/tap остаются вне этого пакета; живые интеграции не проверялись."].

Ограничения: подтверждены только явно указанные режимы и критерии. State/metrics: `/private/tmp/narat-tester-care-20261119/docs/validation/automation/runs/orchestrator-tester-care-reminder-routing-eligibility-20261122-01`.
Следующий шаг: следующая независимая задача manifest; ошибки публикации смотреть в state.json.
