# t039-stage-compatible-snapshot-edit

Make verified plant condition editing work with the actual hosted Supabase migration role.

Подготовлен патч: custom setting заменён внутренним значением INSERT с нормализацией в BEFORE-триггере; обновлены SQL fixtures.

Изменённые файлы: supabase/migrations/202611160016_preserve_last_watered_on_plant_edit.sql, supabase/tests/plant_edit_conditions.test.sql, supabase/tests/plant_edit_taxon.test.sql.

Вызовы — developer 1, reviewer 1, qa 1. Модели — 237.52 с, проверки — 64.61 с. Повторы моделей — 0, тайм-ауты моделей — 0, тайм-ауты проверок — 0.

Проверки:

- deno-check — PASS (local, exit 0, 0.08 с). Лог `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-t039-stage-compatible-snapshot-edit-codex-20261116-52/t039-stage-compatible-snapshot-edit/check-1-deno-check/stdout.log`.
- diff-check — PASS (local, exit 0, 0.02 с). Лог `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-t039-stage-compatible-snapshot-edit-codex-20261116-52/t039-stage-compatible-snapshot-edit/check-2-diff-check/stdout.log`.
- deno-tests — PASS (fixture, exit 0, 4.20 с). Лог `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-t039-stage-compatible-snapshot-edit-codex-20261116-52/t039-stage-compatible-snapshot-edit/check-3-deno-tests/stdout.log`.
- parallel-backend-diagnosis-sql — PASS (fixture, exit 0, 60.31 с). Лог `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-t039-stage-compatible-snapshot-edit-codex-20261116-52/t039-stage-compatible-snapshot-edit/check-4-parallel-backend-diagnosis-sql/stdout.log`.

Review и QA подтвердили критерии manifest; это не автоматическое закрытие полной продуктовой задачи.

Решения: ["Маркер применяется только при INSERT с вычисленным drainage='unknown'; известные значения и legacy aliasing сохранены.", "Guarded replacement, текущие ACL и защита независимых пар при несвязанных UPDATE сохранены; схема и старые миграции не меняются.", "Добавлены проверки отсутствия custom scope, запрета публичного маркера, CHECK, PUBLIC EXECUTE и неизменности RPC-параметров.", "Файлы не изменялись. Проверки переданы контроллеру; удалённые вызовы и deployment не выполнялись."].

Ограничения: подтверждены только явно указанные режимы и критерии. State/metrics: `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-t039-stage-compatible-snapshot-edit-codex-20261116-52`.
Следующий шаг: следующая независимая задача manifest; ошибки публикации смотреть в state.json.
