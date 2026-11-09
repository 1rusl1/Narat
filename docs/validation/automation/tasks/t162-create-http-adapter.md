# t162-create-http-adapter

Узкий фундамент T019/T044/T162: production plant.create каталога поверх принятого sync/auth; настоящий SQL RPC, cap mapping/retry и HTTP fixtures. Без UI/guest/live.

Подготовлен production RPC-адаптер catalogue plant.create, HTTP fixtures и контракт. Patch готов к проверкам контроллера.

Изменённые файлы: specs/001-plants-ios-mvp/contracts/collection-http.md, supabase/functions/_shared/http.ts, supabase/functions/_shared/tests/collection_http_test.ts, supabase/functions/plants-api/collection.ts, supabase/functions/plants-api/index.ts.

Проверки:

- deno-check: PASS, local, exit 0; log `/Users/ruslansabirov/Documents/ChatGPT/Plants/docs/validation/automation/runs/orchestrator-t162-adapters-20261109-01/t162-create-http-adapter/check-1-deno-check/stdout.log`
- diff-check: PASS, local, exit 0; log `/Users/ruslansabirov/Documents/ChatGPT/Plants/docs/validation/automation/runs/orchestrator-t162-adapters-20261109-01/t162-create-http-adapter/check-2-diff-check/stdout.log`
- deno-tests: PASS, fixture, exit 0; log `/Users/ruslansabirov/Documents/ChatGPT/Plants/docs/validation/automation/runs/orchestrator-t162-adapters-20261109-01/t162-create-http-adapter/check-3-deno-tests/stdout.log`
- ios-tests: PASS, local, exit 0; log `/Users/ruslansabirov/Documents/ChatGPT/Plants/docs/validation/automation/runs/orchestrator-t162-adapters-20261109-01/t162-create-http-adapter/check-4-ios-tests/stdout.log`
- t161-collection-cap: PASS, fixture, exit 0; log `/Users/ruslansabirov/Documents/ChatGPT/Plants/docs/validation/automation/runs/orchestrator-t162-adapters-20261109-01/t162-create-http-adapter/check-5-t161-collection-cap/stdout.log`
- t162-collection-http: PASS, fixture, exit 0; log `/Users/ruslansabirov/Documents/ChatGPT/Plants/docs/validation/automation/runs/orchestrator-t162-adapters-20261109-01/t162-create-http-adapter/check-6-t162-collection-http/stdout.log`
- simulator-smoke: PASS, local, exit 0; log `/Users/ruslansabirov/Documents/ChatGPT/Plants/docs/validation/automation/runs/orchestrator-t162-adapters-20261109-01/t162-create-http-adapter/check-7-simulator-smoke/stdout.log`

Review и QA подтвердили критерии manifest; это не автоматическое закрытие полной продуктовой задачи.

Решения: ["Проверки не запускались: обязательные команды выполняет контроллер после применения patch.", "Существующие auth/profile resolver, sync implementation и безопасный bare handler сохранены; production factory расширена command handler.", "SQL отвечает за cap, hash, receipt и retry; HTTP возвращает проверенный SQL result без синтетических полей.", "Ненулевой photo_id отклоняется до RPC: текущий SQL не проверяет owner main_photo_id при INSERT; каталог без фото поддержан.", "Fixtures не подтверждают live/guest/UI/client acceptance; адаптация Swift DTO/outbox и полные T019/T044/T149/T162 остаются открытыми.", "Файлы, миграции, handoff/tasks и Git не изменялись; представлен только unified diff разрешённых файлов."].

Ограничения: подтверждены только явно указанные режимы и критерии. State/metrics: `/Users/ruslansabirov/Documents/ChatGPT/Plants/docs/validation/automation/runs/orchestrator-t162-adapters-20261109-01`.
Следующий шаг: следующая независимая задача manifest; ошибки публикации смотреть в state.json.
