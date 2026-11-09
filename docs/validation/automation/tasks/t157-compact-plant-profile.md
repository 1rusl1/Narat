# t157-compact-plant-profile

Зависимый срез: минимальный PlantProfile2 для одного независимого действия или safety факта без полного care_algorithm_params/taxonomy/рецепта. История и отдельный каталог сохраняются.

Подготовлен compact PlantProfile2 и AJV-тесты обоих v2 форматов, включая safety-only и сохранность v1.

Изменённые файлы: specs/001-plants-ios-mvp/contracts/plant-profile.schema.json, supabase/functions/_shared/tests/profile_evidence_test.ts.

Проверки:

- deno-check: PASS, local, exit 0; log `/Users/ruslansabirov/Documents/ChatGPT/Plants/docs/validation/automation/runs/orchestrator-t157-compact-20261109-02/t157-compact-plant-profile/check-1-deno-check/stdout.log`
- diff-check: PASS, local, exit 0; log `/Users/ruslansabirov/Documents/ChatGPT/Plants/docs/validation/automation/runs/orchestrator-t157-compact-20261109-02/t157-compact-plant-profile/check-2-diff-check/stdout.log`
- t157-compact-condition: PASS, local, exit 0; log `/Users/ruslansabirov/Documents/ChatGPT/Plants/docs/validation/automation/runs/orchestrator-t157-compact-20261109-02/t157-compact-plant-profile/check-3-t157-compact-condition/stdout.log`
- t157-compact-plant: PASS, local, exit 0; log `/Users/ruslansabirov/Documents/ChatGPT/Plants/docs/validation/automation/runs/orchestrator-t157-compact-20261109-02/t157-compact-plant-profile/check-4-t157-compact-plant/stdout.log`
- automation-tests: PASS, fixture, exit 0; log `/Users/ruslansabirov/Documents/ChatGPT/Plants/docs/validation/automation/runs/orchestrator-t157-compact-20261109-02/t157-compact-plant-profile/check-5-automation-tests/stdout.log`
- deno-tests: PASS, fixture, exit 0; log `/Users/ruslansabirov/Documents/ChatGPT/Plants/docs/validation/automation/runs/orchestrator-t157-compact-20261109-02/t157-compact-plant-profile/check-6-deno-tests/stdout.log`

Review и QA подтвердили критерии manifest; это не автоматическое закрытие полной продуктовой задачи.

Решения: ["Схема сформирована по expected_plant(); общий action соответствует Condition2, legacy-схемы не изменяются.", "Сохранён исходный synthetic v1 builder для проверки чтения исторического снимка и отказа его публикации как v2 без мутации.", "Все прежние provenance negative cases сохранены и дополнительно применены к safety-only.", "Проверки care readiness ограничены контрактом: safety-only сохраняет пустой actions; runtime не изменяется.", "Обязательные проверки выполняет контроллер после применения patch; здесь они не запускались.", "Fixtures синтетические; агрономическая достоверность и живые интеграции не заявляются. Файлы, handoff/tasks и Git не изменялись."].

Ограничения: подтверждены только явно указанные режимы и критерии. State/metrics: `/Users/ruslansabirov/Documents/ChatGPT/Plants/docs/validation/automation/runs/orchestrator-t157-compact-20261109-02`.
Следующий шаг: следующая независимая задача manifest; ошибки публикации смотреть в state.json.
