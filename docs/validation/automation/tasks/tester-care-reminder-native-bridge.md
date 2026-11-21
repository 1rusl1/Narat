# tester-care-reminder-native-bridge

Add shared early System launch isolation, bounded typed pre-Root inbox and inert native UN callback adapter; no registration or Root wiring.

Подготовлен патч: общая launch-policy, ограниченный типизированный inbox и инертный UN-адаптер; добавлены 7 тестов.

Изменённые файлы: ios/Plants/Integrations/Notifications/CareReminderNotificationBridge.swift, ios/PlantsTests/CollectionWireTests.swift.

Вызовы — developer 1, reviewer 1, qa 1. Модели — 494.00 с, проверки — 227.10 с. Повторы моделей — 0, тайм-ауты моделей — 0, тайм-ауты проверок — 0.

Проверки:

- diff-check — PASS (local, exit 0, 0.04 с). Лог `/private/tmp/narat-tester-care-20261119/docs/validation/automation/runs/orchestrator-tester-care-reminder-native-bridge-20261122-01/tester-care-reminder-native-bridge/check-1-diff-check/stdout.log`.
- automation-tests — PASS (fixture, exit 0, 41.79 с). Лог `/private/tmp/narat-tester-care-20261119/docs/validation/automation/runs/orchestrator-tester-care-reminder-native-bridge-20261122-01/tester-care-reminder-native-bridge/check-2-automation-tests/stdout.log`.
- ios-tests — PASS (local, exit 0, 161.40 с). Лог `/private/tmp/narat-tester-care-20261119/docs/validation/automation/runs/orchestrator-tester-care-reminder-native-bridge-20261122-01/tester-care-reminder-native-bridge/check-3-ios-tests/stdout.log`.
- simulator-smoke — PASS (local, exit 0, 23.87 с). Лог `/private/tmp/narat-tester-care-20261119/docs/validation/automation/runs/orchestrator-tester-care-reminder-native-bridge-20261122-01/tester-care-reminder-native-bridge/check-4-simulator-smoke/stdout.log`.

Review и QA подтвердили критерии manifest; это не автоматическое закрытие полной продуктовой задачи.

Решения: ["Diff сформирован через difflib из фактических файлов; изменяются только два разрешённых файла, существующие тесты сохранены.", "Inbox хранит один tap, последний foreground и максимум 64 ключа дедупликации; повтор не меняет intentID и payload.", "UN callbacks синхронно разбирают payload существующей Factory и завершаются через defer; Task получает только Sendable event и sink.", "Добавлены проверки обоих SDK selectors, отклонённых callbacks, синхронного completion, удержанного sink, исторического payload и разделения foreground/tap.", "Проверки сборки, Swift, automation и Simulator выполняет контроллер; локально они не запускались.", "Тесты используют метаданные Factory и callback-entry helpers. Реальные OS callbacks, ранняя регистрация/strong retention, общая runtime-пара, Release bootstrap и legacy-сценарии остаются D2B; SDK-авторизация и маршрутизация — D3.", "Файлы, Git, handoff и tasks не изменялись."].

Ограничения: подтверждены только явно указанные режимы и критерии. State/metrics: `/private/tmp/narat-tester-care-20261119/docs/validation/automation/runs/orchestrator-tester-care-reminder-native-bridge-20261122-01`.
Следующий шаг: следующая независимая задача manifest; ошибки публикации смотреть в state.json.
