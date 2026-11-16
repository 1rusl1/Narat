# t170-saved-diagnosis-condition-summary

Show the canonical diagnosis conditions on the immediate and restored save card.

Подготовлен патч: подтверждённые условия диагноза на сохранённой карточке, EN/PL и fixture восстановления с изоляцией владельца.

Изменённые файлы: ios/Plants/Features/Catalogue/CatalogueSaveModel.swift, ios/Plants/Features/Catalogue/CatalogueSaveView.swift, ios/PlantsTests/CatalogueConnectionTests.swift.

Вызовы — developer 1, reviewer 1, qa 1. Модели — 377.32 с, проверки — 327.12 с. Повторы моделей — 0, тайм-ауты моделей — 0, тайм-ауты проверок — 0.

Проверки:

- diff-check — PASS (local, exit 0, 0.04 с). Лог `/private/tmp/narat-ios-initial-context-20261116/docs/validation/automation/runs/orchestrator-t170-saved-diagnosis-condition-summary-ios-codex-20261116-32/t170-saved-diagnosis-condition-summary/check-1-diff-check/stdout.log`.
- ios-tests — PASS (local, exit 0, 204.05 с). Лог `/private/tmp/narat-ios-initial-context-20261116/docs/validation/automation/runs/orchestrator-t170-saved-diagnosis-condition-summary-ios-codex-20261116-32/t170-saved-diagnosis-condition-summary/check-2-ios-tests/stdout.log`.
- simulator-smoke — PASS (local, exit 0, 123.03 с). Лог `/private/tmp/narat-ios-initial-context-20261116/docs/validation/automation/runs/orchestrator-t170-saved-diagnosis-condition-summary-ios-codex-20261116-32/t170-saved-diagnosis-condition-summary/check-3-simulator-smoke/stdout.log`.

Review и QA подтвердили критерии manifest; это не автоматическое закрытие полной продуктовой задачи.

Решения: ["Используется существующий syncedPlantConditions с исходным lease; значения из входа анализа не синтезируются.", "Добавлены fixture-сценарии немедленного чтения, восстановления SQLite, отсутствующего/старого snapshot, чужого растения и смены владельца.", "Файлы и Git не изменялись. Обязательные проверки и EN/PL Simulator smoke выполняет контроллер."].

Ограничения: подтверждены только явно указанные режимы и критерии. State/metrics: `/private/tmp/narat-ios-initial-context-20261116/docs/validation/automation/runs/orchestrator-t170-saved-diagnosis-condition-summary-ios-codex-20261116-32`.
Следующий шаг: следующая независимая задача manifest; ошибки публикации смотреть в state.json.
