# t170-guest-initial-diagnosis-ios

Connect normal Check a plant to the bound guest first-diagnosis flow, with a pre-auth result.

Подготовлен Swift-патч гостевой диагностики до входа с фикстурами транспорта, повторов и изоляции владельца.

Изменённые файлы: ios/Plants/App/PlantsApp.swift, ios/Plants/Data/Remote/PlantsAPIClient.swift, ios/PlantsTests/CollectionWireTests.swift.

Вызовы — developer 1, reviewer 1, qa 1. Модели — 379.97 с, проверки — 155.46 с. Повторы моделей — 0, тайм-ауты моделей — 0, тайм-ауты проверок — 0.

Проверки:

- diff-check — PASS (local, exit 0, 0.05 с). Лог `/private/tmp/narat-ios-initial-context-20261116/docs/validation/automation/runs/orchestrator-t170-guest-initial-diagnosis-ios-codex-20261116-23/t170-guest-initial-diagnosis-ios/check-1-diff-check/stdout.log`.
- ios-tests — PASS (local, exit 0, 126.24 с). Лог `/private/tmp/narat-ios-initial-context-20261116/docs/validation/automation/runs/orchestrator-t170-guest-initial-diagnosis-ios-codex-20261116-23/t170-guest-initial-diagnosis-ios/check-2-ios-tests/stdout.log`.
- simulator-smoke — PASS (local, exit 0, 29.18 с). Лог `/private/tmp/narat-ios-initial-context-20261116/docs/validation/automation/runs/orchestrator-t170-guest-initial-diagnosis-ios-codex-20261116-23/t170-guest-initial-diagnosis-ios/check-3-simulator-smoke/stdout.log`.

Review и QA подтвердили критерии manifest; это не автоматическое закрытие полной продуктовой задачи.

Решения: ["Check a plant использует существующую регистрацию installation-bound гостя по действию пользователя и открывает фото без постоянного входа.", "Гостевая диагностика передаёт закрытый initial_context; существующие credential, lease, загрузка, повторы и UI результата переиспользуются.", "Добавлены фикстуры разрыва соединения, неизменности контекста, другого владельца и потери поколения lease.", "Проверки запускает контроллер. Живая диагностика и перенос/сохранение ожидают совместимый сервер.", "Файлы, Git, handoff и tasks не изменялись."].

Ограничения: подтверждены только явно указанные режимы и критерии. State/metrics: `/private/tmp/narat-ios-initial-context-20261116/docs/validation/automation/runs/orchestrator-t170-guest-initial-diagnosis-ios-codex-20261116-23`.
Следующий шаг: следующая независимая задача manifest; ошибки публикации смотреть в state.json.
