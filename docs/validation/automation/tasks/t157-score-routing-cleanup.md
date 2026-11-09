# t157-score-routing-cleanup

Последовательно после принятого follow_up-среза a97ff20 убрать старую маршрутизацию по confidence/gap и decision/question DTO, сохраняя явную неопределённость, подтверждённые действия из KB и чтение исторических receipts. Это часть T157, не вся T155.

Подготовлен патч удаления score-routing и question/decision DTO с сохранением подписей и исторического контекста.

Изменённые файлы: ios/Plants/Data/Remote/APIModels.swift, ios/PlantsTests/SyncPersistenceTests.swift, supabase/functions/_shared/ProtocolResolver.ts, supabase/functions/_shared/tests/analysis_result_test.ts.

Проверки:

- deno-check: PASS, local, exit 0; log `/Users/ruslansabirov/Documents/ChatGPT/Plants/docs/validation/automation/runs/orchestrator-t157-rules-20261109-01/t157-score-routing-cleanup/check-1-deno-check/stdout.log`
- diff-check: PASS, local, exit 0; log `/Users/ruslansabirov/Documents/ChatGPT/Plants/docs/validation/automation/runs/orchestrator-t157-rules-20261109-01/t157-score-routing-cleanup/check-2-diff-check/stdout.log`
- t157-no-score-routing: PASS, local, exit 0; log `/Users/ruslansabirov/Documents/ChatGPT/Plants/docs/validation/automation/runs/orchestrator-t157-rules-20261109-01/t157-score-routing-cleanup/check-3-t157-no-score-routing/stdout.log`
- automation-tests: PASS, fixture, exit 0; log `/Users/ruslansabirov/Documents/ChatGPT/Plants/docs/validation/automation/runs/orchestrator-t157-rules-20261109-01/t157-score-routing-cleanup/check-4-automation-tests/stdout.log`
- deno-tests: PASS, fixture, exit 0; log `/Users/ruslansabirov/Documents/ChatGPT/Plants/docs/validation/automation/runs/orchestrator-t157-rules-20261109-01/t157-score-routing-cleanup/check-5-deno-tests/stdout.log`
- ios-tests: PASS, local, exit 0; log `/Users/ruslansabirov/Documents/ChatGPT/Plants/docs/validation/automation/runs/orchestrator-t157-rules-20261109-01/t157-score-routing-cleanup/check-6-ios-tests/stdout.log`
- simulator-smoke: PASS, local, exit 0; log `/Users/ruslansabirov/Documents/ChatGPT/Plants/docs/validation/automation/runs/orchestrator-t157-rules-20261109-01/t157-score-routing-cleanup/check-7-simulator-smoke/stdout.log`

Review и QA подтвердили критерии manifest; это не автоматическое закрытие полной продуктовой задачи.

Решения: ["Файлы не изменены; обязательные static/build/unit/smoke проверки запускает контроллер.", "Только единственный кандидат problem_detected с опубликованной совместимой первой помощью получает действие; неоднозначность сохраняется независимо от scores и лишнего runtime decisionState.", "Без применимой опубликованной помощи действие и срок отсутствуют; EN/PL limitations объясняют причину. Новый fallback не добавляется.", "Подпись и verify не изменены, новые receipts используют decision_revision=1. Добавлены fixture-регрессии Deno и Swift с повторным открытием дискового LocalStore; live-вызовов не было."].

Ограничения: подтверждены только явно указанные режимы и критерии. State/metrics: `/Users/ruslansabirov/Documents/ChatGPT/Plants/docs/validation/automation/runs/orchestrator-t157-rules-20261109-01`.
Следующий шаг: следующая независимая задача manifest; ошибки публикации смотреть в state.json.
