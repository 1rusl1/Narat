# t157-manual-evidence-cleanup

Следующий независимый по файлам срез T157: убрать обязательные три источника и обязательный LLM synthesis workflow из обеих profile schema. Сохранить происхождение/права/применимость. Это минимальная часть перехода к ручной подготовке, не полный новый формат карточки.

Подготовлен минимальный патч двух схем и AJV2020-регрессий для ручной проверки и исторического multi-source.

Изменённые файлы: specs/001-plants-ios-mvp/contracts/condition-profile.schema.json, specs/001-plants-ios-mvp/contracts/plant-profile.schema.json, supabase/functions/_shared/tests/profile_evidence_test.ts.

Проверки:

- deno-check: PASS, local, exit 0; log `/Users/ruslansabirov/Documents/ChatGPT/Plants/docs/validation/automation/runs/orchestrator-t157-rules-20261109-01/t157-manual-evidence-cleanup/check-1-deno-check/stdout.log`
- diff-check: PASS, local, exit 0; log `/Users/ruslansabirov/Documents/ChatGPT/Plants/docs/validation/automation/runs/orchestrator-t157-rules-20261109-01/t157-manual-evidence-cleanup/check-2-diff-check/stdout.log`
- t157-manual-evidence: PASS, local, exit 0; log `/Users/ruslansabirov/Documents/ChatGPT/Plants/docs/validation/automation/runs/orchestrator-t157-rules-20261109-01/t157-manual-evidence-cleanup/check-3-t157-manual-evidence/stdout.log`
- automation-tests: PASS, fixture, exit 0; log `/Users/ruslansabirov/Documents/ChatGPT/Plants/docs/validation/automation/runs/orchestrator-t157-rules-20261109-01/t157-manual-evidence-cleanup/check-4-automation-tests/stdout.log`
- deno-tests: PASS, fixture, exit 0; log `/Users/ruslansabirov/Documents/ChatGPT/Plants/docs/validation/automation/runs/orchestrator-t157-rules-20261109-01/t157-manual-evidence-cleanup/check-5-deno-tests/stdout.log`

Review и QA подтвердили критерии manifest; это не автоматическое закрытие полной продуктовой задачи.

Решения: ["Файлы и Git не изменялись; патч применяет контроллер.", "Изменения схем ограничены согласованными требованиями к количеству источников, разрешениям и необязательным metadata.", "Фикстуры полностью синтетические; schema-valid запись не подтверждает проверку рекомендаций или права на автоматическую обработку/LLM.", "Обязательные semantic hash, static/build/unit проверки запускает контроллер после применения патча; здесь они не запускались.", "T157, T148 и выпуск KB этим срезом не закрываются."].

Ограничения: подтверждены только явно указанные режимы и критерии. State/metrics: `/Users/ruslansabirov/Documents/ChatGPT/Plants/docs/validation/automation/runs/orchestrator-t157-rules-20261109-01`.
Следующий шаг: следующая независимая задача manifest; ошибки публикации смотреть в state.json.
