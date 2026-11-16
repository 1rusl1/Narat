# t170-guest-draft-ttl-lock-order

Resolve the draft replay versus cleanup lock-order inversion at TTL.

Подготовлен патч: replay блокирует существующий draft перед photo и повторно проверяет scope и TTL после ожиданий.

Изменённые файлы: supabase/migrations/202611160007_guest_diagnosis_draft.sql, supabase/tests/diagnosis_jobs.test.sql.

Вызовы — developer 1, reviewer 1, qa 1. Модели — 213.12 с, проверки — 96.33 с. Повторы моделей — 0, тайм-ауты моделей — 0, тайм-ауты проверок — 0.

Проверки:

- deno-check — PASS (local, exit 0, 0.09 с). Лог `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-t170-guest-draft-ttl-lock-order-codex-20261116-39/t170-guest-draft-ttl-lock-order/check-1-deno-check/stdout.log`.
- diff-check — PASS (local, exit 0, 0.04 с). Лог `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-t170-guest-draft-ttl-lock-order-codex-20261116-39/t170-guest-draft-ttl-lock-order/check-2-diff-check/stdout.log`.
- automation-tests — PASS (fixture, exit 0, 49.12 с). Лог `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-t170-guest-draft-ttl-lock-order-codex-20261116-39/t170-guest-draft-ttl-lock-order/check-3-automation-tests/stdout.log`.
- deno-tests — PASS (fixture, exit 0, 4.56 с). Лог `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-t170-guest-draft-ttl-lock-order-codex-20261116-39/t170-guest-draft-ttl-lock-order/check-4-deno-tests/stdout.log`.
- parallel-backend-diagnosis-sql — PASS (fixture, exit 0, 42.52 с). Лог `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-t170-guest-draft-ttl-lock-order-codex-20261116-39/t170-guest-draft-ttl-lock-order/check-5-parallel-backend-diagnosis-sql/stdout.log`.

Review и QA подтвердили критерии manifest; это не автоматическое закрытие полной продуктовой задачи.

Решения: ["Порядок replay: profile → installation → existing draft → photo → job → source. После ожидания draft проверяются актуальные deleted/claimed/storage_cleaned и TTL; после остальных блокировок сохраняется полная исходная проверка scope с новым clock_timestamp().", "Путь создания без receipt, grants, Storage и claim не изменены. Добавлены четыре rollback pgTAP-проверки.", "Детерминированный scratch fixture: зафиксировать данные bound_initial_photo/job/install и diagnosis_draft_receipt из diagnosis_jobs.test.sql до завершающего ROLLBACK; owner=16320000-0000-4000-8000-000000000081, operation=16320000-0000-4000-8000-000000000091, credential=repeat('8',64). В отдельных сессиях вызывать публичный RPC с сохранённым job_id.", "TTL-регрессия: установить одинаковый близкий будущий expires_at у source и draft. Сессия A: BEGIN, SELECT draft FOR UPDATE. Сессия B: вызвать точный replay; через pg_blocking_pids подтвердить ожидание A. После TTL сессия A вызывает finish_guest_photo_cleanup(draft_id), затем COMMIT. Cleanup должен завершиться без ожидания photo от B; B получает P0002:DRAFT_EXPIRED, без deadlock.", "Дополнительный сценарий свежего времени: A блокирует только photo; B начинает replay до TTL и ожидает photo, уже удерживая draft. После TTL A делает COMMIT без cleanup; B получает P0002:DRAFT_EXPIRED. До TTL без блокировок replay возвращает исходный receipt.", "Проверки не запускались: diff-check, deno-check, deno-tests и полный SQL clean/upgrade выполняет контроллер перед Review/QA. Файлы, Git и handoff не изменены."].

Ограничения: подтверждены только явно указанные режимы и критерии. State/metrics: `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-t170-guest-draft-ttl-lock-order-codex-20261116-39`.
Следующий шаг: следующая независимая задача manifest; ошибки публикации смотреть в state.json.
