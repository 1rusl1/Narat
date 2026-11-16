# t019-native-auth-ordinary-account

Wire native Apple and configured Google sign-in into the ordinary account sheet with verified owner scope.

Подготовлен патч нативного входа в обычной форме с проверкой owner scope, общей сериализацией и fixture-покрытием.

Изменённые файлы: ios/Plants/App/PlantsApp.swift, ios/Plants/Features/Catalogue/CatalogueSaveView.swift, ios/Plants/Features/Catalogue/GuestCatalogueView.swift, ios/Plants/Integrations/Auth/NativeAuthConfiguration.swift, ios/Plants/Integrations/Auth/NativeIdentityProvider.swift, ios/PlantsTests/CatalogueConnectionTests.swift.

Вызовы — developer 1, reviewer 1, qa 1. Модели — 769.48 с, проверки — 112.76 с. Повторы моделей — 0, тайм-ауты моделей — 0, тайм-ауты проверок — 0.

Проверки:

- diff-check — PASS (local, exit 0, 0.04 с). Лог `/private/tmp/narat-ios-initial-context-20261116/docs/validation/automation/runs/orchestrator-t019-native-auth-ordinary-account-codex-20261116-20/t019-native-auth-ordinary-account/check-1-diff-check/stdout.log`.
- ios-tests — PASS (local, exit 0, 94.71 с). Лог `/private/tmp/narat-ios-initial-context-20261116/docs/validation/automation/runs/orchestrator-t019-native-auth-ordinary-account-codex-20261116-20/t019-native-auth-ordinary-account/check-2-ios-tests/stdout.log`.
- simulator-smoke — PASS (local, exit 0, 18.01 с). Лог `/private/tmp/narat-ios-initial-context-20261116/docs/validation/automation/runs/orchestrator-t019-native-auth-ordinary-account-codex-20261116-20/t019-native-auth-ordinary-account/check-3-simulator-smoke/stdout.log`.

Review и QA подтвердили критерии manifest; это не автоматическое закрытие полной продуктовой задачи.

Решения: ["Повторно использованы NativeAuthService, SDK, presenter bridge и snapshot/epoch binding. Google доступен при валидном client ID и зарегистрированной callback-схеме.", "Добавлены fixtures отмены, смены scope/ABA, успешного входа, сериализации с email/каталогом и сохранности идентификаторов гостевого переноса.", "Проверки diff-check, ios-tests и ordinary home smoke выполняет контроллер после применения патча.", "Реальные Apple/Google, revocation и физический iPhone остаются открытыми. Напоминания остаются на паузе."].

Ограничения: подтверждены только явно указанные режимы и критерии. State/metrics: `/private/tmp/narat-ios-initial-context-20261116/docs/validation/automation/runs/orchestrator-t019-native-auth-ordinary-account-codex-20261116-20`.
Следующий шаг: следующая независимая задача manifest; ошибки публикации смотреть в state.json.
