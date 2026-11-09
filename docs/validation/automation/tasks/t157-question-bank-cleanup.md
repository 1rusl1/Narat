# t157-question-bank-cleanup

Первый ограниченный срез T157/OLD-01: удалить отменённый банк вопросов после анализа из ConditionProfile JSON Schema, TypeScript профиля/semantic validator и тестовых данных. Это не вся T157 и не приёмка живой диагностики. Код и схема ещё старые: другие отменённые механизмы удаляются следующими согласованными срезами.

Подготовлен патч удаления банка вопросов из схемы, TypeScript и fixtures с регрессионными тестами.

Изменённые файлы: specs/001-plants-ios-mvp/contracts/condition-profile.schema.json, supabase/functions/_shared/KnowledgeTypes.ts, supabase/functions/_shared/tests/analysis_result_test.ts.

Проверки:

- deno-check: PASS, local, exit 0; log `/Users/ruslansabirov/Documents/ChatGPT/Plants/docs/validation/automation/runs/orchestrator-t157-questions-20261109-01/t157-question-bank-cleanup/check-1-deno-check/stdout.log`
- diff-check: PASS, local, exit 0; log `/Users/ruslansabirov/Documents/ChatGPT/Plants/docs/validation/automation/runs/orchestrator-t157-questions-20261109-01/t157-question-bank-cleanup/check-2-diff-check/stdout.log`
- t157-question-contract: PASS, local, exit 0; log `/Users/ruslansabirov/Documents/ChatGPT/Plants/docs/validation/automation/runs/orchestrator-t157-questions-20261109-01/t157-question-bank-cleanup/check-3-t157-question-contract/stdout.log`
- automation-tests: PASS, fixture, exit 0; log `/Users/ruslansabirov/Documents/ChatGPT/Plants/docs/validation/automation/runs/orchestrator-t157-questions-20261109-01/t157-question-bank-cleanup/check-4-automation-tests/stdout.log`
- deno-tests: PASS, fixture, exit 0; log `/Users/ruslansabirov/Documents/ChatGPT/Plants/docs/validation/automation/runs/orchestrator-t157-questions-20261109-01/t157-question-bank-cleanup/check-5-deno-tests/stdout.log`

Review и QA подтвердили критерии manifest; это не автоматическое закрытие полной продуктовой задачи.

Решения: ["Файлы не изменялись; патч применяется контроллером.", "Обязательные проверки не запускались: их выполняет контроллер после применения патча.", "Схема сохраняет версию 1.0 и остальные ограничения; историческое поле игнорируется semantic validator.", "Тесты охватывают fixtures, EN/PL, resolved/pending и прежние отрицательные ограничения. Живая диагностика и вся T157 этим срезом не принимаются."].

Ограничения: подтверждены только явно указанные режимы и критерии. State/metrics: `/Users/ruslansabirov/Documents/ChatGPT/Plants/docs/validation/automation/runs/orchestrator-t157-questions-20261109-01`.
Следующий шаг: следующая независимая задача manifest; ошибки публикации смотреть в state.json.
