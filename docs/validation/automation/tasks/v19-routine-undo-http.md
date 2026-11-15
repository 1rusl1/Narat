# v19-routine-undo-http

Connect the verified routine soil-check reversal to owner /commands without changing other care undo routes.

Подготовлен патч HTTP-отмены проверки почвы, миграция 055 и фикстуры.

Изменённые файлы: supabase/functions/_shared/tests/routine_soil_check_http_test.ts, supabase/functions/plants-api/care-journal.ts, supabase/migrations/202611150055_routine_soil_check_undo_permissions.sql, supabase/tests/routine_soil_check.test.sql.

Вызовы — developer 1, reviewer 1, qa 1. Модели — 359.49 с, проверки — 46.68 с. Повторы моделей — 0, тайм-ауты моделей — 0, тайм-ауты проверок — 0.

Проверки:

- deno-check — PASS (local, exit 0, 0.84 с). Лог `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-v19-routine-undo-http-codex-20261115-08/v19-routine-undo-http/check-1-deno-check/stdout.log`.
- diff-check — PASS (local, exit 0, 0.04 с). Лог `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-v19-routine-undo-http-codex-20261115-08/v19-routine-undo-http/check-2-diff-check/stdout.log`.
- deno-tests — PASS (fixture, exit 0, 5.25 с). Лог `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-v19-routine-undo-http-codex-20261115-08/v19-routine-undo-http/check-3-deno-tests/stdout.log`.
- parallel-backend-diagnosis-sql — PASS (fixture, exit 0, 40.55 с). Лог `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-v19-routine-undo-http-codex-20261115-08/v19-routine-undo-http/check-4-parallel-backend-diagnosis-sql/stdout.log`.

Review и QA подтвердили критерии manifest; это не автоматическое закрытие полной продуктовой задачи.

Решения: ["Отмена использует отдельный RPC с владельцем из авторизации; прежние маршруты ручного ухода и первой помощи сохранены.", "Миграция 055 открывает выполнение только service_role; SQL-фикстура учитывает маркер активации и сохраняет проверку запрета PUBLIC.", "Ответ проверяется с сохранением микросекунд SQL watermark и возвращается с private, no-store.", "Файлы не изменялись. Обязательные проверки запускает контроллер после применения патча; живые интеграции не запускались."].

Ограничения: подтверждены только явно указанные режимы и критерии. State/metrics: `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-v19-routine-undo-http-codex-20261115-08`.
Следующий шаг: следующая независимая задача manifest; ошибки публикации смотреть в state.json.
