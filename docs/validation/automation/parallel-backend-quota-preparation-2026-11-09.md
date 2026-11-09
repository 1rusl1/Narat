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


## Run02 результат и run03 подготовка

Accepted/pushed anchors21ee7a7, ledgere6b1f7c;336 Deno115 automation,clean/upgrade
54+49 pgTAP+12 UTC each. Thirdcombined admission/finalize timeout900/noanswer/nopatch,
WAITING. Raw logs preserved;007 never existed/applied. Next free007 is now narrow
registration_state_guard (controller candidate),008_quota_reservation and009_quota_settlement
are separate bounded pendingtasks. Old manifests/runs are audit, do not resume.

Controller negative upgrade probe BEFORE verified import reproduced legacy NULL
anchor permanent→guest reversal: FAIL1/55 `/tmp/narat-b163-anchor-review/proof.log`.
Project guard007 +55 test + independent protected probe now PASS clean/upgrade,
`/tmp/narat-b163-guard-project.log`. Accepted005/006 unchanged. Notindependentacceptanceyet.

Newmanifest tasks.parallel-backend-quota-sql-finalization.json validate3/context/diffPASS.
Newconfig hash59ed00ee3315c8db379677e7aa0ef1558cc7b9be590b64f626d9cf3f043e31ff.
Newcheck parallel-backend-quota-legacy-guard argv python3 tools/automation/parallel_backend_quota_gate.py --anchors --legacy-guard;
newcheck parallel-backend-quota-reserve argv python3 tools/automation/parallel_backend_quota_gate.py --reserve;
bothunit/fixture/300s, routing/budgets/publishunchanged.
Reserve-only seeds99 historical consumedfixtures, real20connections; never claimfull
T163 fromit. Defaultgate after009still uses99 ACTUALadmit+finalize andsix20-connection
rounds. Nextactualrun parallel-backend-quota-sql-20261109-03. FullAPI/T036/livepending.


Перед run03 дополнительно: `python3 -m unittest discover -s tools/automation/tests -q`
— **115 tests / OK**, `/tmp/narat-b163-finalization-automation.log`.
Общий неизменённый `t161_collection_gate.py --slots` — **FAIL** на seeded-upgrade
snapshot equality после добавления новых таблиц005/006; clean131pgTAP/две гонки
успели пройти, это не полный PASS. Лог `/tmp/narat-b163-guard-cap.log`.
A уведомлена, общий runner/config не изменялся. Новый controller-owned режим
`python3 tools/automation/parallel_backend_quota_gate.py --anchors --legacy-guard --cap-regression`
— **PASS**: clean и upgrade по55 anchor +131 T161 pgTAP, четыре настоящие
owner-lock гонки, все preexisting public rows сохранены. Лог
`/tmp/narat-b163-guard-cap-v2.log`. SQL tests и race implementation T161 скопированы
без изменения условий; generic quota KB fixture имеет draft state, а исходный
T161 catalogue fixture остаётся единственным published release.
Check ID `parallel-backend-cap-regression`, unit/fixture/300s; argv — команда выше.
Он заменяет ошибочное strict-table-key equality только в этой branch config,
не старый shared runner. Root gate дополнительно сравнивает все прежние строки,
новые таблицы допускает как additions. Самостоятельный negative old upgrade
probe остаётся FAIL1/55; guard candidate — ещё до независимой приёмки.


## Run03 / reserve recovery

Guard a04794c accepted/pushed (55+131pgTAP each/12UTC/4races,336Deno115automation
ReviewQA). Reserve returned37618-byte patch but74-char malformed fingerprint
(expected64); correctly rejected, raw answer/state unchanged, settlementPENDING.
Original answer SHA256 de0ac185a94bff6a88cace5b273c460bed3089d11c625cb6852d3398d829a897.
Controller applied only008+test afterscope/gitapplychecks, fixed SQL BEGIN; and
B expected remaining (two existing owncharges, nowadmittedtrue/remaining0).
Reserve gate78+55+49pgTAP each +4x20 realconnections PASS after honest compile/
fixture FAILs. Log/tmp/narat-b163-reserve-recovery-v4.log; notsettlement/fullT163.
Added failing TAP diagnostics toprotectedB gate only. No005/006/007rewrite.

Between runs ordinaryFF72bcccc A integration merged, candidatefilespreserved.
New manifest tasks.parallel-backend-quota-reserve-recovery.json validate2/context/
diffPASS. Samebranchconfighash59ed00ee3315c8db379677e7aa0ef1558cc7b9be590b64f626d9cf3f043e31ff,
samecheckargv/modes/timeouts/routing/budgets/backendpublish. Newrun04 fromclean
candidatecheckpoint: Developer/Reviewer/QA008 acceptance then009settlement. No03resume.
All originalchecks required afresh; Deno008 not claimed frompreviousancestor runs.


## Run04 результат / run05 подготовка

008 independently accepted/pushed141d548 (1Dev/1Review/1QA),78+55+49pgTAP each,
4x20 realconnections,336Deno115automation/typecheck/diff. Combined settlement
Developer timeout900 WITHOUTanswer/patch;009 absent,WAITING,rawstateunchanged.
Newmanifest tasks.parallel-backend-quota-settle-bind.json validate2/context/help/
diffPASS:009finalizeONLY →010bindONLY, no combinedgeneration. Confignewhash
5df700479dc274b65fb61fd76c836251c09594d04ebd0ff122a98010dbd96f49; newcheck
parallel-backend-quota-bind argv python3 tools/automation/parallel_backend_quota_gate.py --bind,
unit/fixture/300s. Fullgate additionally includesall78reserve regression, still
99ACTUALadmit/finalize +6x20connections. Actualbinding10file/suite required,not
filepresence acceptance. Nofullsettlement/livePASSyet. Samebackendpublish/routing/
budgets, sharedconfigunchanged. Nextclean-treeactualrun05, old04notresume.

Run05 preparation regression: `python3 tools/automation/parallel_backend_quota_gate.py --reserve` — PASS clean/upgrade55+49+78pgTAP/12UTC/four20-connectionraces, `/tmp/narat-b163-finalize-prep-reserve.log`. Это не settlement acceptance.
