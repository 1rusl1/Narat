# t152-live-and-disk-safety

Финальный срез T152 после принятых t152-api-persistence-unavailable и t152-ios-unavailable-outbox: закрепить в supabase/config.toml конфигурацию развёрнутого plants-api (verify_jwt = false) и добавить в SyncPersistenceTests проверку сохранности LocalOutbox/sync-кеша/watermark на дисковом SQLite store (inMemory=false) при закрытии и повторном открытии независимых ModelContainer после HTTP 503. Контроллер дополнительно проверяет живой развёрнутый plants-api на стенде narat-staging (ijwnyjdomwvnzmmcurkt) через t152-live-api.

Вызовы асинхронных методов LocalStore в testDiskBackedStoreSurvivesHTTP503AcrossIndependentContainersAndReplaysIdempotently вынесены из синхронных autoclosure XCTAssertEqual/XCTAssertTrue в локальные константы для совместимости со Swift 6 concurrency.

Изменённые файлы: ios/PlantsTests/SyncPersistenceTests.swift, supabase/config.toml.

Проверки:

- diff-check: PASS, local, exit 0; log `/Users/ruslansabirov/Documents/ChatGPT/Plants/docs/validation/automation/runs/orchestrator-t152-live-disk-002/t152-live-and-disk-safety/check-5-diff-check/stdout.log`
- automation-tests: PASS, fixture, exit 0; log `/Users/ruslansabirov/Documents/ChatGPT/Plants/docs/validation/automation/runs/orchestrator-t152-live-disk-002/t152-live-and-disk-safety/check-6-automation-tests/stdout.log`
- deno-tests: PASS, fixture, exit 0; log `/Users/ruslansabirov/Documents/ChatGPT/Plants/docs/validation/automation/runs/orchestrator-t152-live-disk-002/t152-live-and-disk-safety/check-7-deno-tests/stdout.log`
- ios-tests: PASS, local, exit 0; log `/Users/ruslansabirov/Documents/ChatGPT/Plants/docs/validation/automation/runs/orchestrator-t152-live-disk-002/t152-live-and-disk-safety/check-8-ios-tests/stdout.log`
- simulator-smoke: PASS, local, exit 0; log `/Users/ruslansabirov/Documents/ChatGPT/Plants/docs/validation/automation/runs/orchestrator-t152-live-disk-002/t152-live-and-disk-safety/check-9-simulator-smoke/stdout.log`
- t152-live-api: PASS, live, exit 0; log `/Users/ruslansabirov/Documents/ChatGPT/Plants/docs/validation/automation/runs/orchestrator-t152-live-disk-002/t152-live-and-disk-safety/check-10-t152-live-api/stdout.log`

Review и QA подтвердили критерии manifest; это не автоматическое закрытие полной продуктовой задачи.

Решения: ["В Swift 6 autoclosure аргументы XCTAssertEqual/XCTAssertTrue не поддерживают await, поэтому результаты вызовов методов актора LocalStore вынесены в локальные константы перед проверками."].

Ограничения: подтверждены только явно указанные режимы и критерии. State/metrics: `/Users/ruslansabirov/Documents/ChatGPT/Plants/docs/validation/automation/runs/orchestrator-t152-live-disk-002`.
Следующий шаг: следующая независимая задача manifest; ошибки публикации смотреть в state.json.
