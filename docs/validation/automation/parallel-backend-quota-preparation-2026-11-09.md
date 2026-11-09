# B / T163 — подготовка

Base 4bbd35a, отдельный worktree `/Users/ruslansabirov/.codex/worktrees/ffee/Plants`,
ветка `codex/plants-backend`. T161/auth/HTTP не повторяются; задачи/Swift не меняются.

Два bounded high-risk пакета в `tools/automation/tasks.parallel-backend-quota-sql.json`:
registration ledger → atomic admission/settlement. Внутренний depends_on только
между этими ID. Миграции 202611090005/006 свободны на base. SQL-пакеты до B2
не означают production API/client или готовность T163.

Branch config (игнорируемый): `docs/validation/automation/runs/parallel-backend.config.json`.
SHA256 `278b088265ffcb95f508d4d5c8a0d1a7bc11406bbf46a271094b354c2ea29517`.
Routing/retry/budgets унаследованы без изменения: Developer Sol/high; Reviewer/QA
Astra/high для high risk, существующие fallback. Publish enabled, origin,
**только codex/plants-backend**; default config не изменён.

| Check ID | argv | stage / mode / timeout |
| --- | --- | --- |
| parallel-backend-quota-accounting | python3 tools/automation/parallel_backend_quota_gate.py --accounting | unit / fixture / 300s |
| parallel-backend-quota-admission | python3 tools/automation/parallel_backend_quota_gate.py | unit / fixture / 300s |
| deno-tests | deno task --cwd supabase/functions test | unit / fixture / 300s |
| deno-check | deno check --config supabase/functions/deno.json supabase/functions/plants-api/index.ts supabase/functions/analysis-worker/index.ts | static / local / 300s |
| diff-check | git diff --check | static / local / 30s |

Trusted gate — новый самостоятельный Python runner, свой temp PG17 data/socket и
clean/seeded-upgrade БД, pgTAP 1.3.4 из `/private/tmp/pgtap-1.3.4/sql/pgtap.sql`.
Снапшот всех старых public rows сравнивается до/после forward upgrade; separate
usage import/retry, unknown residual, immutable anchor/UTC cases. В полном режиме
99 реальных admit/finalize → **20 отдельных psql процессов**, все наблюдаются
через pg_stat_activity в ожидании held owner lock до отпуска; distinct IDs,
same-job replay и technical failure/finalizeOnce в обеих БД. Это подготовленные
проверки, до зелёного run их прохождение не заявлено. Старый cap runner не заменяет их.

Фактически выполнено:

- `validate --config ... --manifest tools/automation/tasks.parallel-backend-quota-sql.json` — VALID, 2 explicit tasks.
- `context --config ... --manifest ... --role developer` — PASS; полный контракт просмотрен, вывод `/tmp/narat-b163-context.txt`.
- `python3 tools/automation/parallel_backend_quota_gate.py --baseline --accounting` — ожидаемый exit 1 на старом **Free=1**: remaining_after_reserve=0 вместо2, calendar Nov1..Dec1 вместо регистрации Oct31..Nov30. Лог `/tmp/narat-b163-baseline.log`. Это отрицательный контроль, **не приёмка T163**.
- Первый sandbox запуск PG17 отказал на shmget Operation not permitted; повтор с разрешённым локальным выполнением дошёл до указанного продуктового assertion. Никакого Supabase stack/network/production.
- `python3 -m unittest discover -s tools/automation/tests -q` — 115 tests / OK, fixture-only; `/tmp/narat-b163-automation.log`.
- `git diff --check` — PASS.

Live Auth/Supabase/Storage/provider/StoreKit и iOS/Simulator не запускались.
Исторического источника permanent registration нет: месячный доступ неизвестной
истории должен остаться fail-closed до verified import; запрос владельцу отправлен,
решение по дате не выдумано. Контракт не меняет `collection-http.md`.

Следующий шаг: clean-tree real run `parallel-backend-quota-sql-20261109-01` с
явным branch config, проверки и независимые Reviewer/QA; затем отдельный B2 manifest.


## Recovery после реального run-01

Подготовка опубликована SHA365840a. Run-01 действительно запущен, но Developer
Sol/high завершился timeout900s без answer.json/patch; WAITING, следующий PENDING.
Raw state/metrics/stdout сохранены, исходный manifest не resume и не заменяется в
старом run. Это выполненный модельный вызов, не SQL-приёмка и не нулевой расход.

Новый manifest `tasks.parallel-backend-quota-sql-recovery.json`: три более узких
среза 005 anchor/windows →006 ledger/import →007 admission. Новый --anchors
trusted mode не требует ledger следующего среза. Новый config SHA256
`608c6a50dd40b90e6aeb6b89163e6fc666469b8d44b81d2d1b10289df73bcbb9`;
добавлен check parallel-backend-quota-anchors, argv
`python3 tools/automation/parallel_backend_quota_gate.py --anchors`,
unit / fixture / 300s. Остальные argv/routing/budgets прежние.
Validate3/context/diff PASS; следующий run-id parallel-backend-quota-sql-20261109-02.
Владелец подтвердил fail-closed неизвестной legacy даты; это больше не ожидаемый ответ.

Recovery negative control `--baseline --anchors` повторён: ожидаемый exit1 на старом Free1/calendar, `/tmp/narat-b163-baseline-v2.log`; это не продуктовый PASS.
