# t169-owner-sync-season-retirement

Retire season_override from the active owner condition sync projection while preserving stored snapshots and public seasonal facts.

Исправлен шаблон миграции: приведение JSON-ключа к text теперь необязательно при PostgreSQL deparsing.

Изменённые файлы: supabase/migrations/202611150057_retire_season_override_owner_sync.sql, supabase/tests/plant_edit_conditions.test.sql.

Вызовы — developer 3, reviewer 1, qa 1. Модели — 435.45 с, проверки — 52.11 с. Повторы моделей — 2, тайм-ауты моделей — 0, тайм-ауты проверок — 0.

Проверки:

- diff-check — PASS (local, exit 0, 0.02 с). Лог `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-t169-owner-sync-season-retirement-codex-20261115-14/t169-owner-sync-season-retirement/check-4-diff-check/stdout.log`.
- deno-tests — PASS (fixture, exit 0, 4.49 с). Лог `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-t169-owner-sync-season-retirement-codex-20261115-14/t169-owner-sync-season-retirement/check-5-deno-tests/stdout.log`.
- parallel-backend-diagnosis-sql — PASS (fixture, exit 0, 40.63 с). Лог `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-t169-owner-sync-season-retirement-codex-20261115-14/t169-owner-sync-season-retirement/check-6-parallel-backend-diagnosis-sql/stdout.log`.

Review и QA подтвердили критерии manifest; это не автоматическое закрытие полной продуктовой задачи.

Решения: ["Сохранены требования ровно одного совпадения и отсутствия оставшихся ссылок на season_override.", "По данным контроллера diff-check и deno-tests прошли; повторно не запускались. Исправление SQL подготовлено для проверки контроллером."].

Ограничения: подтверждены только явно указанные режимы и критерии. State/metrics: `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-t169-owner-sync-season-retirement-codex-20261115-14`.
Следующий шаг: следующая независимая задача manifest; ошибки публикации смотреть в state.json.
