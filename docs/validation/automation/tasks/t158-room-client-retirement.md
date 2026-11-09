# t158-room-client-retirement

Согласовать TS/Swift claim overrides без room fields после SQL retirement; проверить чтение старого JSON и явный отказ HTTP до RPC. Сохранить историю/outbox и известные ограничения claim.

Patch пересобран относительно текущих файлов: удалены room writer fields, добавлены HTTP guard и Deno/Swift regression-тесты. Готов к проверкам контроллера.

Изменённые файлы: ios/Plants/Data/Remote/APIModels.swift, ios/PlantsTests/SyncPersistenceTests.swift, supabase/functions/_shared/tests/claim_transfer_test.ts, supabase/functions/plants-api/claims.ts.

Проверки:

- deno-check: PASS, local, exit 0; log `/Users/ruslansabirov/Documents/ChatGPT/Plants/docs/validation/automation/runs/orchestrator-t158-rooms-20261109-02/t158-room-client-retirement/check-1-deno-check/stdout.log`
- diff-check: PASS, local, exit 0; log `/Users/ruslansabirov/Documents/ChatGPT/Plants/docs/validation/automation/runs/orchestrator-t158-rooms-20261109-02/t158-room-client-retirement/check-2-diff-check/stdout.log`
- deno-tests: PASS, fixture, exit 0; log `/Users/ruslansabirov/Documents/ChatGPT/Plants/docs/validation/automation/runs/orchestrator-t158-rooms-20261109-02/t158-room-client-retirement/check-3-deno-tests/stdout.log`
- ios-tests: PASS, local, exit 0; log `/Users/ruslansabirov/Documents/ChatGPT/Plants/docs/validation/automation/runs/orchestrator-t158-rooms-20261109-02/t158-room-client-retirement/check-4-ios-tests/stdout.log`
- simulator-smoke: PASS, local, exit 0; log `/Users/ruslansabirov/Documents/ChatGPT/Plants/docs/validation/automation/runs/orchestrator-t158-rooms-20261109-02/t158-room-client-retirement/check-5-simulator-smoke/stdout.log`

Review и QA подтвердили критерии manifest; это не автоматическое закрытие полной продуктовой задачи.

Решения: ["Файлы, Git, handoff/tasks не изменялись; обязательные проверки запускает контроллер.", "Deno fixtures покрывают каждый retired key со строкой и null, отсутствие RPC и мутаций; допустимые overrides сохраняют прежние RPC-параметры.", "Swift regression читает исторический JSON из SwiftData, проверяет все оставшиеся поля и повторное сохранение без room keys.", "Исторические sync/outbox, receipt/signature и Free slots tests сохранены.", "Несовместимость guest RPC и ограничения proof/TTL/context остаются T159; fixtures не подтверждают живой перенос."].

Ограничения: подтверждены только явно указанные режимы и критерии. State/metrics: `/Users/ruslansabirov/Documents/ChatGPT/Plants/docs/validation/automation/runs/orchestrator-t158-rooms-20261109-02`.
Следующий шаг: следующая независимая задача manifest; ошибки публикации смотреть в state.json.
