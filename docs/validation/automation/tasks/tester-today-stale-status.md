# tester-today-stale-status

Keep explicit known-stale schedule status visible alongside refresh failure; narrow C3b reviewer repair.

Подготовлен узкий патч: известная неактуальность расписания остаётся видимой при ошибке обновления. Добавлен один регрессионный тест.

Изменённые файлы: ios/Plants/Features/Today/TodayHomeView.swift, ios/PlantsTests/CollectionWireTests.swift.

Вызовы — developer 1, reviewer 1, qa 1. Модели — 240.41 с, проверки — 154.29 с. Повторы моделей — 0, тайм-ауты моделей — 0, тайм-ауты проверок — 0.

Проверки:

- diff-check — PASS (local, exit 0, 0.04 с). Лог `/private/tmp/narat-tester-care-20261119/docs/validation/automation/runs/orchestrator-tester-today-stale-status-20261120-01/tester-today-stale-status/check-1-diff-check/stdout.log`.
- ios-tests — PASS (local, exit 0, 123.87 с). Лог `/private/tmp/narat-tester-care-20261119/docs/validation/automation/runs/orchestrator-tester-today-stale-status-20261120-01/tester-today-stale-status/check-2-ios-tests/stdout.log`.
- simulator-smoke — PASS (local, exit 0, 30.38 с). Лог `/private/tmp/narat-tester-care-20261119/docs/validation/automation/runs/orchestrator-tester-today-stale-status-20261120-01/tester-today-stale-status/check-3-simulator-smoke/stdout.log`.

Review и QA подтвердили критерии manifest; это не автоматическое закрытие полной продуктовой задачи.

Решения: ["Прочитан фактический отчёт Reviewer; предикат используется непосредственно SwiftUI и проверяется через repository/cache/TodayModel.", "Существующие ограничения дат, доступа, владельца и pending сохранены; прежние тесты не изменены.", "Файлы и Git не изменялись. Проверки не запускались: fullSwift/build/welcome/MCP и highReviewQA выполняет контроллер.", "PASS означает готовность патча к проверкам. Приёмка всего C3b остаётся отдельным этапом; живые интеграции не подтверждены."].

Ограничения: подтверждены только явно указанные режимы и критерии. State/metrics: `/private/tmp/narat-tester-care-20261119/docs/validation/automation/runs/orchestrator-tester-today-stale-status-20261120-01`.
Следующий шаг: следующая независимая задача manifest; ошибки публикации смотреть в state.json.
