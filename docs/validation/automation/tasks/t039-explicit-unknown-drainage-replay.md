# t039-explicit-unknown-drainage-replay

Preserve independent watering context without regressing explicit unknown drainage.

Подготовлен патч: plant.edit сохраняет drainage и last_watered независимо, включая явный unknown; legacy-записи сохраняют прежнее поведение.

Изменённые файлы: supabase/migrations/202611160016_preserve_last_watered_on_plant_edit.sql, supabase/tests/plant_edit_conditions.test.sql.

Вызовы — developer 1, reviewer 1, qa 1. Модели — 265.79 с, проверки — 64.53 с. Повторы моделей — 0, тайм-ауты моделей — 0, тайм-ауты проверок — 0.

Проверки:

- deno-check — PASS (local, exit 0, 0.14 с). Лог `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-t039-explicit-unknown-drainage-replay-codex-20261116-51/t039-explicit-unknown-drainage-replay/check-1-deno-check/stdout.log`.
- diff-check — PASS (local, exit 0, 0.02 с). Лог `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-t039-explicit-unknown-drainage-replay-codex-20261116-51/t039-explicit-unknown-drainage-replay/check-2-diff-check/stdout.log`.
- deno-tests — PASS (fixture, exit 0, 4.23 с). Лог `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-t039-explicit-unknown-drainage-replay-codex-20261116-51/t039-explicit-unknown-drainage-replay/check-3-deno-tests/stdout.log`.
- parallel-backend-diagnosis-sql — PASS (fixture, exit 0, 60.14 с). Лог `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-t039-explicit-unknown-drainage-replay-codex-20261116-51/t039-explicit-unknown-drainage-replay/check-4-parallel-backend-diagnosis-sql/stdout.log`.

Review и QA подтвердили критерии manifest; это не автоматическое закрытие полной продуктовой задачи.

Решения: ["Изменяются только неопубликованная миграция 016 и существующий SQL-тест; исторические снимки не переписываются.", "Настройка ограничена вызовом execute_plant_edit_command; несвязанные UPDATE сохраняют существующую пару полей.", "Добавлены проверки unknown, yes, исторической даты, отсутствующего снимка, изменения света, replay/no-op, soft-delete, ACL и восстановления настройки перед legacy-вставками.", "Файлы и Git не изменялись. Обязательные проверки выполнит контроллер; живые интеграции не запускались."].

Ограничения: подтверждены только явно указанные режимы и критерии. State/metrics: `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-t039-explicit-unknown-drainage-replay-codex-20261116-51`.
Следующий шаг: следующая независимая задача manifest; ошибки публикации смотреть в state.json.
