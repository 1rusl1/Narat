# t170-persist-conditions-on-diagnosis-save

Persist first diagnosis answers as the saved plant’s canonical condition snapshot.

Подготовлена forward-миграция: первый диагноз сохраняет исходные условия в канонический snapshot той же транзакцией. Добавлены SQL fixtures.

Изменённые файлы: supabase/migrations/202611160008_initial_diagnosis_conditions_on_save.sql, supabase/tests/diagnosis_jobs.test.sql.

Вызовы — developer 1, reviewer 1, qa 1. Модели — 388.31 с, проверки — 52.24 с. Повторы моделей — 0, тайм-ауты моделей — 0, тайм-ауты проверок — 0.

Проверки:

- deno-check — PASS (local, exit 0, 2.19 с). Лог `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-t170-persist-conditions-on-diagnosis-save-codex-20261116-41/t170-persist-conditions-on-diagnosis-save/check-1-deno-check/stdout.log`.
- diff-check — PASS (local, exit 0, 0.04 с). Лог `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-t170-persist-conditions-on-diagnosis-save-codex-20261116-41/t170-persist-conditions-on-diagnosis-save/check-2-diff-check/stdout.log`.
- deno-tests — PASS (fixture, exit 0, 5.18 с). Лог `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-t170-persist-conditions-on-diagnosis-save-codex-20261116-41/t170-persist-conditions-on-diagnosis-save/check-3-deno-tests/stdout.log`.
- parallel-backend-diagnosis-sql — PASS (fixture, exit 0, 44.83 с). Лог `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-t170-persist-conditions-on-diagnosis-save-codex-20261116-41/t170-persist-conditions-on-diagnosis-save/check-4-parallel-backend-diagnosis-sql/stdout.log`.

Review и QA подтвердили критерии manifest; это не автоматическое закрытие полной продуктовой задачи.

Решения: ["Сохранены проверки источника из 001, существующий receipt и маршруты без initial_context; новых полей API нет.", "Частота и drainage сохраняются напрямую; last_watered остаётся unknown, остальные defaults не меняются.", "Файлы не изменялись. Проверки и применение patch выполняет controller; live-интеграции не запускались."].

Ограничения: подтверждены только явно указанные режимы и критерии. State/metrics: `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-t170-persist-conditions-on-diagnosis-save-codex-20261116-41`.
Следующий шаг: следующая независимая задача manifest; ошибки публикации смотреть в state.json.
