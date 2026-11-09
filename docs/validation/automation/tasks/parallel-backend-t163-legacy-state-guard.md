# parallel-backend-t163-legacy-state-guard

T163 narrow forward guard for accepted005 hole: unresolved permanent cannot flip to guest and regain a clock anchor. Controller already materialized the small candidate; inspect and repair only if necessary.

Кандидат корректен и готов к проверкам контроллера; исправления не требуются.

Изменённые файлы: нет.

Проверки:

- deno-check: PASS, local, exit 0; log `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-parallel-backend-quota-sql-20261109-03/parallel-backend-t163-legacy-state-guard/check-1-deno-check/stdout.log`
- diff-check: PASS, local, exit 0; log `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-parallel-backend-quota-sql-20261109-03/parallel-backend-t163-legacy-state-guard/check-2-diff-check/stdout.log`
- automation-tests: PASS, fixture, exit 0; log `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-parallel-backend-quota-sql-20261109-03/parallel-backend-t163-legacy-state-guard/check-3-automation-tests/stdout.log`
- deno-tests: PASS, fixture, exit 0; log `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-parallel-backend-quota-sql-20261109-03/parallel-backend-t163-legacy-state-guard/check-4-deno-tests/stdout.log`
- parallel-backend-cap-regression: PASS, fixture, exit 0; log `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-parallel-backend-quota-sql-20261109-03/parallel-backend-t163-legacy-state-guard/check-5-parallel-backend-cap-regression/stdout.log`

Review и QA подтвердили критерии manifest; это не автоматическое закрытие полной продуктовой задачи.

Решения: ["Миграция 007 запрещает permanent→guest независимо от наличия anchor; guest→permanent, обновления без смены статуса и DELETE разрешены.", "Новая definer-функция закрепляет пустой search_path, отзывает права PUBLIC/anon/authenticated и разрешает исполнение service_role. Миграция не изменяет существующие данные.", "Новый pgTAP-кейс выполняется до импорта доказательств и выбирает permanent с registered_at NULLS FIRST.", "FR-005/017/065, monthly-access.md и конституция учтены. Файлы не изменялись; проверки оставлены контроллеру. Live-подтверждения нет."].

Ограничения: подтверждены только явно указанные режимы и критерии. State/metrics: `/Users/ruslansabirov/.codex/worktrees/ffee/Plants/docs/validation/automation/runs/orchestrator-parallel-backend-quota-sql-20261109-03`.
Следующий шаг: следующая независимая задача manifest; ошибки публикации смотреть в state.json.
