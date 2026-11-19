# tester-care-record-canonical-ack

Retain typed manual care.record receipt and require its canonical owner journal linkage before ACK, reusing existing sync/outbox. This is a narrow prerequisite for saved-card manual watering.

Подготовлен узкий патч: typed receipt care.record, проверка канонической связи перед ACK и дисковые регрессии повторной отправки.

Изменённые файлы: ios/Plants/Data/Local/LocalStore.swift, ios/Plants/Data/Remote/PlantsAPIClient.swift, ios/Plants/Data/Sync/SyncEngine.swift, ios/PlantsTests/CollectionWireTests.swift.

Вызовы — developer 1, reviewer 1, qa 1. Модели — 540.71 с, проверки — 145.49 с. Повторы моделей — 0, тайм-ауты моделей — 0, тайм-ауты проверок — 0.

Проверки:

- diff-check — PASS (local, exit 0, 0.05 с). Лог `/private/tmp/narat-tester-care-20261119/docs/validation/automation/runs/orchestrator-tester-care-record-ack-20261119-01/tester-care-record-canonical-ack/check-1-diff-check/stdout.log`.
- ios-tests — PASS (local, exit 0, 117.15 с). Лог `/private/tmp/narat-tester-care-20261119/docs/validation/automation/runs/orchestrator-tester-care-record-ack-20261119-01/tester-care-record-canonical-ack/check-2-ios-tests/stdout.log`.
- simulator-smoke — PASS (local, exit 0, 28.29 с). Лог `/private/tmp/narat-tester-care-20261119/docs/validation/automation/runs/orchestrator-tester-care-record-ack-20261119-01/tester-care-record-canonical-ack/check-3-simulator-smoke/stdout.log`.

Review и QA подтвердили критерии manifest; это не автоматическое закрытие полной продуктовой задачи.

Решения: ["Патч ограничен четырьмя разрешёнными файлами; файлы, Git, handoff и tasks не изменялись.", "ACK требует точной связи owner/plant/entry/operation и валидного manual water факта; уже сохранённая связь с достаточным watermark допускает ACK без повторного GET.", "Active и voided записи подтверждают создание; replay не перезаписывает исправленную дату или состояние.", "Добавлены дисковые сценарии потери ответа, отсутствующей/чужой/несовпадающей связи, некорректного факта и сбоя sync с точным повтором payload.", "Проверки сборки, Swift tests и Simulator выполняет controller; живые интеграции не запускались. T065/T160/T171 остаются открытыми."].

Ограничения: подтверждены только явно указанные режимы и критерии. State/metrics: `/private/tmp/narat-tester-care-20261119/docs/validation/automation/runs/orchestrator-tester-care-record-ack-20261119-01`.
Следующий шаг: следующая независимая задача manifest; ошибки публикации смотреть в state.json.
