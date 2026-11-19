# tester-care-saved-watering-api

Add narrow existing-plant manual watering enqueue/retry on the accepted canonical ACK machinery, without a create confirmation or care entitlement requirement.

Исправлены две причины падения тестов: выбор точного entryId при ACK и устаревшая строка растения в delta fixture.

Изменённые файлы: ios/Plants/Data/Local/LocalStore.swift, ios/Plants/Data/Repositories/CollectionRepository.swift, ios/Plants/Data/Sync/SyncEngine.swift, ios/PlantsTests/CollectionWireTests.swift.

Вызовы — developer 3, reviewer 1, qa 1. Модели — 941.38 с, проверки — 259.77 с. Повторы моделей — 2, тайм-ауты моделей — 0, тайм-ауты проверок — 0.

Проверки:

- diff-check — PASS (local, exit 0, 0.04 с). Лог `/private/tmp/narat-tester-care-20261119/docs/validation/automation/runs/orchestrator-tester-care-record-api-20261119-01/tester-care-saved-watering-api/check-3-diff-check/stdout.log`.
- ios-tests — PASS (local, exit 0, 109.66 с). Лог `/private/tmp/narat-tester-care-20261119/docs/validation/automation/runs/orchestrator-tester-care-record-api-20261119-01/tester-care-saved-watering-api/check-4-ios-tests/stdout.log`.
- simulator-smoke — PASS (local, exit 0, 28.28 с). Лог `/private/tmp/narat-tester-care-20261119/docs/validation/automation/runs/orchestrator-tester-care-record-api-20261119-01/tester-care-saved-watering-api/check-5-simulator-smoke/stdout.log`.

Review и QA подтвердили критерии manifest; это не автоматическое закрытие полной продуктовой задачи.

Решения: ["Общий identity core сохранён; ACK ищет именно entryId из receipt, включая исправленные и отменённые записи.", "Delta fixture возвращает новый факт без строки растения на границе since. Проверки и assertions не ослаблены.", "По логам контроллера build прошёл; unit выявил исправленные причины. Повторные проверки выполняет контроллер."].

Ограничения: подтверждены только явно указанные режимы и критерии. State/metrics: `/private/tmp/narat-tester-care-20261119/docs/validation/automation/runs/orchestrator-tester-care-record-api-20261119-01`.
Следующий шаг: следующая независимая задача manifest; ошибки публикации смотреть в state.json.
