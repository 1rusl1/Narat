# t170-guest-initial-diagnosis-sql

Add service-only install-bound admission and read RPCs for a guest first diagnosis.

Исправлена подготовка KB для гостевой fixture после теста identification с retired-релизом.

Изменённые файлы: supabase/migrations/202611160005_bound_guest_initial_diagnosis.sql, supabase/tests/diagnosis_jobs.test.sql.

Вызовы — developer 3, reviewer 1, qa 1. Модели — 581.20 с, проверки — 71.03 с. Повторы моделей — 2, тайм-ауты моделей — 0, тайм-ауты проверок — 0.

Проверки:

- deno-check — PASS (local, exit 0, 0.13 с). Лог `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-t170-guest-initial-diagnosis-sql-codex-20261116-34/t170-guest-initial-diagnosis-sql/check-9-deno-check/stdout.log`.
- diff-check — PASS (local, exit 0, 0.04 с). Лог `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-t170-guest-initial-diagnosis-sql-codex-20261116-34/t170-guest-initial-diagnosis-sql/check-10-diff-check/stdout.log`.
- deno-tests — PASS (fixture, exit 0, 4.96 с). Лог `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-t170-guest-initial-diagnosis-sql-codex-20261116-34/t170-guest-initial-diagnosis-sql/check-11-deno-tests/stdout.log`.
- parallel-backend-diagnosis-sql — PASS (fixture, exit 0, 44.64 с). Лог `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-t170-guest-initial-diagnosis-sql-codex-20261116-34/t170-guest-initial-diagnosis-sql/check-12-parallel-backend-diagnosis-sql/stdout.log`.

Review и QA подтвердили критерии manifest; это не автоматическое закрытие полной продуктовой задачи.

Решения: ["Подтверждена причина сбоя — предыдущая identification fixture переводит опубликованный KB в retired.", "Добавлена проверка отказа без опубликованного KB и восстановление конкретного релиза первоначальной diagnosis fixture.", "Контроллер сообщил PASS для deno-check, diff-check и deno-tests. SQL gate ожидает повторной проверки после применения patch."].

Ограничения: подтверждены только явно указанные режимы и критерии. State/metrics: `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-t170-guest-initial-diagnosis-sql-codex-20261116-34`.
Следующий шаг: следующая независимая задача manifest; ошибки публикации смотреть в state.json.
