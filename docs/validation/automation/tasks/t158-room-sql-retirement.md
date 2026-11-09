# t158-room-sql-retirement

Независимая read-only приёмка полного room-only SQL кандидата после Developer CLI timeout, не только пустого diff. Управляющий процесс материализовал точный expected SQL и реальные seed/66 pgTAP; PostgreSQL clean/upgrade/race PASS, но Review/QA ещё обязательны. Узкий T158: остановить новые room CRUD/link/creation и исключить rooms/room_id из sync без удаления истории. Не менять Free/квоты/expiry и не объявлять старый несовместимый guest claim рабочим.

Read-only task: controller runs checks before independent Review/QA.

Изменённые файлы: нет.

Проверки:

- deno-check: PASS, local, exit 0; log `/Users/ruslansabirov/Documents/ChatGPT/Plants/docs/validation/automation/runs/orchestrator-t158-rooms-20261109-02/t158-room-sql-retirement/check-1-deno-check/stdout.log`
- diff-check: PASS, local, exit 0; log `/Users/ruslansabirov/Documents/ChatGPT/Plants/docs/validation/automation/runs/orchestrator-t158-rooms-20261109-02/t158-room-sql-retirement/check-2-diff-check/stdout.log`
- automation-tests: PASS, fixture, exit 0; log `/Users/ruslansabirov/Documents/ChatGPT/Plants/docs/validation/automation/runs/orchestrator-t158-rooms-20261109-02/t158-room-sql-retirement/check-3-automation-tests/stdout.log`
- deno-tests: PASS, fixture, exit 0; log `/Users/ruslansabirov/Documents/ChatGPT/Plants/docs/validation/automation/runs/orchestrator-t158-rooms-20261109-02/t158-room-sql-retirement/check-4-deno-tests/stdout.log`
- t158-rooms-upgrade: PASS, fixture, exit 0; log `/Users/ruslansabirov/Documents/ChatGPT/Plants/docs/validation/automation/runs/orchestrator-t158-rooms-20261109-02/t158-room-sql-retirement/check-5-t158-rooms-upgrade/stdout.log`

Review и QA подтвердили критерии manifest; это не автоматическое закрытие полной продуктовой задачи.

Решения: ["No Developer call needed: no files may be changed."].

Ограничения: подтверждены только явно указанные режимы и критерии. State/metrics: `/Users/ruslansabirov/Documents/ChatGPT/Plants/docs/validation/automation/runs/orchestrator-t158-rooms-20261109-02`.
Следующий шаг: следующая независимая задача manifest; ошибки публикации смотреть в state.json.
