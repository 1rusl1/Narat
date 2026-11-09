# t157-followup-cleanup

Следующий последовательный срез T157: убрать отдельный новый AI follow_up/comparison из schema, backend API/access/worker/provider и iOS активного выбора/квот. Новое фото того же растения использует diagnosis. Сохраняются прежние результаты/подписи и ручные/контрольные фото; не путать с полностью отдельной очисткой расписания T160. Предыдущий question-bank срез принят f15e6c6.

Подготовлен единый патч удаления нового follow_up/comparison с сохранением исторического чтения и регрессиями Deno/Swift.

Изменённые файлы: ios/Plants/Data/Repositories/AnalysisAccessRepository.swift, ios/Plants/Domain/PlantTypes.swift, ios/PlantsTests/FirstHelpUnitTests.swift, ios/PlantsTests/SyncPersistenceTests.swift, specs/001-plants-ios-mvp/contracts/ai-result.schema.json, supabase/functions/_shared/AnalysisAccess.ts, supabase/functions/_shared/AnalysisValidator.ts, supabase/functions/_shared/AnthropicAdapter.ts, supabase/functions/_shared/KnowledgeTypes.ts, supabase/functions/_shared/ProtocolResolver.ts, supabase/functions/_shared/ProviderBudgetGuard.ts, supabase/functions/_shared/tests/analysis_result_test.ts, supabase/functions/_shared/tests/runtime_compatibility_test.ts, supabase/functions/analysis-worker/index.ts, supabase/functions/plants-api/analysis.ts.

Проверки:

- deno-check: PASS, local, exit 0; log `/Users/ruslansabirov/Documents/ChatGPT/Plants/docs/validation/automation/runs/orchestrator-t157-followup-20261109-01/t157-followup-cleanup/check-1-deno-check/stdout.log`
- diff-check: PASS, local, exit 0; log `/Users/ruslansabirov/Documents/ChatGPT/Plants/docs/validation/automation/runs/orchestrator-t157-followup-20261109-01/t157-followup-cleanup/check-2-diff-check/stdout.log`
- t157-followup-contract: PASS, local, exit 0; log `/Users/ruslansabirov/Documents/ChatGPT/Plants/docs/validation/automation/runs/orchestrator-t157-followup-20261109-01/t157-followup-cleanup/check-3-t157-followup-contract/stdout.log`
- automation-tests: PASS, fixture, exit 0; log `/Users/ruslansabirov/Documents/ChatGPT/Plants/docs/validation/automation/runs/orchestrator-t157-followup-20261109-01/t157-followup-cleanup/check-4-automation-tests/stdout.log`
- deno-tests: PASS, fixture, exit 0; log `/Users/ruslansabirov/Documents/ChatGPT/Plants/docs/validation/automation/runs/orchestrator-t157-followup-20261109-01/t157-followup-cleanup/check-5-deno-tests/stdout.log`
- ios-tests: PASS, local, exit 0; log `/Users/ruslansabirov/Documents/ChatGPT/Plants/docs/validation/automation/runs/orchestrator-t157-followup-20261109-01/t157-followup-cleanup/check-6-ios-tests/stdout.log`
- simulator-smoke: PASS, local, exit 0; log `/Users/ruslansabirov/Documents/ChatGPT/Plants/docs/validation/automation/runs/orchestrator-t157-followup-20261109-01/t157-followup-cleanup/check-7-simulator-smoke/stdout.log`

Review и QA подтвердили критерии manifest; это не автоматическое закрытие полной продуктовой задачи.

Решения: ["PASS означает готовность патча к проверкам контроллера. Обязательные static/build/unit/smoke проверки здесь не запускались.", "Сохранены schema_version 3.0, исторические режимы и подписи; legacy worker завершает задание через finalizeJobOnce до provider/budget.", "Ручные и контрольные фото, recovery-check descriptors, лимиты и expiry сохранены. SQL/forward migration и T160 остаются отдельной работой.", "Workspace, Git, tasks и handoff не изменялись; live provider/DB не использовались."].

Ограничения: подтверждены только явно указанные режимы и критерии. State/metrics: `/Users/ruslansabirov/Documents/ChatGPT/Plants/docs/validation/automation/runs/orchestrator-t157-followup-20261109-01`.
Следующий шаг: следующая независимая задача manifest; ошибки публикации смотреть в state.json.
