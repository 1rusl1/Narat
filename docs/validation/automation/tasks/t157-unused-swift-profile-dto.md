# t157-unused-swift-profile-dto

После принятых Condition/Plant2 удалить три неиспользуемые Swift DTO, которые ещё описывают полный профиль/лечебные фазы/сравнение. Никакой загрузки private Golden Records на клиент вместо них не добавлять; сохраняется существующая проекция результата и сырая история.

Подготовлен патч удаления трёх неиспользуемых DTO и устаревшего MARK.

Изменённые файлы: ios/Plants/Data/Remote/APIModels.swift.

Проверки:

- diff-check: PASS, local, exit 0; log `/Users/ruslansabirov/Documents/ChatGPT/Plants/docs/validation/automation/runs/orchestrator-t157-swift-profiles-20261109-01/t157-unused-swift-profile-dto/check-1-diff-check/stdout.log`
- t157-swift-profile-dto: PASS, local, exit 0; log `/Users/ruslansabirov/Documents/ChatGPT/Plants/docs/validation/automation/runs/orchestrator-t157-swift-profiles-20261109-01/t157-unused-swift-profile-dto/check-2-t157-swift-profile-dto/stdout.log`
- automation-tests: PASS, fixture, exit 0; log `/Users/ruslansabirov/Documents/ChatGPT/Plants/docs/validation/automation/runs/orchestrator-t157-swift-profiles-20261109-01/t157-unused-swift-profile-dto/check-3-automation-tests/stdout.log`
- ios-tests: PASS, local, exit 0; log `/Users/ruslansabirov/Documents/ChatGPT/Plants/docs/validation/automation/runs/orchestrator-t157-swift-profiles-20261109-01/t157-unused-swift-profile-dto/check-4-ios-tests/stdout.log`
- simulator-smoke: PASS, local, exit 0; log `/Users/ruslansabirov/Documents/ChatGPT/Plants/docs/validation/automation/runs/orchestrator-t157-swift-profiles-20261109-01/t157-unused-swift-profile-dto/check-5-simulator-smoke/stdout.log`

Review и QA подтвердили критерии manifest; это не автоматическое закрытие полной продуктовой задачи.

Решения: ["Прочитаны AGENTS.md, конституция и контракт compact-profiles.md.", "Поиск по ios подтвердил отсутствие потребителей вне удаляемых определений.", "Остальные DTO, поля и сериализация сохранены; история, outbox и локальные данные не изменяются.", "Файлы не изменялись. Обязательные проверки выполнит контроллер после применения патча."].

Ограничения: подтверждены только явно указанные режимы и критерии. State/metrics: `/Users/ruslansabirov/Documents/ChatGPT/Plants/docs/validation/automation/runs/orchestrator-t157-swift-profiles-20261109-01`.
Следующий шаг: следующая независимая задача manifest; ошибки публикации смотреть в state.json.
