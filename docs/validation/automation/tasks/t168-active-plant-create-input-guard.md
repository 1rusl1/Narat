# t168-active-plant-create-input-guard

Reject newly submitted camera light and retired seasonal overrides in the canonical plant create SQL writer while retaining legitimate historical replay.

Исправлена квалификация переменной владельца в SQL fixture через явную метку блока.

Изменённые файлы: supabase/migrations/202611150058_guard_new_plant_create_context.sql, supabase/tests/diagnosis_jobs.test.sql.

Вызовы — developer 2, reviewer 1, qa 1. Модели — 323.09 с, проверки — 52.39 с. Повторы моделей — 1, тайм-ауты моделей — 0, тайм-ауты проверок — 0.

Проверки:

- diff-check — PASS (local, exit 0, 0.04 с). Лог `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-t168-active-plant-create-input-guard-codex-20261115-15/t168-active-plant-create-input-guard/check-4-diff-check/stdout.log`.
- deno-tests — PASS (fixture, exit 0, 4.37 с). Лог `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-t168-active-plant-create-input-guard-codex-20261115-15/t168-active-plant-create-input-guard/check-5-deno-tests/stdout.log`.
- parallel-backend-diagnosis-sql — PASS (fixture, exit 0, 39.42 с). Лог `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-t168-active-plant-create-input-guard-codex-20261115-15/t168-active-plant-create-input-guard/check-6-parallel-backend-diagnosis-sql/stdout.log`.

Review и QA подтвердили критерии manifest; это не автоматическое закрытие полной продуктовой задачи.

Решения: ["Обе ошибочные ссылки заменены обращением к переменной явно помеченного PL/pgSQL-блока.", "Миграция 058 не менялась.", "Полученные PASS для diff-check и Deno учтены; проверки не перезапускались. Исправление готово к проверкам контроллера."].

Ограничения: подтверждены только явно указанные режимы и критерии. State/metrics: `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-t168-active-plant-create-input-guard-codex-20261115-15`.
Следующий шаг: следующая независимая задача manifest; ошибки публикации смотреть в state.json.
