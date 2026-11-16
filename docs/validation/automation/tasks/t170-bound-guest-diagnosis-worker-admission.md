# t170-bound-guest-diagnosis-worker-admission

Repair SQL worker lease and provider reservation for correctly bound starter diagnosis.

Подготовлены узкий SQL-допуск гостевой диагностики к worker и фикстуры полного сценария.

Изменённые файлы: supabase/migrations/202611160006_bound_guest_diagnosis_worker.sql, supabase/tests/diagnosis_jobs.test.sql.

Вызовы — developer 1, reviewer 1, qa 1. Модели — 441.44 с, проверки — 48.39 с. Повторы моделей — 0, тайм-ауты моделей — 0, тайм-ауты проверок — 0.

Проверки:

- deno-check — PASS (local, exit 0, 0.12 с). Лог `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-t170-bound-guest-diagnosis-worker-codex-20261116-37/t170-bound-guest-diagnosis-worker-admission/check-1-deno-check/stdout.log`.
- diff-check — PASS (local, exit 0, 0.03 с). Лог `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-t170-bound-guest-diagnosis-worker-codex-20261116-37/t170-bound-guest-diagnosis-worker-admission/check-2-diff-check/stdout.log`.
- deno-tests — PASS (fixture, exit 0, 4.58 с). Лог `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-t170-bound-guest-diagnosis-worker-codex-20261116-37/t170-bound-guest-diagnosis-worker-admission/check-3-deno-tests/stdout.log`.
- parallel-backend-diagnosis-sql — PASS (fixture, exit 0, 43.67 с). Лог `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-t170-bound-guest-diagnosis-worker-codex-20261116-37/t170-bound-guest-diagnosis-worker-admission/check-4-parallel-backend-diagnosis-sql/stdout.log`.

Review и QA подтвердили критерии manifest; это не автоматическое закрытие полной продуктовой задачи.

Решения: ["Приватный helper проверяет активного владельца, installation, резерв, provenance и исходное фото; порядок блокировок сохранён.", "Существующий finalizer, прежняя маршрутизация и политики чтения сохранены.", "Проверки выполняет контроллер. Файлы, Git, handoff и tasks не изменялись; живые интеграции не запускались."].

Ограничения: подтверждены только явно указанные режимы и критерии. State/metrics: `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-t170-bound-guest-diagnosis-worker-codex-20261116-37`.
Следующий шаг: следующая независимая задача manifest; ошибки публикации смотреть в state.json.
