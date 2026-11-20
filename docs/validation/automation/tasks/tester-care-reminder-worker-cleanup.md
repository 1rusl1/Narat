# tester-care-reminder-worker-cleanup

Repair two Review-confirmed reminder cold-owner/untrusted-canonical cleanup gaps; existing serialized worker remains unaccepted until whole R2b2 union acceptance.

Подготовлены два узких исправления очистки и три регрессионных теста.

Изменённые файлы: ios/Plants/Integrations/Notifications/CareReminderReceipts.swift, ios/Plants/Integrations/Notifications/CareReminderScheduler.swift, ios/PlantsTests/CollectionWireTests.swift.

Вызовы — developer 1, reviewer 1, qa 1. Модели — 497.82 с, проверки — 178.37 с. Повторы моделей — 0, тайм-ауты моделей — 0, тайм-ауты проверок — 0.

Проверки:

- diff-check — PASS (local, exit 0, 0.04 с). Лог `/private/tmp/narat-tester-care-20261119/docs/validation/automation/runs/orchestrator-tester-care-reminder-worker-cleanup-20261120-01/tester-care-reminder-worker-cleanup/check-1-diff-check/stdout.log`.
- ios-tests — PASS (local, exit 0, 154.81 с). Лог `/private/tmp/narat-tester-care-20261119/docs/validation/automation/runs/orchestrator-tester-care-reminder-worker-cleanup-20261120-01/tester-care-reminder-worker-cleanup/check-2-ios-tests/stdout.log`.
- simulator-smoke — PASS (local, exit 0, 23.51 с). Лог `/private/tmp/narat-tester-care-20261119/docs/validation/automation/runs/orchestrator-tester-care-reminder-worker-cleanup-20261120-01/tester-care-reminder-worker-cleanup/check-3-simulator-smoke/stdout.log`.

Review и QA подтвердили критерии manifest; это не автоматическое закрытие полной продуктовой задачи.

Решения: ["Чужие canonical raw ID удаляются с readback до defer; собственные и непрозрачные ID при неизвестном состоянии сохраняются.", "Блокировки сохраняются в receipts v1 до удаления, проверяются при prepare и фильтрации кандидатов; исторические блокировки не увеличивают текущий счётчик.", "Добавлены регрессии для cold-owner, совместимости/валидации codec и реального дискового Store с отказом сохранения, restart, opt-out и full refresh. Существующие assertions сохранены.", "Файлы и Git не изменялись; проверки переданы контроллеру. PASS означает готовность патча к проверкам. Исходный Review FAIL остаётся непринятым до обязательных проверок и полной R2b2 union acceptance."].

Ограничения: подтверждены только явно указанные режимы и критерии. State/metrics: `/private/tmp/narat-tester-care-20261119/docs/validation/automation/runs/orchestrator-tester-care-reminder-worker-cleanup-20261120-01`.
Следующий шаг: следующая независимая задача manifest; ошибки публикации смотреть в state.json.
