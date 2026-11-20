# tester-care-today-model

Implement small owner/locale scoped Today state model with local-overlay race fencing and precise access deadline metadata; no UI or networking integration yet.

Устранена блокировка EN-refresh при сохранённом PL-кэше. Добавлен регрессионный fixture-сценарий.

Изменённые файлы: ios/Plants/Data/Repositories/CollectionRepository.swift, ios/Plants/Features/Today/TodayModel.swift, ios/PlantsTests/CollectionWireTests.swift.

Вызовы — developer 3, reviewer 2, qa 1. Модели — 674.58 с, проверки — 256.86 с. Повторы моделей — 3, тайм-ауты моделей — 0, тайм-ауты проверок — 0.

Проверки:

- diff-check — PASS (local, exit 0, 0.02 с). Лог `/private/tmp/narat-tester-care-20261119/docs/validation/automation/runs/orchestrator-tester-care-today-model-20261120-01/tester-care-today-model/check-3-diff-check/stdout.log`.
- ios-tests — PASS (local, exit 0, 112.61 с). Лог `/private/tmp/narat-tester-care-20261119/docs/validation/automation/runs/orchestrator-tester-care-today-model-20261120-01/tester-care-today-model/check-4-ios-tests/stdout.log`.
- simulator-smoke — PASS (local, exit 0, 20.84 с). Лог `/private/tmp/narat-tester-care-20261119/docs/validation/automation/runs/orchestrator-tester-care-today-model-20261120-01/tester-care-today-model/check-5-simulator-smoke/stdout.log`.

Review и QA подтвердили критерии manifest; это не автоматическое закрытие полной продуктовой задачи.

Решения: ["Завершённое чтение своего owner снимает локальную блокировку даже при несовпадении locale; прежнее состояние скрыто, needsRevalidation остаётся true.", "Защита незавершённого локального чтения и устаревших callbacks сохранена.", "Расширен существующий тест: PL-кэш → EN-активация → локальное чтение → EN-refresh через fixture transport.", "git apply --check: exit 0. Успешные проверки контроллера повторно не запускались; новый patch ожидает его проверок."].

Ограничения: подтверждены только явно указанные режимы и критерии. State/metrics: `/private/tmp/narat-tester-care-20261119/docs/validation/automation/runs/orchestrator-tester-care-today-model-20261120-01`.
Следующий шаг: следующая независимая задача manifest; ошибки публикации смотреть в state.json.
