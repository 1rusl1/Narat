# t162-sync-http-adapter

Узкий фундамент T019/T162: production GET /sync через fetch_sync_delta. Auth prerequisite 9551807 уже принят. Только sync, без command/create/UI/live.

Подготовлен patch: production GET /sync через Supabase RPC, валидация, безопасные ошибки, HTTP fixtures и контракт.

Изменённые файлы: specs/001-plants-ios-mvp/contracts/collection-http.md, supabase/functions/_shared/tests/collection_http_test.ts, supabase/functions/plants-api/collection.ts, supabase/functions/plants-api/index.ts.

Проверки:

- deno-check: PASS, local, exit 0; log `/Users/ruslansabirov/Documents/ChatGPT/Plants/docs/validation/automation/runs/orchestrator-t162-adapters-20261109-01/t162-sync-http-adapter/check-1-deno-check/stdout.log`
- diff-check: PASS, local, exit 0; log `/Users/ruslansabirov/Documents/ChatGPT/Plants/docs/validation/automation/runs/orchestrator-t162-adapters-20261109-01/t162-sync-http-adapter/check-2-diff-check/stdout.log`
- deno-tests: PASS, fixture, exit 0; log `/Users/ruslansabirov/Documents/ChatGPT/Plants/docs/validation/automation/runs/orchestrator-t162-adapters-20261109-01/t162-sync-http-adapter/check-3-deno-tests/stdout.log`
- ios-tests: PASS, local, exit 0; log `/Users/ruslansabirov/Documents/ChatGPT/Plants/docs/validation/automation/runs/orchestrator-t162-adapters-20261109-01/t162-sync-http-adapter/check-4-ios-tests/stdout.log`
- t162-collection-http: PASS, fixture, exit 0; log `/Users/ruslansabirov/Documents/ChatGPT/Plants/docs/validation/automation/runs/orchestrator-t162-adapters-20261109-01/t162-sync-http-adapter/check-5-t162-collection-http/stdout.log`
- simulator-smoke: PASS, local, exit 0; log `/Users/ruslansabirov/Documents/ChatGPT/Plants/docs/validation/automation/runs/orchestrator-t162-adapters-20261109-01/t162-sync-http-adapter/check-6-simulator-smoke/stdout.log`

Review и QA подтвердили критерии manifest; это не автоматическое закрытие полной продуктовой задачи.

Решения: ["Проверки не запускались: после применения patch их выполняет контроллер.", "Auth/profile 9551807 сохранён; bare handler, command fallback и явные delegates сохраняют поведение.", "Отсутствующие timestamps/cursor передаются как null; limit по умолчанию 200, поскольку SQL NULL отключает ограничение.", "Fixtures не подтверждают live/DB/client sync. Полные T019/T162, Swift DTO/outbox, command/create и UI остаются открытыми; ограничения отражены в контракте.", "Файлы, handoff/tasks и Git не изменялись."].

Ограничения: подтверждены только явно указанные режимы и критерии. State/metrics: `/Users/ruslansabirov/Documents/ChatGPT/Plants/docs/validation/automation/runs/orchestrator-t162-adapters-20261109-01`.
Следующий шаг: следующая независимая задача manifest; ошибки публикации смотреть в state.json.
