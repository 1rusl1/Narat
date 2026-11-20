# tester-today-rotated-stale

Show known stale cache after real canonical generation rotation followed by overview transport failure; preserve aligned offline availability.

Исправлено неверное ожидание теста: первый refresh без кеша создаёт canonical wrapper.

Изменённые файлы: ios/Plants/Features/Today/TodayHomeView.swift, ios/PlantsTests/CollectionWireTests.swift.

Вызовы — developer 2, reviewer 2, qa 1. Модели — 358.29 с, проверки — 263.45 с. Повторы моделей — 2, тайм-ауты моделей — 0, тайм-ауты проверок — 0.

Проверки:

- diff-check — PASS (local, exit 0, 0.05 с). Лог `/private/tmp/narat-tester-care-20261119/docs/validation/automation/runs/orchestrator-tester-today-rotated-stale-20261120-01/tester-today-rotated-stale/check-3-diff-check/stdout.log`.
- ios-tests — PASS (local, exit 0, 116.22 с). Лог `/private/tmp/narat-tester-care-20261119/docs/validation/automation/runs/orchestrator-tester-today-rotated-stale-20261120-01/tester-today-rotated-stale/check-4-ios-tests/stdout.log`.
- simulator-smoke — PASS (local, exit 0, 21.51 с). Лог `/private/tmp/narat-tester-care-20261119/docs/validation/automation/runs/orchestrator-tester-today-rotated-stale-20261120-01/tester-today-rotated-stale/check-5-simulator-smoke/stdout.log`.

Review и QA подтвердили критерии manifest; это не автоматическое закрытие полной продуктовой задачи.

Решения: ["Лог подтверждает единственное падение нового теста: сравнение созданного canonicalGeneration с nil в сценарии без кеша.", "beginCareOverviewRead сохраняет новый wrapper до сетевого запроса; ожидание скорректировано только для первого запроса без кеша.", "Проверки mismatch, stale, aligned offline и отсутствия выдуманного расписания сохранены. Повторные проверки выполняет контроллер."].

Ограничения: подтверждены только явно указанные режимы и критерии. State/metrics: `/private/tmp/narat-tester-care-20261119/docs/validation/automation/runs/orchestrator-tester-today-rotated-stale-20261120-01`.
Следующий шаг: следующая независимая задача manifest; ошибки публикации смотреть в state.json.
