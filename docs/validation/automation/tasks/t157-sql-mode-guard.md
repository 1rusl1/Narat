# t157-sql-mode-guard

После удаления нового follow_up в API/provider/iOS закрыть старый прямой quota RPC путь: forward migration для admit_analysis_quota с только identification/diagnosis; сохранить legacy table rows/check constraints и расход. Это узкий SQL-срез T157, не пересмотр квот/anchor T158.

Подготовлены точечная forward migration, seed и 50 pgTAP assertions для проверок controller.

Изменённые файлы: supabase/migrations/202611090001_analysis_mode_guard.sql, supabase/tests/analysis_mode_guard.test.sql, supabase/tests/analysis_mode_upgrade.seed.sql.

Проверки:

- deno-check: PASS, local, exit 0; log `/Users/ruslansabirov/Documents/ChatGPT/Plants/docs/validation/automation/runs/orchestrator-t157-sql-mode-20261109-01/t157-sql-mode-guard/check-1-deno-check/stdout.log`
- diff-check: PASS, local, exit 0; log `/Users/ruslansabirov/Documents/ChatGPT/Plants/docs/validation/automation/runs/orchestrator-t157-sql-mode-20261109-01/t157-sql-mode-guard/check-2-diff-check/stdout.log`
- automation-tests: PASS, fixture, exit 0; log `/Users/ruslansabirov/Documents/ChatGPT/Plants/docs/validation/automation/runs/orchestrator-t157-sql-mode-20261109-01/t157-sql-mode-guard/check-3-automation-tests/stdout.log`
- deno-tests: PASS, fixture, exit 0; log `/Users/ruslansabirov/Documents/ChatGPT/Plants/docs/validation/automation/runs/orchestrator-t157-sql-mode-20261109-01/t157-sql-mode-guard/check-4-deno-tests/stdout.log`
- t157-sql-mode-upgrade: PASS, fixture, exit 0; log `/Users/ruslansabirov/Documents/ChatGPT/Plants/docs/validation/automation/runs/orchestrator-t157-sql-mode-20261109-01/t157-sql-mode-guard/check-5-t157-sql-mode-upgrade/stdout.log`

Review и QA подтвердили критерии manifest; это не автоматическое закрытие полной продуктовой задачи.

Решения: ["RPC извлечена программно из исходной миграции; заменён только whitelist guard и удалена obsolete paid-only ветка.", "Файлы, Git, handoff и tasks не изменялись. Обязательные проверки выполнит controller после применения патча.", "Проверки предназначены для fixture PostgreSQL17/pgTAP; live deployment и конкурентность не заявлены. T157/T155 остаются открытыми, правила T158 не пересматривались."].

Ограничения: подтверждены только явно указанные режимы и критерии. State/metrics: `/Users/ruslansabirov/Documents/ChatGPT/Plants/docs/validation/automation/runs/orchestrator-t157-sql-mode-20261109-01`.
Следующий шаг: следующая независимая задача manifest; ошибки публикации смотреть в state.json.
