# t083-profile-reminder-hour-core

Persist the user's reminder hour through an owner-bound canonical profile command and read projection.

Исправлен приоритет SQL-операторов в проверке проекции /sync.

Изменённые файлы: supabase/migrations/202611150059_profile_reminder_hour.sql, supabase/tests/auth_registration_profile.test.sql.

Вызовы — developer 2, reviewer 1, qa 1. Модели — 389.62 с, проверки — 53.00 с. Повторы моделей — 1, тайм-ауты моделей — 0, тайм-ауты проверок — 0.

Проверки:

- diff-check — PASS (local, exit 0, 0.02 с). Лог `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-t083-profile-reminder-hour-core-codex-20261115-16/t083-profile-reminder-hour-core/check-4-diff-check/stdout.log`.
- deno-tests — PASS (fixture, exit 0, 4.41 с). Лог `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-t083-profile-reminder-hour-core-codex-20261115-16/t083-profile-reminder-hour-core/check-5-deno-tests/stdout.log`.
- parallel-backend-diagnosis-sql — PASS (fixture, exit 0, 40.58 с). Лог `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-t083-profile-reminder-hour-core-codex-20261115-16/t083-profile-reminder-hour-core/check-6-parallel-backend-diagnosis-sql/stdout.log`.

Review и QA подтвердили критерии manifest; это не автоматическое закрытие полной продуктовой задачи.

Решения: ["Лог подтвердил неоднозначность вычитания строковых литералов из-за приоритета операторов; извлечение JSON-профиля заключено в скобки.", "Успешные проверки не перезапускались. Патч готов к повторной SQL-проверке контроллером; файлы и Git не изменялись."].

Ограничения: подтверждены только явно указанные режимы и критерии. State/metrics: `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-t083-profile-reminder-hour-core-codex-20261115-16`.
Следующий шаг: следующая независимая задача manifest; ошибки публикации смотреть в state.json.
