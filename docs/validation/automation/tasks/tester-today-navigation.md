# tester-today-navigation

Fix first-presentation one-shot Today task target handoff to current canonical collection card; preserve scope/freshness and Back/Close behavior.

Подготовлен узкий патч: цель Today принадлежит конкретному sheet, одноразовое потребление остаётся локальным.

Изменённые файлы: ios/Plants/App/PlantsApp.swift, ios/Plants/Features/Catalogue/GuestCatalogueView.swift.

Вызовы — developer 1, reviewer 1, qa 1. Модели — 288.43 с, проверки — 173.83 с. Повторы моделей — 0, тайм-ауты моделей — 0, тайм-ауты проверок — 0.

Проверки:

- diff-check — PASS (local, exit 0, 0.03 с). Лог `/private/tmp/narat-tester-care-20261119/docs/validation/automation/runs/orchestrator-tester-today-navigation-20261120-01/tester-today-navigation/check-1-diff-check/stdout.log`.
- ios-tests — PASS (local, exit 0, 108.47 с). Лог `/private/tmp/narat-tester-care-20261119/docs/validation/automation/runs/orchestrator-tester-today-navigation-20261120-01/tester-today-navigation/check-2-ios-tests/stdout.log`.
- simulator-smoke — PASS (local, exit 0, 25.19 с). Лог `/private/tmp/narat-tester-care-20261119/docs/validation/automation/runs/orchestrator-tester-today-navigation-20261120-01/tester-today-navigation/check-3-simulator-smoke/stdout.log`.
- tester-today-navigation-ui — PASS (fixture, exit 0, 40.14 с). Лог `/private/tmp/narat-tester-care-20261119/docs/validation/automation/runs/orchestrator-tester-today-navigation-20261120-01/tester-today-navigation/check-4-tester-today-navigation-ui/stdout.log`.

Review и QA подтвердили критерии manifest; это не автоматическое закрытие полной продуктовой задачи.

Решения: ["sheet(item:) передаёт неизменяемую цель вместе с идентичностью презентации; отдельные состояния цели и показа устранены.", "Убран callback очистки родителя: targetConsumed действует только внутри текущей презентации, новая презентация получает новое состояние.", "Сохранены проверки исходного SDK scope, текущего чтения, свежести результата и UUID канонической карточки; Back/Close и обычные открытия коллекции сохраняют прежнюю логику.", "Файлы не изменялись. Обязательные проверки и неизменённый UI regression запускает контроллер после применения патча; итоговая приёмка ещё не выполнена."].

Ограничения: подтверждены только явно указанные режимы и критерии. State/metrics: `/private/tmp/narat-tester-care-20261119/docs/validation/automation/runs/orchestrator-tester-today-navigation-20261120-01`.
Следующий шаг: следующая независимая задача manifest; ошибки публикации смотреть в state.json.
