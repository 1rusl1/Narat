# v19-routine-contextual-calendar

Require an explicit verified routine rule before a contextual care profile can emit a soil-check date.

Исправлено формирование описания SQL-теста: JSONB явно преобразуется в текст.

Изменённые файлы: supabase/migrations/202611150056_require_explicit_contextual_calendar.sql, supabase/tests/routine_soil_check.test.sql.

Вызовы — developer 2, reviewer 1, qa 1. Модели — 376.24 с, проверки — 59.22 с. Повторы моделей — 1, тайм-ауты моделей — 0, тайм-ауты проверок — 0.

Проверки:

- diff-check — PASS (local, exit 0, 0.04 с). Лог `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-v19-routine-contextual-calendar-codex-20261115-11/v19-routine-contextual-calendar/check-4-diff-check/stdout.log`.
- deno-tests — PASS (fixture, exit 0, 4.53 с). Лог `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-v19-routine-contextual-calendar-codex-20261115-11/v19-routine-contextual-calendar/check-5-deno-tests/stdout.log`.
- parallel-backend-diagnosis-sql — PASS (fixture, exit 0, 42.34 с). Лог `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-v19-routine-contextual-calendar-codex-20261115-11/v19-routine-contextual-calendar/check-6-parallel-backend-diagnosis-sql/stdout.log`.

Review и QA подтвердили критерии manifest; это не автоматическое закрытие полной продуктовой задачи.

Решения: ["Лог подтверждает выбор JSONB-конкатенации вместо текстовой; явное приведение устраняет причину ошибки.", "Успешные проверки не повторялись. SQL-проверку после применения патча запускает контроллер.", "Миграция не изменена; T160/T171 остаются открытыми."].

Ограничения: подтверждены только явно указанные режимы и критерии. State/metrics: `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-v19-routine-contextual-calendar-codex-20261115-11`.
Следующий шаг: следующая независимая задача manifest; ошибки публикации смотреть в state.json.
