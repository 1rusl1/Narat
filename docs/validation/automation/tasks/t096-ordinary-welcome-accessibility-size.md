# t096-ordinary-welcome-accessibility-size

Keep ordinary home navigation reachable at iOS accessibility text sizes.

Подготовлен патч адаптации обычного домашнего экрана и XCUI-регрессии EN/PL для accessibility-размера текста.

Изменённые файлы: ios/Plants/App/PlantsApp.swift, ios/PlantsUITests/PlantsUITests.swift.

Вызовы — developer 1, reviewer 1, qa 3. Модели — 596.46 с, проверки — 159.41 с. Повторы моделей — 2, тайм-ауты моделей — 0, тайм-ауты проверок — 0.

Проверки:

- diff-check — PASS (local, exit 0, 0.04 с). Лог `/private/tmp/narat-ios-initial-context-20261116/docs/validation/automation/runs/orchestrator-t096-ordinary-welcome-accessibility-size-codex-20261116-30/t096-ordinary-welcome-accessibility-size/check-1-diff-check/stdout.log`.
- ios-tests — PASS (local, exit 0, 95.16 с). Лог `/private/tmp/narat-ios-initial-context-20261116/docs/validation/automation/runs/orchestrator-t096-ordinary-welcome-accessibility-size-codex-20261116-30/t096-ordinary-welcome-accessibility-size/check-2-ios-tests/stdout.log`.
- simulator-smoke — PASS (local, exit 0, 64.21 с). Лог `/private/tmp/narat-ios-initial-context-20261116/docs/validation/automation/runs/orchestrator-t096-ordinary-welcome-accessibility-size-codex-20261116-30/t096-ordinary-welcome-accessibility-size/check-3-simulator-smoke/stdout.log`.

Review и QA подтвердили критерии manifest; это не автоматическое закрытие полной продуктовой задачи.

Решения: ["Обычный домашний экран реализован как PlantHomeView; адаптация ограничена им. При accessibility-размерах заголовок и коллекция расположены вертикально, подписи растут по высоте; обычный размер сохраняет горизонтальную компоновку.", "Добавлена EN/PL XCUI-проверка системного предпочтения размера, фактического увеличения текста, прокрутки к каталогу и перехода туда и обратно в сборке без backend. Существующие EN no-args и PL smoke сохранены.", "Проверки выполняет контроллер; фактическое применение accessibility-размера пока не подтверждено. Тест завершится ошибкой, если платформа проигнорирует системное предпочтение.", "Файлы, Git, handoff и tasks не изменялись."].

Ограничения: подтверждены только явно указанные режимы и критерии. State/metrics: `/private/tmp/narat-ios-initial-context-20261116/docs/validation/automation/runs/orchestrator-t096-ordinary-welcome-accessibility-size-codex-20261116-30`.
Следующий шаг: следующая независимая задача manifest; ошибки публикации смотреть в state.json.
