# t168-retire-unused-client-light-estimator

Ограниченный T168 клиентский срез: удалить неиспользуемые camera-estimate writer/protocol и оставить новый выбор света только ручным; старый cache/происхождение сохраняются. Это не полная T168 server/API приёмка.

Подготовлен патч удаления неиспользуемого оценщика света, ручного выбора и регрессионного теста сохранности исторических данных.

Изменённые файлы: ios/Plants/Domain/PlantTypes.swift, ios/Plants/Features/Analysis/AnalysisFlowModel.swift, ios/Plants/Features/Analysis/CareQuestionsView.swift, ios/PlantsTests/FirstHelpUnitTests.swift.

Проверки:

- diff-check: PASS, local, exit 0; log `/Users/ruslansabirov/Documents/ChatGPT/Plants/docs/validation/automation/runs/orchestrator-t168-client-light-20261109-01/t168-retire-unused-client-light-estimator/check-1-diff-check/stdout.log`
- t168-client-light-writer: PASS, local, exit 0; log `/Users/ruslansabirov/Documents/ChatGPT/Plants/docs/validation/automation/runs/orchestrator-t168-client-light-20261109-01/t168-retire-unused-client-light-estimator/check-2-t168-client-light-writer/stdout.log`
- automation-tests: PASS, fixture, exit 0; log `/Users/ruslansabirov/Documents/ChatGPT/Plants/docs/validation/automation/runs/orchestrator-t168-client-light-20261109-01/t168-retire-unused-client-light-estimator/check-3-automation-tests/stdout.log`
- ios-tests: PASS, local, exit 0; log `/Users/ruslansabirov/Documents/ChatGPT/Plants/docs/validation/automation/runs/orchestrator-t168-client-light-20261109-01/t168-retire-unused-client-light-estimator/check-4-ios-tests/stdout.log`
- simulator-smoke: PASS, local, exit 0; log `/Users/ruslansabirov/Documents/ChatGPT/Plants/docs/validation/automation/runs/orchestrator-t168-client-light-20261109-01/t168-retire-unused-client-light-estimator/check-5-simulator-smoke/stdout.log`

Review и QA подтвердили критерии manifest; это не автоматическое закрытие полной продуктовой задачи.

Решения: ["Прочитаны применимые конституция и разделы спецификации. Файлы, Git, handoff и tasks не изменялись.", "LightSource.cameraEstimate и существующие SyncPersistenceTests сохранены без изменений. Новый тест в @MainActor-классе покрывает оба намерения, исторический JSON, все ручные уровни, unknown и сохранение состояния.", "Обязательные проверки не запускались: их выполняет контроллер после применения патча. PASS означает готовность к этим проверкам.", "T168/T155 остаются открытыми: серверные/API/RPC guards, согласование wire DTO и повторная отправка исторических условий находятся вне этого клиентского среза."].

Ограничения: подтверждены только явно указанные режимы и критерии. State/metrics: `/Users/ruslansabirov/Documents/ChatGPT/Plants/docs/validation/automation/runs/orchestrator-t168-client-light-20261109-01`.
Следующий шаг: следующая независимая задача manifest; ошибки публикации смотреть в state.json.
