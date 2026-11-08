# t152-ios-unavailable-outbox

Второй ограниченный срез T152 после принятого backend: заменить демонстрационную помощь в штатном iOS честной недоступностью анализа; проверить care/scan и problem/scan EN/PL, возврат/каталог и сохранность outbox при HTTP503. Реальное фото/identification — T150; не подключать их в этом срезе.

Подготовлено исправление общей причины падения четырёх UI-case: язык проверяется по локализованному тексту экрана.

Изменённые файлы: ios/Plants/Data/Sync/SyncEngine.swift, ios/Plants/Features/Analysis/AnalysisFlowModel.swift, ios/Plants/Features/Analysis/CareQuestionsView.swift, ios/Plants/Features/Analysis/PreliminaryResultView.swift, ios/Plants/Features/Catalogue/GuestCatalogueView.swift, ios/Plants/Features/Onboarding/AddPlantRouter.swift, ios/PlantsTests/FirstHelpUnitTests.swift, ios/PlantsTests/SyncPersistenceTests.swift, ios/PlantsUITests/FirstHelpTests.swift.

Проверки:

- diff-check: PASS, local, exit 0; log `/Users/ruslansabirov/Documents/ChatGPT/Plants/docs/validation/automation/runs/orchestrator-t152-ios-001/t152-ios-unavailable-outbox/check-6-diff-check/stdout.log`
- automation-tests: PASS, fixture, exit 0; log `/Users/ruslansabirov/Documents/ChatGPT/Plants/docs/validation/automation/runs/orchestrator-t152-ios-001/t152-ios-unavailable-outbox/check-7-automation-tests/stdout.log`
- ios-tests: PASS, local, exit 0; log `/Users/ruslansabirov/Documents/ChatGPT/Plants/docs/validation/automation/runs/orchestrator-t152-ios-001/t152-ios-unavailable-outbox/check-8-ios-tests/stdout.log`
- simulator-smoke: PASS, local, exit 0; log `/Users/ruslansabirov/Documents/ChatGPT/Plants/docs/validation/automation/runs/orchestrator-t152-ios-001/t152-ios-unavailable-outbox/check-9-simulator-smoke/stdout.log`
- t152-ui: PASS, local, exit 0; log `/Users/ruslansabirov/Documents/ChatGPT/Plants/docs/validation/automation/runs/orchestrator-t152-ios-001/t152-ios-unavailable-outbox/check-10-t152-ui/stdout.log`

Review и QA подтвердили критерии manifest; это не автоматическое закрытие полной продуктовой задачи.

Решения: ["В журнале t152-ui все четыре case падают только на проверке choice.value: Simulator возвращает пустую строку вместо «1».", "Проверка заменена ожиданием фактического локализованного welcome.subtitle после явного выбора языка; проверки недоступности, retry, back, каталога и screenshot attachments сохранены.", "Файлы не изменялись, проверки не запускались. Повторный t152-ui и дальнейшие проверки выполняет контроллер; ранее успешные проверки повторно не запускались."].

Ограничения: подтверждены только явно указанные режимы и критерии. State/metrics: `/Users/ruslansabirov/Documents/ChatGPT/Plants/docs/validation/automation/runs/orchestrator-t152-ios-001`.
Следующий шаг: следующая независимая задача manifest; ошибки публикации смотреть в state.json.
