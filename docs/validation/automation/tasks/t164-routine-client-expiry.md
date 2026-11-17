# t164-routine-client-expiry

Hide stale routine due dates and prevent new routine completions at the known server entitlement expiry.

Подготовлен патч: известный expiry скрывает дату и блокирует новую отметку; история, undo и точный replay сохранены.

Изменённые файлы: ios/Plants/Features/Catalogue/CatalogueUIFixtures.swift, ios/Plants/Features/Catalogue/GuestCatalogueView.swift, ios/PlantsTests/CatalogueUIFixtureTests.swift, ios/PlantsUITests/CatalogueSaveUITests.swift.

Вызовы — developer 2, reviewer 1, qa 1. Модели — 488.03 с, проверки — 653.56 с. Повторы моделей — 1, тайм-ауты моделей — 0, тайм-ауты проверок — 0.

Проверки:

- diff-check — PASS (local, exit 0, 0.04 с). Лог `/private/tmp/narat-ios-initial-context-20261116/docs/validation/automation/runs/orchestrator-t164-routine-client-expiry-codex-20261117-45/t164-routine-client-expiry/check-1-diff-check/stdout.log`.
- ios-tests — PASS (local, exit 0, 241.44 с). Лог `/private/tmp/narat-ios-initial-context-20261116/docs/validation/automation/runs/orchestrator-t164-routine-client-expiry-codex-20261117-45/t164-routine-client-expiry/check-2-ios-tests/stdout.log`.
- simulator-smoke — PASS (local, exit 0, 235.12 с). Лог `/private/tmp/narat-ios-initial-context-20261116/docs/validation/automation/runs/orchestrator-t164-routine-client-expiry-codex-20261117-45/t164-routine-client-expiry/check-3-simulator-smoke/stdout.log`.
- t164-expiry-ui — PASS (local, exit 0, 176.96 с). Лог `/private/tmp/narat-ios-initial-context-20261116/docs/validation/automation/runs/orchestrator-t164-routine-client-expiry-codex-20261117-45/t164-routine-client-expiry/check-4-t164-expiry-ui/stdout.log`.

Review и QA подтвердили критерии manifest; это не автоматическое закрытие полной продуктовой задачи.

Решения: ["Права читаются из локального canonical entitlement; отсутствие entitlement сохраняет Free.", "Добавлены таймер expiry, обновление при foreground и повторная проверка перед enqueue. Общий routineWriteAvailable не ограничен.", "Добавлены детерминированные fixture-часы и именованный UI-тест: активная дата/действие, expiry, журнал, foreground, повторное открытие и restart.", "Файлы и Git не изменялись. Проверки и запуск UI-теста выполняет контроллер; живые интеграции не запускались."].

Ограничения: подтверждены только явно указанные режимы и критерии. State/metrics: `/private/tmp/narat-ios-initial-context-20261116/docs/validation/automation/runs/orchestrator-t164-routine-client-expiry-codex-20261117-45`.
Следующий шаг: следующая независимая задача manifest; ошибки публикации смотреть в state.json.
