# t161-atomic-collection-cap

T161 первый срез: атомарный Free collection cap 3 на всех writers, paid unlimited. PostgreSQL clean/upgrade, real concurrent retries and distinct operations.

Подготовлены универсальный атомарный cap Free=3 и 35 проверок pgTAP. Paid не ограничен.

Изменённые файлы: supabase/migrations/202611090003_collection_cap.sql, supabase/tests/collection_cap.test.sql.

Проверки:

- deno-check: PASS, local, exit 0; log `/Users/ruslansabirov/Documents/ChatGPT/Plants/docs/validation/automation/runs/orchestrator-t161-collection-20261109-01/t161-atomic-collection-cap/check-1-deno-check/stdout.log`
- diff-check: PASS, local, exit 0; log `/Users/ruslansabirov/Documents/ChatGPT/Plants/docs/validation/automation/runs/orchestrator-t161-collection-20261109-01/t161-atomic-collection-cap/check-2-diff-check/stdout.log`
- automation-tests: PASS, fixture, exit 0; log `/Users/ruslansabirov/Documents/ChatGPT/Plants/docs/validation/automation/runs/orchestrator-t161-collection-20261109-01/t161-atomic-collection-cap/check-3-automation-tests/stdout.log`
- deno-tests: PASS, fixture, exit 0; log `/Users/ruslansabirov/Documents/ChatGPT/Plants/docs/validation/automation/runs/orchestrator-t161-collection-20261109-01/t161-atomic-collection-cap/check-4-deno-tests/stdout.log`
- t161-collection-cap: PASS, fixture, exit 0; log `/Users/ruslansabirov/Documents/ChatGPT/Plants/docs/validation/automation/runs/orchestrator-t161-collection-20261109-01/t161-atomic-collection-cap/check-5-t161-collection-cap/stdout.log`

Review и QA подтвердили критерии manifest; это не автоматическое закрытие полной продуктовой задачи.

Решения: ["Блокировка через UPDATE строки профиля сохраняет watermark и предотвращает обход через устаревший snapshot REPEATABLE READ/SERIALIZABLE.", "Права paid проверяются по серверному времени после блокировки; p_now вызывающего RPC не влияет на cap.", "Проверки переданы контроллеру и здесь не запускались. PASS означает готовность patch к проверкам.", "Положительный guest claim и живые интеграции не заявлены; существующие RPC и applied migrations сохранены.", "Файлы, Git, handoff и tasks не изменялись."].

Ограничения: подтверждены только явно указанные режимы и критерии. State/metrics: `/Users/ruslansabirov/Documents/ChatGPT/Plants/docs/validation/automation/runs/orchestrator-t161-collection-20261109-01`.
Следующий шаг: следующая независимая задача manifest; ошибки публикации смотреть в state.json.
