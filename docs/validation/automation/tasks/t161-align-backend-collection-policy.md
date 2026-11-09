# t161-align-backend-collection-policy

T161 третий срез: TS DTO/entitlement/basic-care HTTP больше не выбирают Free-места; align authoritative SQL, behavioral tests and API/sync addendum.

Подготовлен патч: DTO и entitlement без Free-мест, исторический replay через SQL, HTTP fixtures и API/sync addendum.

Изменённые файлы: specs/001-plants-ios-mvp/contracts/collection-cap.md, supabase/functions/_shared/BasicCareService.ts, supabase/functions/_shared/EntitlementGate.ts, supabase/functions/_shared/tests/claim_transfer_test.ts, supabase/functions/_shared/tests/foundational_services_test.ts, supabase/functions/plants-api/basic-care.ts.

Проверки:

- deno-check: PASS, local, exit 0; log `/Users/ruslansabirov/Documents/ChatGPT/Plants/docs/validation/automation/runs/orchestrator-t161-collection-20261109-02/t161-align-backend-collection-policy/check-1-deno-check/stdout.log`
- diff-check: PASS, local, exit 0; log `/Users/ruslansabirov/Documents/ChatGPT/Plants/docs/validation/automation/runs/orchestrator-t161-collection-20261109-02/t161-align-backend-collection-policy/check-2-diff-check/stdout.log`
- deno-tests: PASS, fixture, exit 0; log `/Users/ruslansabirov/Documents/ChatGPT/Plants/docs/validation/automation/runs/orchestrator-t161-collection-20261109-02/t161-align-backend-collection-policy/check-3-deno-tests/stdout.log`
- t161-slots-retired: PASS, fixture, exit 0; log `/Users/ruslansabirov/Documents/ChatGPT/Plants/docs/validation/automation/runs/orchestrator-t161-collection-20261109-02/t161-align-backend-collection-policy/check-4-t161-slots-retired/stdout.log`

Review и QA подтвердили критерии manifest; это не автоматическое закрытие полной продуктовой задачи.

Решения: ["Файлы не изменялись; патч подготовлен в памяти только для разрешённых путей.", "Миграции и данные сохранены. Legacy adapter повторяет прежнюю truthy-проекцию payload; receipt lookup и hash остаются authoritative SQL.", "Проверки не запускались: обязательные Deno/SQL/typecheck/diff проверки выполняет контроллер после применения.", "HTTP module не подключён к production router; fixtures не подтверждают live интеграцию или положительный guest claim. T162/T164 и T155/T158 остаются открытыми."].

Ограничения: подтверждены только явно указанные режимы и критерии. State/metrics: `/Users/ruslansabirov/Documents/ChatGPT/Plants/docs/validation/automation/runs/orchestrator-t161-collection-20261109-02`.
Следующий шаг: следующая независимая задача manifest; ошибки публикации смотреть в state.json.
