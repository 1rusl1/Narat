# Narat — текущий статус и передача работы

**Обновлено 2026-11-09.** B запущена в отдельном worktree/ветке codex/plants-backend от 4bbd35a; подготовлены контракт T163 и два SQL-среза с отдельным trusted PG17 gate. Реальная приёмка этих SQL ещё впереди; T163/T036 открыты. A независимо ведёт клиентский sync; collection-http.md стабилен.

## B / T163 — run-01 WAITING и recovery, 2026-11-09

Подготовка `365840a` успешно опубликована в origin/codex/plants-backend.
Реальный `parallel-backend-quota-sql-20261109-01`: Developer Sol/high вызван один
раз, **900s timeout**, answer.json/патча нет; первый срез WAITING, admission PENDING.
SQL не создан/не применён, Reviewer/QA и продуктовые SQL/Deno gates не запускались.
State/logs сохранены в ignored `docs/validation/automation/runs/orchestrator-parallel-backend-quota-sql-20261109-01/`; исходный run не resume.

Владелец прямо подтвердил: неизвестную legacy дату permanent регистрации
блокировать до подтверждённого импорта из Auth. Решение передано A, starter не
выдаётся заново. Подготовлен новый `tasks.parallel-backend-quota-sql-recovery.json`:
005 anchors/windows →006 legacy ledger →007 admission. Старый manifest сохранён
как аудит run-01, **не запускать**. `parallel_backend_quota_gate.py` получил --anchors,
контракт monthly-access.md согласован с тремя миграциями. Config hash теперь
`608c6a50dd40b90e6aeb6b89163e6fc666469b8d44b81d2d1b10289df73bcbb9`;
новый check argv `python3 tools/automation/parallel_backend_quota_gate.py --anchors`,
unit/fixture/300s. Routing/budgets/default config/publish branch не менялись.
Validate (3 tasks), developer context и diff-check PASS. Product checkbox открыты.

**Точный следующий шаг:** commit/push recovery подготовки, затем clean-tree
`parallel-backend-quota-sql-20261109-02` с явным branch --config; runtime приёмки нет.
После принятого SQL — отдельный API-пакет; live и клиент A/T036 остаются обязательными.

## B / T163 — подготовка registration quota, 2026-11-09

**Выполнено:** `contracts/monthly-access.md` фиксирует registration UTC anchor,
короткие месяцы, shared Free3/paid100, стартеры и перенос consumed/reserved/unknown.
Новый controller-owned `tools/automation/parallel_backend_quota_gate.py`: отдельный
PG17 clean/upgrade, retained rows, pgTAP и 20 настоящих соединений под наблюдаемым
owner lock. `tasks.parallel-backend-quota-sql.json` содержит два bounded SQL-пакета
005 accounting →006 admission; runtime SQL пока не реализован. Default config,
collection wire, Swift/tasks не менялись. Branch config игнорируется; hash/check
argv/mode/timeout и routing — [отчёт подготовки](validation/automation/parallel-backend-quota-preparation-2026-11-09.md).

**Реальные проверки:** validate (2 tasks), developer context и diff-check PASS;
115 automation fixture tests / OK (`/tmp/narat-b163-automation.log`).
Отрицательный контроль старого SQL — ожидаемый exit1: Free после первого запроса
remaining=0 вместо2 и calendar window; это не продуктовая приёмка. PG17 работает
с разрешённым локальным запуском вне sandbox shared-memory restriction.

**Ограничения:** legacy дата permanent регистрации неизвестна; отдельный service
verified import, без молчаливой покупки/guest created_at в роли anchor. Вопрос
владельцу отправлен. Full T163 ждёт API B2 + клиента A/T036; live Supabase/Auth/
Storage/provider/StoreKit и iOS не проверялись. 20-connection code подготовлен,
успешное прохождение ещё не заявлено. Продуктовые checkbox без изменений.

**Следующий шаг:** после commit/push подготовки запустить новый
`parallel-backend-quota-sql-20261109-01` через branch-specific --config, принять
оба SQL-среза реальными gates/Reviewer/QA, затем отдельно подготовить API.


**Workspace:** `/Users/ruslansabirov/Documents/ChatGPT/Plants`, ветка `main`.
**Источники:** [spec](../specs/001-plants-ios-mvp/spec.md), [tasks](../specs/001-plants-ios-mvp/tasks.md), [решения](validation/spec-simplification-2026-11-09.md), [аудит и карта зависимостей](validation/overengineering-review-2026-11-09.md).

## Подготовлены задания двум параллельным сессиям — 9 ноября 2026

По поручению владельца распределены **все 137 открытых ID**: A — 59 (iOS/клиентские сценарии и объединение), B — 78 (сервер/SQL/контракты/KB/каталог/evals). У каждого ID один ответственный, у смешанных задач указан вклад второго; T172–T174 распределены, но отложены как необязательные комнаты. `[X]` не менялись: 14/151. Подготовка не подтверждает runtime-готовность и не запускает новые чаты/worktree/модели.

**Изменённые файлы:** `docs/parallel/{README.md,session-ios.md,session-backend.md,allocation.json}`, ссылка в `specs/001-plants-ios-mvp/tasks.md`, предупреждение запуска в `tools/automation/ORCHESTRATOR.md`, этот handoff. Задания готовы к передаче в два отдельных Worktree-чата. Протокол сохраняет готовые auth/cap/HTTP/typed receipt и делит timeout sync на DTO/transport, затем engine/disk; B начинает с регистрации/квот T163, не ждёт всего T162. Следующие границы — guest, analysis/KB/billing, expiry/care и общая приёмка, с исходными зависимостями.

**Обнаруженные ограничения инфраструктуры:** `doctor.exclusive_run` защищает только run directory своего checkout. Две копии в разных worktree не защищают общий Simulator; только A запускает UI gates. Default config/Engine публикуют в `main` и проверяют имя текущей ветки, поэтому каждый чат обязан использовать собственный branch-specific `--config` с `codex/plants-ios` либо `codex/plants-backend`. Общий runtime/config не менялись, lock не отключён. A также интегратор: завершённые пакеты B объединяются между runs, итоговые проверки повторяются на объединённом коде, затем обычный push в main. Controller каждого checkout обновляет свой handoff и публикует свою ветку; итоговые checkbox — после интеграции.

**Проверки подготовки:** выполнено сравнение allocation с исходными checkbox: PASS, 137 уникальных ID без пропусков/дубликатов, A=59/B=78, optional=3. Полная структурная проверка — PASS: 151 статус совпадает с HEAD (14 отмечены/137 открыты), все группы/ответственные/вклады/optional согласованы, 33 локальные Markdown-ссылки существуют. Два branch-config прототипа приняты текущим `orchestration.context.validate` на существующем manifest; это проверка конфигурации, не готовность новых manifests. `git diff --check` и `git diff --cached --check` новых/изменённых файлов — PASS. Runtime suites/модельные вызовы/SQL/Xcode/Simulator/live Auth/Storage/AI/StoreKit в этом этапе не запускались. Живой параллелизм и экономия не измерены.

**Публикация подготовки:** коммит `3300baf` (`docs: prepare two parallel Plants orchestration sessions`) создан и успешно отправлен в `origin/main`; push exit 0 (`344eeb3..3300baf`). Staged whitespace check — PASS. Эта подтверждённая запись сохраняется отдельным handoff-коммитом; задачи/запуски runtime не изменились.

**Точный следующий шаг:** открыть два новых чата Worktree от коммита этой подготовки и передать [задание A](parallel/session-ios.md) и [задание B](parallel/session-backend.md). A материализует и проверяет два новых узких T162 manifests/gates; B фиксирует T163 transition contract, готовит новый PostgreSQL clean/upgrade/20-connection gate и узкие SQL/API manifests. Создание исполняемых JSON/gates — первый этап этих заданий; данный пакет содержит задания управляющим чатам, не готовые `run` manifests. Старые timeout runs и их evidence сохраняются, resume с изменённым контрактом запрещён.

## Client receipt принят; sync остановлен по timeout — 9 ноября 2026

Run `t162-client-wire-20261109-02`: `t162-client-create-receipt-recovery` **COMPLETED / Verified and published**, commit `e8a12fe` в origin/main. Кандидат `cf084e3` независимо принят после исправления target membership. Реализованы `PlantCreateReceiptDTO` и `sendCatalogueCreate`, валидация canonical receipt/payload, SQL timestamp parser с сохранением исходного watermark, error propagation и retry identity без синтетического legacy CommandResponseDTO. Изменены APIModels.swift, PlantsAPIClient.swift, CollectionWireTests.swift и pbxproj; оркестратор сохранил task report/handoff.

**Фактические проверки приёмки:** Xcode build и EN welcome PASS; **35 PlantsTests PASS, 0 failed, 0 skipped**, включая все шесть новых CollectionWireTests. Свежий unit-result: `docs/validation/automation/runs/q-5e3d2ff74f02b547fa100b07/unit-result.stdout.log`. Simulator smoke и diff-check PASS; независимые Review/QA PASS (по одному вызову). Прежний run-01 с 29 tests не считается приёмкой нового кода. Подготовка manifests: validate/context/diff-check PASS; checkpoint/push и acceptance/push подтверждены.

**Остановка:** зависимый `t162-client-sync-wire` — WAITING, Developer1 timeout900s, answer.json отсутствует, патч не применён. Его checks/Review/QA не запускались; canonical sync остаётся несовместим с текущим Swift flow. Это не готовое сохранение: typed create method пока не подключён к outbox/UI. Live Supabase/Auth/AI/StoreKit, новая SQL-проверка и физический iPhone не запускались. Tasks checkbox не изменялись; полный T162/T019/T149 остаётся открытым. Рабочее дерево после остановки проверено; controller изменил только текущий handoff.

**Точный следующий шаг:** новый manifest вместо resume большого sync пакета: (1) только canonical SyncWire DTO/SQL timestamp/cursor decode + transport mapping, explicit owner и unit fixtures в уже включённом CollectionWireTests.swift; (2) затем интеграция точных строк since/until/next_since в существующие SyncEngine/LocalStore с disk checkpoint/restart, failed-page atomicity и session A/B tests. Каждый — отдельная узкая приёмка, legacy disk compatibility обязательна. После принятия этих двух prerequisites — repository на существующем outbox, catalogue→login→save→card с cap/error/pending/restart и реальными UI gates. Не объявлять API method готовым пользовательским save. Новые Swift-файлы подключать к Xcode target до запуска тестов. Старые runtime evidence и timeout state не переписывать.

## Client wire run-01 остановлен после замечания Review

`t162-client-wire-20261109-01`: первый кандидат применён, но НЕ принят. Reviewer выявил, что новый `CollectionWireTests.swift` отсутствовал в Sources pbxproj: build/unit PASS покрывал только прежние 29 тестов. Developer repair был начат контроллером автоматически, затем управляющий процесс штатно прервал run (exit130), чтобы исправить controller-owned target membership; ни одна задача не опубликована. Кандидат APIModels/PlantsAPIClient/CollectionWireTests сохранён без объявления готовым.

Контроллер выполнил `xcodegen generate --spec ios/project.yml --project ios/`: pbxproj включает новый test file (+4 строки). Подготовлен `tasks.t162-client-wire-recovery.json`: read-only полная приёмка кандидата после свежих checks с минимум 35 реальными tests, затем sync task. Следующий шаг: validate/context/diff-check, checkpoint commit/push (не acceptance), новый run `t162-client-wire-20261109-02`; прежние 29-test evidence не использовать для приёмки новых AC. Live/полный save/UI/T162 не приняты. Для будущих новых Swift-файлов controller обязан актуализировать target membership до доказательств tests.

## Продолжение T162: клиентский wire prerequisite

По команде владельца «вперед» подготовлены два зависимых пакета `tools/automation/tasks.t162-client-wire.json`: typed create receipt/API с точными timestamp и затем canonical sync→существующий engine/store с disk checkpoints/owner isolation/legacy decode. Runtime ещё не изменён; tools config прежний. Сохранение через UI требует этих предпосылок и остаётся следующим отдельным пакетом, полный T162 не закрывается. Проверки подготовки: validate/context/diff-check выполняются перед запуском; build/unit/Simulator и независимые Review/QA — во время run. Live/guest/deploy не включены. Следующий шаг: commit/push подготовки, run `t162-client-wire-20261109-01`, наблюдать до результата, затем repository/save/card и UI gates.

## T162 HTTP adapters приняты и опубликованы — 9 ноября 2026

`t162-adapters-20261109-01`: обе задачи **COMPLETED / Verified and published**, по одному Developer/Reviewer/QA без repairs. Sync `c26a4e0`, catalogue create `88345ed` отправлены в origin/main. Production entrypoint использует `createProductionPlantsApiHandler`: подключены настоящие service-role RPC adapters `fetch_sync_delta` и `execute_plant_create_command`; auth/profile prerequisite сохранён. Bare factory сохраняет 503 fallback для тестовых/неподключённых handlers. Добавлены query/payload validation, owner boundaries, generic EN/PL errors и отдельный HTTP409 COLLECTION_LIMIT_REACHED; возврат авторитетного SQL JSON без синтетических receipts/watermarks.

**Изменены:** `supabase/functions/plants-api/{index,collection}.ts`, `_shared/http.ts`, `_shared/tests/collection_http_test.ts`, `specs/001-plants-ios-mvp/contracts/collection-http.md`; task reports и handoff. **Проверки:** sync — 327 Deno PASS, в том числе 11 HTTP fixtures; финальный create — **336 Deno PASS / 0 failed**, включая **20 HTTP fixtures**, targeted gate 20 PASS. PostgreSQL17 clean/upgrade — по 60 pgTAP (25 trusted +35 regression), четыре реальные owner-lock гонки PASS, public rows upgrade snapshot сохранён. Deno typecheck/diff-check PASS; iOS build/welcome/PlantsTests и Simulator smoke PASS по runner evidence. Это fixtures/локальный Simulator, не live product integration. Независимые Review/QA приняли оба контракта.

**Ограничения:** миграции/runtime клиента не менялись, live Auth/Supabase/Storage/AI/StoreKit и deploy не выполнялись; обработчики готовы в коде, доступность развёрнутого API не подтверждена. Каталог create допускает только постоянного active owner и без ненулевого photo_id: SQL пока не проверяет ownership main_photo_id при INSERT. Draft/claim, другие commands и полный UI/save остаются открытыми. Swift DTO ещё не читают новый canonical SQL wire, поэтому весь T162/T019/T044/T149 не закрывается; tasks checkbox остаются 14/137.

**Точный следующий шаг:** подготовить узкий клиентский manifest на `collection-http.md`: адаптация `SyncPageDTO`/command response к авторитетному SQL (без потери legacy cache), repository поверх существующих LocalStore/outbox/SyncEngine, минимальное catalogue→login→save→card, cap до операции и server rejection без потери ввода. Проверить pending/retry/disk restart/owner switch/A-B и фактический UI, отдельно live test backend. Не возвращать retired slots/rooms/draft fallback. Не resume старый foundation timeout run; новая клиентская очередь с отдельными UI gates. Контроллер дополнительно обновил этот текущий статус после публикации.

## Продолжение T162: два узких HTTP-пакета

По команде владельца «Продолжаем» подготовлен `tools/automation/tasks.t162-adapters.json`: сначала production sync/RPC/валидация/fixtures и точный wire contract, затем зависимый catalogue plant.create/cap/error/retry. Auth prerequisite 9551807 сохраняется. Используются существующие checks без изменения config; для create также настоящий PostgreSQL cap regression. Изменены manifest и handoff; runtime и checkbox пока не менялись. Live/клиент/guest/deploy вне среза. Подготовка: validate VALID (2 tasks), context Developer просмотрен, diff-check PASS; commit/push `89c68a2` подтверждён. Запуск и итог приёмки приведены выше. Старые timeout runs не resume.

## Принят первый prerequisite T019/T162 — 9 ноября 2026

Оркестратор `t019-auth-profile-20261109-01` завершён **COMPLETED / Verified and published**; runtime commit `9551807` отправлен в origin/main. Developer 1, независимые Reviewer 1 и QA 1, без repairs. Устранён fail-open default auth resolver: missing/invalid/deleting/deleted profile не становится active; ошибка чтения profile даёт generic EN/PL 503 без raw DB error. Auth seam использует настоящий Supabase client с mocked transport только в тестах; штатная авторизация остаётся настоящей.

**Изменены:** `supabase/functions/plants-api/index.ts`, новый `_shared/tests/auth_profile_test.ts`; оркестратор сохранил task report и Task Summary handoff. Контроллер дополнительно обновил этот текущий статус. **Проверки:** Deno typecheck/diff-check PASS; полный Deno fixture suite **316 PASS / 0 failed**, включая **57 новых auth HTTP fixtures PASS**; отдельный targeted gate также 57 PASS. Это не 373 уникальных теста. Проверены реальные default resolver и Supabase HTTP composition на mocked transport, owner boundaries и отсутствие вызова handlers при отказе. Reviewer/QA PASS. Live Auth/Supabase, SQL, iOS/Simulator не запускались этим срезом; сохранение/sync пока не подключены. Полные T019/T162 и остальные checkbox остаются открытыми.

**Точная точка продолжения:** из `tasks.t162-foundation.json` подготовить меньший manifest только command/sync adapter после принятого auth prerequisite: canonical Swift envelope → execute_plant_create_command/fetch_sync_delta, production wiring, collection cap mapping, exact receipt/sync projection, HTTP fixtures и существующий PostgreSQL cap regression. Исключить уже выполненную auth-работу, не resume старый timeout run. Затем клиентские DTO/repository/save/card/pending/restart/A-B. Старый большой run сохранён WAITING без патча; его timeout не выдан за приёмку. Комнаты/live/deploy не запускались.

## T162 run-01: тайм-аут без патча; уменьшен следующий срез

`t162-foundation-20261109-01` — WAITING, Developer 1: CLI timeout900s, answer.json отсутствует, патч не применён. Product checks/Review/QA не запускались, готовность не подтверждена. Исходные evidence сохраняются; старую очередь не resume с изменённым контрактом.

Подготовлен меньший manifest `tools/automation/tasks.t019-auth-profile.json`: только fail-closed auth/profile и реальные HTTP fixtures с mocked Supabase transport. Новый check в config; исходный foundation manifest сохранён для дальнейшего разбиения adapters. Следующий шаг: validate/context/diff-check, commit/push и отдельный run `t019-auth-profile-20261109-01`. Затем command/sync и клиент; T019/T162 и продуктовые checkbox открыты. Live не запускался.

## Подготовка запуска T162 foundation — 9 ноября 2026

Владелец поручил реализацию через оркестратор. Подготовлен ограниченный серверный manifest `tools/automation/tasks.t162-foundation.json`: production plant.create/catalogue и sync adapters, fail-closed auth/profile, cap/error mapping и meaningful HTTP fixtures. Новый check `t162-collection-http` в config; SQL regression использует существующий настоящий PostgreSQL cap gate. Изменены manifest/config/handoff; продуктовые checkbox не менялись. Это первый фундамент T019/T044/T162, без клиентского UI, guest claim, live/deploy и без закрытия родительских задач.

Следующий шаг: validate/context/diff-check, commit/push подготовки и запуск отдельного run `t162-foundation-20261109-01`; наблюдать проверки, независимые Review/QA и публикацию. Затем подготовить клиентский save/card пакет на принятом HTTP контракте. Подготовка: validate — VALID (1 task), context Developer просмотрен, diff-check PASS; 115 automation fixture tests PASS (40.097s, вне sandbox). Новый HTTP gate до реализации ещё не пройден; live не проверялся. Фактические результаты запуска фиксируются после приёмки.

## Обзор готовности к запуску — 9 ноября 2026

По запросу владельца сверены текущий код, tasks, quickstart и доказательства приёмки. Итог: публичный MVP ещё не готов; остаются шесть блоков — сохранение/sync, фотоанализ, проверенные данные/рекомендации, уход, доступ/покупки и безопасность/выпуск. Подробности и конкретные code blockers: [launch-readiness](validation/launch-readiness-2026-11-09.md). Изменены только этот handoff и новый отчёт; runtime/tasks checkbox не менялись (14 отмечены / 137 открыты, из них 3 необязательные комнаты).

**Реально выполнено:** чтение Swift/TS/SQL/CI, инвентаризация и сверка checkbox; targeted Deno `persistence_unavailable_test.ts` — **15 PASS, 0 failed** на fixtures. Они подтверждают явный 503 при неподключённой persistence, не успешный серверный save. `git diff --check` — PASS. Полные SQL/Deno/iOS suites, Simulator, live Auth/Supabase/Storage/AI/StoreKit, физическая камера и production не проверялись повторно; прежние PASS остаются историческими доказательствами своих срезов. Отсутствие release отчётов и billing/card/care UI зафиксировано без объявления всей инфраструктуры отсутствующей.

**Точный следующий шаг:** подготовить T162 на принятом T161, явно выделив отсутствующий фундамент T019/T044–T048: command/sync adapter → repository → минимальное подтверждённое сохранение из каталога и карточка. Затем client cap/server rejection, legacy decode, pending/retry/restart/A-B; отдельная live test integration. Удаление DTO само по себе T162 не закрывает. Далее T163/T166 и остальные зависимости по отчёту. Очередь разработки/оркестратор этим запросом не запускались. Этот раздел задаёт текущую точку продолжения; прежние «следующие шаги» ниже сохраняются как история.

## Итог текущей очереди — четыре среза приняты и опубликованы

**Результат 2026-11-09:** через обновлённый оркестратор приняты четыре среза: T161 cap `b5f2c8f`, T161 SQL retirement `01ba170`, T161 TypeScript/API `eb58c03`, ограниченный T168 client light-estimator `dadfcb1`. Все четыре — **COMPLETED / Verified and published** в своих успешных run/task records, обычный push в origin/main подтверждён. T161 закрыта как серверный пакет по собственным SQL/Deno AC; полные T155/T158/T168 и клиентская T162 не закрывались.

**Клиентский результат T168:** удалены `LightingEstimateResult`, `LightingEstimating`, `applyEstimatedLighting`; `selectLightLevel` больше не принимает внешний source. Явный известный выбор — manual/confirmed, unknown — unknown/unconfirmed. Исторический camera_estimate остаётся декодируемым и без действий пользователя не превращается в manual. Новый meaningful test проверяет все уровни/оба intent, сохранность flow/photo/species/retry identity и JSON roundtrip; прежние disk/cache/owner/outbox regressions оставлены. Изменены `ios/Plants/Domain/PlantTypes.swift`, `Features/Analysis/{AnalysisFlowModel,CareQuestionsView}.swift`, `ios/PlantsTests/FirstHelpUnitTests.swift`; инструменты/manifest и handoff подготовлены отдельным checkpoint `9774fdf`.

**Реально выполненные проверки:**

- PostgreSQL17 fixtures: clean и seeded-upgrade по **131 pgTAP**, четыре настоящие конкурентные гонки с наблюдаемым owner lock; upgrade public rows/owners/history/spending/receipts неизменны. Это свежие временные БД, не staging/production. Итоговые SQL проверки backend-среза прошли до его принятия; позже менялись только клиент и документация.
- Backend fixtures: **259 Deno PASS**, deno-check и diff-check PASS на финальном backend fingerprint. Старый положительный guest claim и production HTTP не принимались.
- T168 local iOS: Xcode build **PASS**, EN welcome **PASS**, **29 PlantsTests PASS, 0 failed, 0 skipped**. Включены legacy disk/cache и новый manual/unknown тест. `ios_gate` evidence: `docs/validation/automation/runs/q-9d577638ffadf17d132d6d80/summary.json` и `unit-result.stdout.log`.
- Local Simulator/MCP: build/handshakes/welcome/care-navigation **PASS**, summary `docs/validation/automation/runs/q-490b11063686d2e96658dc52/summary.json`. Это существующий UI smoke, не полная UI-приёмка камеры, сохранения, PL/EN или live backend.
- T168 static writer gate и **115 automation fixtures PASS** на последнем клиентском fingerprint; diff-check PASS. `validate/context` новых manifests и py_compile gates прошли при подготовке. После приёмки контроллер менял только документацию/статусы; финальный `git diff --check` и сверка checkbox/handoff — PASS (14/137; T155/T158/T162/T168 открыты). Runtime тесты без новых runtime-правок не повторялись.

**Маршруты оркестратора подтверждены живыми CLI:** cap/SQL high risk — отдельные Astra Review+QA; обычный TS — Sol Review+QA; low/low T168 — один Sol Developer + одна совмещённая Sol acceptance после ВСЕХ проверок, включая UI. T168 принят с первой попытки каждого вызова. Metrics прочитаны для всех трёх runs; всего 12 call records, включая отклонённый SQL patch и interrupted попытку. У interrupted record время/итог неизвестны; CLI token scope неизвестен, поэтому точная экономия токенов/денег не заявляется. Это живые модели, но не живые продуктовые интеграции.

**Фактические ограничения:** первоначальный run `t161-collection-20261109-01` сохраняет WAITING SQL и PENDING backend; выполненный cap в нём COMPLETED. Recovery `t161-collection-20261109-02` завершил SQL/TS; не изменять старые evidence и не resume старую очередь. SQL candidate был восстановлен только правкой одного пробела diff header, содержание побайтово проверено. Подсказка при compaction после failed apply пока не содержит пути к rejected proposal; это отдельный оставшийся дефект удобства восстановления, не продуктовая приёмка.

basic-care module не подключён production router; общий HTTP cap mapping, рабочее client save/pending и положительный guest baseline остаются незавершёнными. SQL/API guards нового camera input и повторная отправка legacy camera payload НЕ входят в принятый клиентский срез T168. Полный expiry всех reminders/first-aid/premium — T164. Статически подтверждён сохранённый baseline gap premium-ветки `can_owner_schedule_rule` в `202611090004`: она обращается к несуществующим в migrations `care_plans.applicability_status/chemical_must_revalidate_after`; эта ветка не исполнялась в T161, её согласование необходимо перед дальнейшей приёмкой T164/T167/T171. StoreKit/AI/live Supabase, новая PL-приёмка и физическая камера не запускались.

**Точный следующий продуктовый шаг:** подготовить manifest/gates T162 на принятом серверном T161: убрать FreeSelection/slot fields из активных Swift DTO/writers, декодировать новые и старые profile/membership/cache JSON, затем реализовать cap до реального сохранения и обработку server rejection с сохранением ввода/pending/restart/retry/owner isolation. Текущий UI сохранения ещё отсутствует, поэтому сначала нужен его реальный проверяемый путь, а не только удаление DTO. T163/T164 — по зависимостям; T168 server/API guards — отдельный независимый пакет. Checkbox: **14 выполненных / 137 открытых**, 151 активная задача; это не процент готовности продукта.

## T161 принят по серверному контракту; подготовлен клиентский срез T168

Три задачи приняты и отправлены в origin/main: atomic cap `b5f2c8f`, восстановленный SQL retirement `01ba170`, TS/API `eb58c03`. Run-02 **COMPLETED** для обеих своих задач. По одному независимому Reviewer/QA на каждый серверный срез. Кандидат SQL сохранён отдельным checkpoint `68f852f`; исходный run-01 остаётся WAITING по остановленной повторной генерации, не переименован в успешный. Неизменность восстановленного code/test относительно CLI answer проверена побайтово.

**Результат:** Free collection cap=3 на INSERT/restore/owner transfer; paid без collection cap. Нет новых select/автоматического назначения слотов; historical receipts/hash conflict, memberships/фото/owner history/расход сохранены. Basic-care SQL/TS eligibility больше не зависит от slot; expired entitlement не возвращает тройку. Новые basic state и sync/profile projections без slot/selection keys. Существующие первая помощь/premium/общий expiry lifecycle — вне этого среза (T164). Совместимый HTTP replay сохраняет старую payload projection; новые typed команды только enable/disable.

**Проверки:** финальные `t161-slots-retired` clean/seeded-upgrade — по **131** pgTAP (25+35+16+55), четыре реальные owner-lock гонки PASS; snapshot public rows на upgrade неизменен. **259 Deno fixtures**, deno-check и diff-check PASS на финальном backend fingerprint. **115 automation tests** PASS на SQL recovery fingerprint до TS-среза; на финальном backend повтор не требовался и не запускался. Это PostgreSQL/Deno fixtures и local typecheck; не live Supabase/StoreKit/AI, не новая iOS-сборка. T161 отмечена выполненной как серверный пакет с указанными режимами, родители T155/T158 и клиент T162 открыты. API/sync документы ссылаются на `collection-cap.md`; опечатка profile key исправлена управляющим процессом.

**Изменённые runtime/test файлы:** `supabase/migrations/20261109000{3_collection_cap,4_retire_free_slots}.sql`; `supabase/tests/{collection_cap,free_care}.test.sql`; `_shared/{BasicCareService,EntitlementGate}.ts`, `plants-api/basic-care.ts`, `_shared/tests/{foundational_services,claim_transfer}_test.ts`; `contracts/collection-cap.md`. Manifest/gates/отчёты перечислены в предыдущих разделах и Task Summary. Дополнительно синхронизированы `contracts/{api,sync}.md`, `tasks.md`, этот handoff.

**Живые ограничения:** basic-care module ещё не подключён production router, общий commands/claim HTTP mapping лимита не добавлен; API возвращает текущие реальные unavailable/ошибки. Положительный guest baseline и приложение save flow не принимались. Legacy product/first-aid/premium и полная остановка reminders после expiry требуют следующих задач. Стабильность/экономия нового оркестратора не выводятся из одного набора: run-01 включает неуспешную apply и interrupted attempt; raw usage не гарантирует per-turn scope. При compaction после rejected patch текущий packet не указал путь к старому answer — кандидат восстанавливался контроллером; улучшение передачи failed proposal осталось отдельной инфраструктурной работой.

**Следующий шаг в текущей работе:** подготовлен `tasks.t168-client-light.json` и `t168_light_writer_gate.py`: один low/low клиентский срез удаления неиспользуемых estimator protocol/writer с новой проверкой manual/unknown и сохранением legacy camera cache. Validate/context PASS; gate до реализации ещё не пройден. После commit/push запустить `python3 tools/automation/orchestrator.py run --manifest tools/automation/tasks.t168-client-light.json --run-id t168-client-light-20261109-01`. Полная T168 остаётся открытой: SQL/API guards/resubmission не входят в этот узкий срез. После него — T162 (client cap/save/pending) и T163/T164 по зависимостям.

## T161 — подготовлена следующая очередь обновлённого оркестратора

По поручению владельца подготовлен `tools/automation/tasks.t161-collection.json`: три зависимых задачи — атомарный cap коллекции, SQL retirement Free-мест, согласование TypeScript/API. Полная T162 зависит от отсутствующего рабочего UI сохранения; в эту очередь она не включена. T163/T164 и положительный guest остаются отдельно.

**Изменённые файлы:** новый manifest, `tools/automation/t161_collection_gate.py`, доверенные `tools/automation/sql/t161_{cap,slots}.sql`, два check entrypoints в `orchestrator.config.json`, этот handoff. Runner создаёт только временные PostgreSQL17 clean/seeded-upgrade кластеры, сравнивает все public rows до/после миграций, запускает pgTAP без skips/TODO и две настоящие гонки с наблюдаемым ожиданием owner lock (same retry/distinct create на последний остаток). Применённые migrations/продуктовые checkbox не изменены.

**Проверки подготовки:** `orchestrator.py validate --manifest tools/automation/tasks.t161-collection.json` — VALID, 3 tasks; `context --task t161-atomic-collection-cap --role developer` — PASS, полные criteria/scope; `python3 -m py_compile tools/automation/t161_collection_gate.py` и `git diff --check` — PASS. `python3 -m unittest discover -s tools/automation/tests -q` вне sandbox — **115 tests PASS / OK**, 40.375s (fixtures/subprocess/temporary Git). Первый запуск в sandbox прерван; его вывод не является итоговым PASS. Новый SQL gate до реализации cap/retirement ещё не проходил и не объявляется готовым продуктом.

**Ограничения и точный следующий шаг:** сохранить подготовку commit/push, из чистого Git запустить `python3 tools/automation/orchestrator.py run --manifest tools/automation/tasks.t161-collection.json --run-id t161-collection-20261109-01`; наблюдать реальные checks/Review/QA/publication. Live Supabase/AI/StoreKit и новая iOS-проверка этим этапом не выполнялись. T161/T155/T158 остаются открытыми до приёмки. Нельзя resume старые runs с новым config hash.

### T161: первый срез принят, SQL-кандидат восстановлен для независимой приёмки

Run `t161-collection-20261109-01`: `t161-atomic-collection-cap` **COMPLETED / Verified and published**, commit `b5f2c8f` отправлен в origin/main. Реальный универсальный table trigger ограничивает INSERT/restore/owner transfer Free=3, paid без cap; старые over-cap строки не удаляются. Tuple update owner profile предотвращает stale snapshot обход REPEATABLE READ/SERIALIZABLE; дата paid проверяется после lock по серверным часам. Проверки: clean/upgrade по 25 trusted + 35 developer pgTAP, четыре наблюдаемых owner-lock гонки (same retry/distinct create), 259 Deno и 115 automation fixtures, deno-check/diff PASS; 1 Developer/1 Reviewer/1 QA.

Второй срез вернул полный SQL/pgTAP-кандидат за 782.423s, но лишний пробел перед вторым `diff --git` привёл к отказу apply. Контроллер остановил повторную генерацию: run-01 SQL остаётся WAITING (2 Developer attempts, второй interrupted), backend PENDING. Исходные answer/state/logs не переписаны. В кандидатах `supabase/migrations/202611090004_retire_free_slots.sql` и `supabase/tests/free_care.test.sql` исправлено только оформление разделителя diff, побайтовое сравнение materialized файлов с добавленными строками исходного answer — PASS; содержимое CLI-патча неизменно. До commit принятия этого кандидата ещё нет.

**Реальные проверки кандидата:** `python3 tools/automation/t161_collection_gate.py --slots` — PASS: clean и seeded-upgrade по **131** pgTAP (25 cap trusted + 35 cap regression + 16 slots trusted + 55 care behavior), четыре настоящие owner-lock гонки, snapshot всех public rows при upgrade совпал. Только локальные PostgreSQL fixtures; live/API routing/guest перенос не принимались. Новая SQL использует актуальные receipt fields и убирает активные slot projections/selection; положительный guest/T164/клиент остаются отдельной работой.

**Точный следующий шаг:** сохранить checkpoint, затем `python3 tools/automation/orchestrator.py run --manifest tools/automation/tasks.t161-collection-recovery.json --run-id t161-collection-20261109-02`: read-only полная независимая приёмка SQL с повтором всех обязательных checks → TS/API срез. Новый recovery manifest содержит только две реальные зависимости; cap b5f2c8f проверен управляющим процессом. Старый run-01 не resume. После завершения — отдельный ограниченный T168 client estimator slice; полная T168 требует SQL/API guards. Product checkbox открыты.

## Оптимизация оркестратора — 2026-11-09

**Выполнено:** для `risk=low/complexity=low` включён путь Developer → все автоматические проверки (включая QA/UI) → одна независимая совмещённая Review/QA (`acceptance`). Остальные задачи сохраняют раздельную приёмку. Обычная приёмка — Sol с существующим разрешённым Flash fallback; высокий риск, `finding_complexity=high` или два отказа приёмки включают Astra/high route. Эскалация не сбрасывает бюджеты; no-progress guard сохранён. Для приёмки предусмотрено до трёх попыток, чтобы после повторных замечаний оставалась попытка эксперта. Scope/AC checks и актуальный fingerprint обязательны при публикации.

**Resume:** только для известной той же сессии/роли/модели передаются delta файлов с предыдущего вызова, изменённые результаты checks, summary и ошибки. Criteria/architecture/Project State не дублируются. Смена модели, compaction, lost session и неизвестный результат прерывания требуют полного контракта/диффа в новой сессии. Новый `finding_complexity` включён в полную JSON schema и connectivity smoke; чтение старых ответов сохранено.

**Расход:** `metrics` считает все фактические вызовы, повторы, fallback и непринятую работу на число COMPLETED задач; хранится история check runs. Ноль принятых задач, неизвестное время и неоднозначная область токенового счётчика дают `null`. `--compare-run-id` сопоставляет только одинаковые `quality_contract` (задача, scope/criteria/evidence modes, constraints, architecture и команды checks); выбор моделей/число ролей не меняет контракт. Старые records без контракта не объединяются для сравнения. Текущие CLI не гарантируют per-turn/cumulative scope: точный токеновый расход/денежная экономия не заявлены.

**Изменённые файлы:** `tools/automation/orchestration/{context,engine,provider,metrics}.py`, `tools/automation/{orchestrator.py,orchestrator.config.json,orchestrator_smoke.py,ORCHESTRATOR.md}`, `tools/automation/tests/test_orchestration_{context,engine,provider,metrics}.py`, этот handoff. `specs/001-plants-ios-mvp/tasks.md` не изменён: это инфраструктурный этап, продуктовые сценарии/checkbox им не принимаются.

**Реально запущенные проверки:** финальный `python3 -m unittest discover -s tools/automation/tests -q` — **115 tests PASS / OK** (fixtures, fake CLI, реальные subprocess checks и временные Git/bare origin). В том числе оба пути приёмки, repair до приёмки, обязательные UI/scope evidence, Sol→Astra/fallback, budgets/no-progress, delta-resume, crash recovery/commit/push, подсчёт всех попыток, unknown/cumulative counters и CLI сравнения. Программный `validate` всех **14** `tasks*.json` — PASS; `context --role acceptance` — PASS (полные criteria и новая schema instruction). `metrics --run-id t158-rooms-20261109-02` — PASS как read-only проекция существующего state: две COMPLETED задачи, неизвестный токеновый расход сохранён. `git diff --check` — PASS.

**Живые интеграции/ограничения:** новые вызовы Codex/Agy, backend/AI/БД, iOS/Simulator и реальная продуктовая очередь не запускались. Чтение старого state не является новой живой приёмкой. Экономия и одинаковое фактическое качество нового маршрута ещё не измерены; fixture PASS не доказывает их. Изменённый config требует нового run-id; старые незавершённые runs нельзя resume с новым config hash.

**Точный следующий шаг:** для замера подготовить две изолированные одинаковые исходные копии и одинаковый ограниченный scope/AC/checks: старый split (`combined_levels: []`) и новый combined, с новыми run-id; после приёмки обоих сравнить `metrics --run-id <split> --compare-run-id <combined>`, отдельно учитывая live/fixture режимы и unknown usage. Следующий продуктовый этап остаётся подготовкой manifest/gate T161 перед T158 collection cap; T155/T157–T160 и T161–T174 этим этапом не закрыты.

## Выполнено

- Определён простой уход: действия сейчас, основание/условие и следующая проверка; обычные повторы и один контроль первой помощи. OPEN-PLAN разрешён; T156 закрывает только документальное продуктовое решение.
- В необязательный v2 вынесены лечебные цепочки, AI-динамика, комнаты, дополнительные фотофункции, универсальный pipeline, расширенный сезонный UI и журнал пересчётов. [Полный список](../specs/001-plants-ios-mvp/deferred.md).
- Убраны обязательный экран намерений/pre-post-save, распределённый trial claim и отдельный durable analytics outbox. Локальный opt-in reminder и best-effort клиентские события; billing/квоты надёжны отдельно.
- Сохранены тарифы/два starter/Free=3/paid=100/регистрационный месяц, cap до трёх и прекращение автоматики после expiry; owner isolation, история, outbox и проверенная база.
- T155 разделена на T157–T160 для согласования схем/анализа, коллекции/доступа, guest/остатков и простого ухода. Ещё 9 задач сняты без отметки выполнения. Всего 137 активных: 13 отмечены (12 прежних + документальная T156), 124 открыты; 23 снятых ID отдельно. 60 действующих FR, 24 SC, 7 историй. Это не процент готовности продукта.
- Обновлены дизайн/ASO тексты. Старые PNG и генератор перемещены без изменения содержимого в [архив](../design/archive/aso-before-2026-11-09/README.md); новых проверенных изображений пока нет.
- Удалён исполняемый минимальный gate 300 видов из валидатора каталога; сохранены count/hash/ID/источники/SQLite проверки фактического выпуска, добавлен read-only `--check`. Манифест T148 больше не требует автоматически поставить editorial completed после правки regex.

## Изменённые файлы

- `.specify/memory/constitution.md`; `specs/001-plants-ios-mvp/{spec,user-flow,plan,data-model,research,knowledge-base-pipeline,tasks,quickstart,deferred}.md`; `contracts/{api,sync,README,revision-2026-11-08,revision-2026-11-09}.md`; оба checklist.
- `design/{design-concept,stitch-specification-en,stitch-specification-pl,stitch-prompt,stitch-prompt-pl,stitch-aso-screens-prompt,aso-store-content}.md`; `docs/stitch-ui-prompts.md`; `design/screenshots/README.md`; архив генератора/17 PNG и README в `design/archive/aso-before-2026-11-09/`.
- `docs/{infrastructure-preparation,plant-catalogue-skeleton,plant-database-sourcing}.md`; `research/prompts/gemini-argon-plant-data-deep-research-ru.md`; `docs/validation/{overengineering-review-2026-11-09,spec-simplification-2026-11-08,spec-simplification-2026-11-09}.md`.
- `knowledge-base/pipeline/validate_catalogue_skeleton.py`; `tools/automation/tasks.t148-pipeline.json`; этот handoff и его [исторический снимок](archive/handoff_status_before_simplification_2026-11-09.md).

## Проверки документального этапа (до runtime-очистки)

- `python3 -m unittest discover -s knowledge-base/tests -v` — **PASS, 27 тестов** на фикстурах/локальных данных; лог `/tmp/narat_simplification_kb_tests.log`.
- `python3 -m unittest tools.automation.tests.test_t148_catalogue_gate -v` — **PASS, 2 теста** (локальные изображения/константы, не редакционная приёмка).
- `python3 knowledge-base/pipeline/validate_catalogue_skeleton.py --check` — **PASS** на существующем выпуске; отчёт `/tmp/narat_catalogue_simplification_check.json`. Это проверка реальных локальных данных/источников/медиа/SQLite; редакционный статус остаётся not_completed. Проверка неизменности каталога — PASS; data/media/JSON/SQLite не менялись.
- `python3 /tmp/narat_scope_checks_20261109.py` — **PASS**: 60 FR/24 SC/7 US, полнота T001–T160 и трассировки, 137 активных/13 отмеченных/124 открытых/23 снятых, только T156 новая отметка, ссылки 34 действующих документов, 17 PNG + генератор в архиве побайтово совпадают с исходными; runtime/данные каталога не менялись. `--help` валидатора показывает `--check`; `git diff --check` и `git diff --cached --check` — **PASS**.
- Живые интеграции, app/SQL/AI/StoreKit/UI tests **не запускались**; бинарные ASO-изображения не редактировались и визуально не принимались.
- На момент документального этапа Swift/TypeScript/SQL runtime и машинные JSON Schema **ещё содержали старые механизмы**; последующие принятые runtime-срезы описаны ниже. Они явно отделены от цели в `contracts/README.md` и открытых T157–T160. T148/T155 не закрыты. Историческая T152 сохраняет только ранее проверенные границы отсутствия фиктивных успехов.
- Публичный eval требует до запуска конкретной выборки/достаточности T118; малые ранние прогоны не доказывают цели точности. EN/PL ASO — черновик до редакторской/визуальной приёмки и реализации.

## Очистка через оркестратор: первый срез принят

Run `t157-questions-20261109-01`, manifest `tools/automation/tasks.t157-cleanup.json`: **COMPLETED / Verified and published**, 1 Developer → 1 Reviewer → 1 QA, без повторных вызовов. Коммит `f15e6c6` создан контроллером и успешно отправлен в origin/main; state подтверждает публикацию. Подготовка manifest/gate/config была сохранена и отправлена коммитом `555a7a6`.

**Реализовано:** из `contracts/condition-profile.schema.json` удалены только required/property диагностического банка; из `KnowledgeTypes.ts` — ClarifyingQuestion, поле и semantic checks вопросов; обновлён `analysis_result_test.ts`. Новые карточки без банка проходят, поле в новой публикации отвергается schema, исторический extra field безопасно игнорируется semantic validator/resolver EN/PL. Остальные schema ограничения сохранены точным semantic hash gate. Данные/применённые SQL/Swift/деплой не затронуты.

**Проверки:** 39 Deno tests — PASS (fixtures, без skips); deno-check — PASS; точный `t157-question-contract` — PASS; whitespace — PASS; 89 automation tests — PASS (fixtures). Reviewer и QA подтвердили все критерии. Живой AI/БД/клиентский сценарий не проверялся. [Отчёт среза](validation/automation/tasks/t157-question-bank-cleanup.md), runtime state/logs — `docs/validation/automation/runs/orchestrator-t157-questions-20261109-01/` (исключены из Git).

**Ограничение:** принята только часть OLD-01/T157; follow_up, scores/routing, полный профиль/источники, treatment timeline, Swift DTO и прочие остатки T158–T160 ещё требуют очистки. T157 и T155 не закрыты; новые checkbox не добавлены. Успешный пилот подтверждает пригодность оркестратора для ограниченных срезов с точными файлами/проверками, а не автоматическую безопасность любой миграции.

## Последовательная очистка: follow_up принят

Run `t157-followup-20261109-01` — **COMPLETED / Verified and published**, коммит `a97ff20` отправлен контроллером в origin/main. Удалён новый follow_up/comparison из AI schema/provider/validator/access/API/worker; Swift active modes/квоты сокращены до identification/diagnosis. Исторический режим допускается только для чтения кеша/receipt, исходная подпись сохраняется. Legacy queued job завершает finalizeOnce до provider/budget, не создаёт ложного успеха. Контрольные фото и история сохранены.

Проверки: **45 Deno tests PASS**, deno-check/точный structural gate/whitespace PASS; **89 automation tests PASS**; iOS build/welcome/PlantsTests PASS без skips и Simulator smoke PASS. Reviewer/QA подтвердили все AC, по одному вызову каждой роли, без repairs. [Отчёт](validation/automation/tasks/t157-followup-cleanup.md). Это fixtures и local Simulator, живые AI/DB и forward migration не проверены; старые SQL mode/RPC остаются следующей migration-работой.

Очередь `tasks.t157-rules.json`, run `t157-rules-20261109-01` — обе задачи **COMPLETED**, без repair: score routing/DTO — коммит `31a465f`, manual evidence — `e2a446d`, оба опубликованы контроллером. В resolver нет confidence/gap routing/decision override и выдуманных fallback действий; неоднозначность не выбирает лечение, исторические подписи сохраняются. Из Swift удалены неиспользуемые question/decision DTO. Обе profile schema принимают одну source запись и manual_review без выдуманных synthesis metadata; происхождение/права/field evidence/проверка обязательны.

Проверки score-среза: 50 Deno tests PASS, iOS build/welcome/unit и Simulator smoke PASS, gates/static/89 automation tests PASS; evidence-среза — **104 Deno tests PASS**, точный hash gate/статические проверки/89 automation tests PASS. Reviewer/QA подтвердили AC каждого среза. Это fixtures/local Simulator, не live AI/DB. Отчёты: `docs/validation/automation/tasks/t157-{score-routing,manual-evidence}-cleanup.md`. T157/T155 остаются открыты: обязательный полный профиль/timeline и прочие SQL/collection/report остатки ещё не согласованы.

### База для следующих SQL-срезов

Docker/Podman недоступны; CLI Supabase status не может поднять контейнеры. Альтернатива проверена в собственной временной Unix-socket БД: **PostgreSQL 17.11 + настоящий pgTAP 1.3** (cached upstream `/private/tmp/pgtap-1.3.4/sql/pgtap.sql`). Системный PATH по умолчанию указывает на PostgreSQL14, использовать явный `/opt/homebrew/opt/postgresql@17/bin/`.

Изолированный baseline `/tmp/narat_sql_baseline.py` — PASS: **21 неизменённая миграция, 235/235 pgTAP, 1212 EN/PL SQL/TS проекций и реальные mutex/race сценарии каталога**. Логи: `/var/folders/_7/qq9rxkm91sb087_l46fjnbj00000gn/T/narat-cleanup-sql-baseline-59321aki/`. Первая попытка baseline остановилась на пустом PGSERVICE во временном окружении; после удаления inherited PG* выполнена заново успешно. Обе временные БД/кластеры остановлены и удалены; production/staging не использовались. Это не тест новой миграции.

### SQL mode guard принят

Run `t157-sql-mode-20261109-01` — **COMPLETED / Verified and published**, коммит `bd481a9` отправлен контроллером в origin/main. Новая `supabase/migrations/202611090001_analysis_mode_guard.sql` меняет ровно whitelist/obsolete paid-only branch в `admit_analysis_quota`. Новые follow_up/plan/unknown/NULL отвергаются до расхода; применённые 21 миграция, старые mode CHECK и таблицы истории не переписаны. Правила месячных периодов/Free legacy в RPC этим срезом не принимаются — они остаются для T158/T030.

**Проверки:** clean PostgreSQL17 — 50 настоящих pgTAP assertions PASS; seeded upgrade — 50 PASS, сравнение всех public table rows до/после PASS; проверен реальный prosrc admission после seed, без подмены функции. Deno **104 tests PASS**, deno-check/whitespace и 89 automation tests PASS; Reviewer и QA приняли все AC, без repairs. [Отчёт](validation/automation/tasks/t157-sql-mode-guard.md). Это изолированные fixtures/auth stubs; миграция не применялась к staging/production, live Supabase/AI не проверялись.

**Изменённые файлы этого этапа:** schema/backend/iOS/test файлы перечислены в четырёх отчётах controller: `t157-followup-cleanup`, `t157-score-routing-cleanup`, `t157-manual-evidence-cleanup`, `t157-sql-mode-guard`. Новые SQL seed/test: `supabase/tests/analysis_mode_upgrade.seed.sql`, `analysis_mode_guard.test.sql`. Подготовка и независимые gates/manifests: `tools/automation/tasks.t157-{followup,rules,sql-mode}.json`, `t157_{followup,score,evidence,sql_mode}_gate.py`, config. Этот handoff, `contracts/README.md` и заметка T157 в tasks обновлены управляющим процессом; runtime логи исключены из Git.

**Итог последовательности:** a97ff20 → 31a465f → e2a446d → bd481a9, все COMPLETED и опубликованы. T157/T155 и T158–T160 остаются открыты: обязательный полный профиль/timeline, новая collection/quota/expiry модель, report/product/guest остатки и простой уход ещё не завершены. Число checkbox не менялось; приёмка срезов не равна готовности пользовательского фото→уход сценария.

## Компактные профили приняты

Подготовка `bd929b1`: `contracts/compact-profiles.md`, manifest `tasks.t157-compact-profiles.json`, gate `t157_compact_profile_gate.py`, config. Condition2 содержит независимые действия/first_help_action_id/nullable следующую проверку вместо фаз/повторов; Plant2 — действия или safety-факт вместо полного care_algorithm_params/taxonomy/рецепта. Права/происхождение/ручная проверка/EN-PL сохранены. Срок 1..90 — прежняя техническая граница, не универсальный таймер.

Run `t157-compact-20261109-01` остановился без применения: copy100% metadata первого ответа не поддерживается, второй Developer истёк по timeout900с. T1 WAITING, T2 PENDING — этот запуск не принят. Управляющий процесс побайтово сохранил обе v1 схемы в `contracts/legacy/`, сверил SHA и нормализовал только copy-header готового candidate; остальные 6 schema/TS/test файлов применены после git apply --check/numstat. Checkpoint `adf7130`: 109 Deno PASS, condition gate PASS, независимая приёмка ещё ожидалась.

Восстановительный manifest `tasks.t157-compact-recovery.json`, run `t157-compact-20261109-02` — **COMPLETED / Verified and published**. Read-only Review/QA полного Condition2 кода приняты в `e7d2d7b`; зависимый Plant2 в `eb40f28`. По одному Reviewer/QA на задачу, Plant2 — один Developer; repairs не потребовались. Все коммиты отправлены в origin/main.

**Изменённые файлы:** `contracts/{condition-profile.schema.json,plant-profile.schema.json,legacy/*.v1.schema.json,compact-profiles.md}`; `KnowledgeTypes.ts`, `ProtocolResolver.ts`, `AnalysisValidator.ts`; `analysis_result_test.ts`, `profile_evidence_test.ts`; gates/manifests/config, отчёты и handoff. Новый формат валидируется до обращения к полям; v1/повреждённый профиль не исполняется как новый совет; first-help выбирается только по явной ссылке с проверкой условий, без fallback. Исторические данные/подписи/SQL/Swift этим срезом не переписывались.

**Реально выполненные проверки:** Condition2 — 109 Deno tests PASS; итог Plant2 — **257 Deno tests PASS**, deno-check, оба точных schema gate, diff-check и 89 automation tests PASS. Это synthetic fixtures/local static, не агрономическая приёмка, не live provider/БД. Отчёты: [Condition2](validation/automation/tasks/t157-compact-condition-profile.md), [Plant2](validation/automation/tasks/t157-compact-plant-profile.md). T157/T155 не закрыты; checkbox не менялись.

## Удаление старых Swift DTO принято

Run `t157-swift-profiles-20261109-01`, manifest `tasks.t157-swift-profiles.json` — **COMPLETED / Verified and published**, коммит `93d77bc` отправлен в origin/main. Один Developer → один Reviewer → один QA, без repairs. Из `ios/Plants/Data/Remote/APIModels.swift` удалены только `RecoveryCheckDTO`, `TreatmentStepDTO`, `ConditionProfileDTO` и пустой устаревший MARK: 104 строки. Внешних consumers нет; остальные сериализуемые поля, история, outbox и локальные данные сохранены.

**Реально выполненные проверки:** точный `t157_swift_profile_gate.py` и diff-check PASS; 89 automation tests PASS (fixtures); iOS build/welcome UI PASS, **27 PlantsTests PASS, 0 skipped**; Simulator smoke welcome/care-navigation PASS (local UI). Reviewer/QA приняли оба AC. Это не live Supabase/AI/StoreKit и не полный фото→уход маршрут. [Отчёт](validation/automation/tasks/t157-unused-swift-profile-dto.md).

**Файлы подготовки/фиксации:** `tools/automation/{tasks.t157-swift-profiles.json,t157_swift_profile_gate.py,orchestrator.config.json}`; `contracts/README.md`, `tasks.md`, этот handoff и отчёт контроллера. Подготовка `8dac563` опубликована; финальная сводка сохраняется отдельным commit/push. T157/T155 открыты, продуктовые checkbox не менялись.

## Подготовка T158: комнаты (история этапа)

Прослежены зависимости: room CRUD SQL, plant.create, guest prepare/commit, owner_sync_entries, TS/Swift claim overrides. Подготовлены `contracts/room-retirement.md`, `tools/automation/tasks.t158-rooms.json` (SQL → клиент), `t158_rooms_gate.py` и config check. Таблицы/связи/исторические receipts сохраняются, новые room inputs явно отвергаются; sync плоский. Free slots/collection cap/квоты/expiry — отдельные следующие срезы.

Обнаружен реальный baseline gap: старый guest-claim SQL/API несовместим с текущими таблицами/RPC (state/claim_secret_hash/owner_id/proof_expires_at и параметры API). Полный положительный claim не принимался и этим срезом не чинится; T159/T042/T019 требуют отдельного восстановления proof/TTL/media/cleanup. Существующие generic cache/outbox данные не сбрасываются.

`--print-migration` gate выводит согласованный room-only SQL; исходные функции извлекаются из неизменённых migrations, не переписываются вручную. Целевые SQL/Deno/iOS tests ещё не выполнены. После validate и сохранения чистого Git запустить run `t158-rooms-20261109-01`.

### Восстановление очереди комнат

Run `t158-rooms-20261109-01`: Developer CLI завершился timeout900с без answer/патча; SQL task WAITING, клиент PENDING. Runtime/данные этим вызовом не менялись, приёмки нет. Исходные state/logs сохранены, запуск не переписан.

Управляющий процесс материализовал `202611090002_retire_rooms.sql` точно через `t158_rooms_gate.py --print-migration` и подготовил `rooms_upgrade.seed.sql`/`rooms_retirement.test.sql`: реальные два owner/legacy rooms/plant links/photo/snapshot/расход/receipts и 66 pgTAP assertions. **PASS**: clean PostgreSQL17 — 66; seeded upgrade — 66, snapshot всех public rows до/после совпал; два реальных concurrent retries дождались owner lock, по одному plant/receipt. Все временные кластеры удалены. Первая sandbox-попытка initdb не смогла создать shared memory; повтор с разрешением системного запуска прошёл. Это локальные fixtures, не live deployment и не полный guest claim.

На checkpoint fbd7e18 кандидат ожидал независимых Review/QA. Новый `tasks.t158-rooms-recovery.json`, run `t158-rooms-20261109-02`: read-only полнотекстовая SQL приёмка с повторными trusted checks → затем исходный клиентский срез. Продуктовые checkbox не менялись. После сохранения чистого Git запустить эту очередь; при finding исправление только отдельным проверяемым шагом.

## T158: комнаты удалены из активного контракта

Run `t158-rooms-20261109-02` — обе задачи **COMPLETED / Verified and published**. SQL принят `b80a74e` (read-only полный Review/QA кандидата); клиент принят `0d8d4ee`. Все коммиты отправлены в origin/main. По одному Reviewer/QA на задачу. Клиент: первый diff не применился из-за формата, второй Developer пересобрал его; только после этого проверки/приёмка. Исходный run-01 остаётся WAITING по timeout, не объявляется завершённым.

**Реализовано:** новые room CRUD и room-поля отвергаются; существующий точный receipt возвращается без нового room side effect. В plant.create/guest SQL удалены комнатные insert/link/response; в sync нет rooms/plant.room_id. TS/Swift claim writers не содержат комнат. HTTP prepare отклоняет room aliases до RPC без мутации; Swift читает старый JSON из SwiftData, сохраняет прочие поля и при повторной записи не возвращает room keys. Таблицы/старые связи/фото/расход/receipts/generic cache/outbox сохранены.

**Изменённые файлы:** `supabase/migrations/202611090002_retire_rooms.sql`; `supabase/tests/{rooms_upgrade.seed.sql,rooms_retirement.test.sql}`; `supabase/functions/plants-api/claims.ts`, `_shared/tests/claim_transfer_test.ts`; `ios/Plants/Data/Remote/APIModels.swift`, `ios/PlantsTests/SyncPersistenceTests.swift`; `tools/automation/{t158_rooms_gate.py,tasks.t158-rooms.json,tasks.t158-rooms-recovery.json,orchestrator.config.json}`; `contracts/{room-retirement.md,README.md}`, `tasks.md`, этот handoff и два отчёта контроллера. Применённые SQL не изменены.

**Реальные проверки:** clean PostgreSQL17 — **66 pgTAP PASS**, seeded upgrade — **66 PASS**, snapshot всех public rows до/после совпал. Два настоящих concurrent retry дождались owner lock, по одному plant/receipt; RLS A/B, pagination, media metadata и private-key exclusion проверены. SQL-срез: 257 Deno/89 automation tests PASS; итог клиента: **259 Deno PASS**, deno-check/diff-check PASS; iOS build/welcome PASS, **28 PlantsTests PASS, 0 skipped**, Simulator smoke welcome/care-navigation PASS. [SQL отчёт](validation/automation/tasks/t158-room-sql-retirement.md), [клиент](validation/automation/tasks/t158-room-client-retirement.md).

**Документальные проверки финальной сводки:** локальные ссылки обновлённых документов PASS; diff-check PASS; tasks сохраняет 13 отмеченных и 124 открытых. Git diff к началу этапа показывает в migrations только новый room SQL, без изменений применённых файлов.

**Ограничения:** это изолированные fixtures/auth stubs и local UI, без live Supabase/AI/StoreKit; новая миграция не применялась к staging/production. Старый положительный guest claim несовместим с таблицами/API и не принят — T159/T042/T019. Старый `supabase/tests/guest_claim.test.sql` содержит снятые room/fallback assertions и baseline gaps: не использовался для текущей приёмки, должен быть переписан вместе с T159, без удаления покрытия proof/media/receipts. Исторические generic room sync/outbox tests намеренно сохранены для чтения прежних данных. Free slots/новый collection cap/периоды/expiry ещё не менялись. T158/T155 и продуктовые checkbox остаются открытыми.

## Повторная инвентаризация остатков — 9 ноября 2026

Проверен текущий код на HEAD `1290028` против принятого решения `validation/spec-simplification-2026-11-09.md`, deferred и T157–T160. Это статический аудит, не новый runtime-срез. Изменён только этот handoff; задачи не закрывались.

**Что ещё убрать или заменить:**

1. **Free-места и автоматический выбор трёх:** `BasicCareService.ts:18–45`, `EntitlementGate.ts:189–215`, `plants-api/basic-care.ts`, Swift `FreeSelection`/`freeSlot` и текущая SQL sync-проекция. Заменить ограничением добавления в коллекцию, отдельно остановить всю автоматику после paid expiry (T158).
2. **Старые месячные правила:** актуальная `202611090001_analysis_mode_guard.sql:208–232` всё ещё задаёт Free=1, UTC-календарный месяц и начало после месяца первого starter success. Требуется Free=3/paid=100 с периодом от регистрации и сохранением расхода при смене тарифа (T158/T030). Это замена бизнес-правил, а не удаление квот.
3. **Месячные отчёты и распределённые claims уведомлений:** `notifications.ts:17`, реально подключённый маршрут `index.ts:160`, `ProgressReportDTO`/`monthlyReportOptIn`, `SyncEngine.swift:85,255–276`, SQL RPC и `notification_claim_summaries` в последней sync-проекции. Оставить локальное opt-in trial-напоминание по подтверждённой дате (T159).
4. **Восстановление удалённого guest через local_fallback:** ветка остаётся даже в последнем определении plant.create — `202611090002_retire_rooms.sql:94,192,260`. Одновременно восстановить совместимый положительный claim, семь дней/proof/media/cleanup и переписать старые SQL tests. `analysis_receipt` пока имеет consumers (`ProtocolResolver.ts`, `claims.ts:179`, Swift); удаление подписи допустимо только вместе с заменой этих consumers. Operation receipts и claim proof сохраняются (T159).
5. **Товарный таймер:** `chemicalMustRevalidateAfter` исполняется в `EntitlementGate.ts:148–177`, `SyncEngine.swift:49` и SQL `can_owner_schedule_rule`. Таблицы `product_evidence`/`treatment_blocks` остаются в схеме; их сохранение само по себе не доказывает работающий магазин. Снять активную товарную зависимость, сохранив применимость рекомендаций/веществ и исторические данные (T159).
6. **Камера света:** `PlantTypes.swift:36,178–191`, writer `AnalysisFlowModel.applyEstimatedLighting:44`, `claims.ts:10`. Убрать новый ввод/контракты/старые положительные tests, сохранив чтение прежней оценки без превращения её в ручной ответ (OLD-02/T155).
7. **Прежний путь добавления:** `PlantsApp.swift:45,64–104` реально показывает выбор намерения; `PlantTypes.swift:108–118` и `AddPlantRouter.swift:82–87` сохраняют diagnosticRefinement/preSaveReview/postSaveNextStep. Заменить входом «Проверить растение» и единым результатом с сохранением. Pre/post-save обнаружены как состояния/переходы, а не как подтверждённые отдельные работающие экраны (OE-13 и связанные UI-задачи).
8. **Сезонные overrides и старые зависимости ухода:** поля ещё передаются через Swift, API/provider context, claim и последнюю SQL sync-проекцию. Согласовать с простыми действиями/следующей проверкой (T160). Старые phase/repeat_count в схеме не являются доказательством готового лечебного движка; обычные повторы, один контроль первой помощи, журнал и undo остаются.

**Уже очищено по ранее принятым срезам:** комнаты в активных командах/контрактах; question-bank и score routing; новый AI follow_up; обязательные полные профили/timeline; три неиспользуемых Swift DTO; gate минимальных 300 видов. Новая проверка не переаттестовывает прежние результаты. Legacy schemas/применённые миграции/история/регрессионные fixtures не подлежат механическому удалению. Отдельного durable analytics/funnel outbox в просмотренных runtime-каталогах поиском не обнаружено; общий sync/outbox сохраняется.

**Реально выполнено:** чтение решений/handoff/tasks, `git log`, `git status`, поиск `rg` и просмотр Swift/TS/SQL consumers, сопоставление последних переопределений SQL. Сборка, fixture-тесты и живые интеграции не запускались; состояние развёрнутой БД не проверялось. Следующий шаг остаётся T158 Free-места → атомарный collection cap; затем периоды/expiry, T159 и T160/UI. Приоритет и открытые checkbox в tasks не менялись. `git diff --check` — PASS. Публикация этого документа фиксируется результатом commit/push текущего этапа.

## Подготовлены пакеты T161–T174 — 9 ноября 2026

По поручению владельца созданы 11 задач очистки T161–T171 и 3 задачи отдельного возврата простых комнат T172–T174. Найдено исходное обсуждение в чате «Проверить спецификацию на оверинжиниринг»: комнаты как название/список растений/фильтр. Минимальные технические решения (необязательное назначение после сохранения, delete без удаления растений, отсутствие влияния на уход) явно записаны в новом контракте как проектные решения.

**Файлы:** `specs/001-plants-ios-mvp/{tasks,orchestrator-cleanup-tasks,deferred}.md`, `contracts/{simple-rooms,README}.md`, этот handoff. В tasks — зависимости, связь с родительскими задачами и трассировка FR/SC; в пакетах — scope/AC/требуемые fixtures/local/live проверки. 151 задача: 13 отмечены, 138 открыты; T172–T174 — три необязательных задачи вне обязательного MVP. Прежние 23 снятых ID сохранены; новых выполненных checkbox нет.

**Проверки подготовки:** Python-проверка tasks/пакетов — PASS: 151 уникальный ID, 13 прежних выполненных/138 открытых, все 14 новых пакетов присутствуют, граф их зависимостей без циклов, локальные Markdown-ссылки всех шести изменённых/новых файлов существуют. `git diff --check` — PASS. Проверки только документов, без моделей и runtime tests.

**Ограничения:** это задания для подготовки отдельных запусков, не исполняемые JSON manifests. Новые SQL/UI gates ещё не созданы; их нельзя подменить существующим Deno или старым room-retirement gate. Перед каждым run контроллер материализует точный manifest, исполняемые checks и обновляет нужные smoke expectations; gate/config/handoff/tasks защищены от agent patch. Реализация, модели оркестратора, сборка, SQL/fixture suites и live integrations в этом этапе не запускались. Общий sync/outbox и runtime не менялись. Комнаты отдельны от обязательного MVP, текущий запрет room inputs остаётся до нового принятого перехода.

**Точный следующий шаг:** подготовить manifest и PostgreSQL clean/upgrade/concurrency gate T161 (Free-места → collection cap), выполнить validate/context, сохранить подготовку и только затем запускать отдельный run. После T161 — T162/T163/T164. Комнаты идут отдельной очередью T172→T173→T174 с указанными предпосылками. Оркестратор по текущему поручению не запущен.

## Точный следующий шаг

Следующий этап — два независимых Worktree-чата по [плану A/B](parallel/README.md): A начинает с canonical sync DTO/transport, затем engine/disk checkpoints и catalogue save; B — с T163 registration anchor/квот, upgrade/concurrency и API mapping. Server cap/slots T161, auth/profile, HTTP adapters и typed create receipt уже приняты; не повторять их и не возобновлять большой timeout sync manifest. Пока принятые client prerequisites не подключены к outbox/UI, сохранение не готово. Полные T162/T163/T149 и T155 остаются открытыми до своих gates; окончательные изменения объединяет A между runs.

T157 остаётся частичной: новые карточки требуют редакционной публикации и итоговой интеграции. T159 восстановит guest proof/семь дней/cleanup/media и заменит устаревшие assertions; T160 — простой уход. Текущие fixtures не подтверждают live фото→уход маршрут.

T148 остаётся на прежней остановке до запуска следующего pipeline-среза; фактические дефекты имён/переводов/медиа перечислены в обновлённом `tools/automation/tasks.t148-pipeline.json` и [архиве handoff](archive/handoff_status_before_simplification_2026-11-09.md). Полная редакционная приёмка отдельна; минимум охвата снят, сохранность 606 карточек проверяется.

**Git:** основной коммит `905d71e` (`docs: apply approved MVP simplification and align delivery scope`) создан и успешно отправлен в `origin/main`, push exit 0. Staged whitespace check — PASS; 17 PNG и генератор распознаны Git как переносы 100%. Эта запись подтверждённой публикации сохраняется отдельным документационным коммитом.

<!-- orchestrator:project-state -->
## Project State

- Narat: Swift 6/SwiftUI/SwiftData, Supabase, StoreKit 2, EN/PL; конституция 5.0.0.
- Scope принят 9 ноября: простой путь и уход, OPEN-PLAN разрешён; документы не подтверждают runtime.
- 151 задача: 14 отмечены (12 исторических + T156 документ + T161 серверный пакет), 137 открыты; 23 снятых. Из открытых T172–T174 — отдельные необязательные комнаты; пакеты T161–T174 описаны в orchestrator-cleanup-tasks.md, T161 принят по серверному контракту: cap b5f2c8f, slots 01ba170, TS/API eb58c03; fixtures PostgreSQL/Deno, live/client отдельно. Остальные manifests/gates готовятся перед запуском. T155/T157–T160 открыты; T148 остановлена перед pipeline slice.
- Runtime AI классифицирует, советы из проверенных карточек. Sync/outbox, история/приватность/покупки сохранены. Free collection cap=3 и no-slot basic care приняты на сервере; месячные квоты и полный expiry ещё не заменены.
- T157 question-bank f15e6c6 и follow_up a97ff20 опубликованы (COMPLETED). Score/DTO 31a465f и evidence e2a446d опубликованы. SQL mode guard bd481a9 опубликован: clean/upgrade по 50 pgTAP PASS, history unchanged. Компактные Condition2/Plant2 e7d2d7b/eb40f28 опубликованы: 257 Deno PASS. Три неиспользуемые Swift DTO удалены в 93d77bc: 27 PlantsTests/build/welcome/Simulator PASS. Rooms run-02 COMPLETED: SQL b80a74e и клиент 0d8d4ee опубликованы; clean/upgrade по 66 pgTAP + real owner-lock retry, 259 Deno, 28 PlantsTests/build/welcome/Simulator PASS. Run-01 WAITING по timeout без patch сохранён. Серверная T161 принята; следующий клиентский пакет T162, квоты T163 и полный expiry T164 отдельно. T168 client estimator slice dadfcb1 принят (29 PlantsTests/build/Simulator, Sol combined); full T168 server/API guards остаются открыты. PostgreSQL17/pgTAP доступен. Guest claim baseline несовместим с таблицами/API: не объявлять положительный перенос проверенным, исправление T159. Остальная T157/T158–T160 открыта; T148 независима. Применённые миграции не переписывать.
- Оркестратор: простые low/low задачи проходят все checks и одну совмещённую Review/QA на Sol; высокий риск/сложные или повторные замечания — Astra. Resume известной сессии передаёт delta/errors; свежая сессия — полный контракт. Metrics включает все повторы на COMPLETED и сравнивает только одинаковый quality_contract. 115 automation fixtures PASS; live CLI cap/SQL Astra split, TS Sol split и T168 Sol combined приняты, экономика одинакового контракта не измерена. Для нового config нужен новый run-id.
- Auth/profile 9551807, production sync c26a4e0/catalogue create 88345ed и typed receipt e8a12fe приняты. Receipt — 35 реально выполненных PlantsTests; sync wire/engine остаётся timeout без patch. UI save/outbox/live не готовы.
- Владелец поручил подготовить два оркестратора: docs/parallel/README.md, session-ios.md (A=59 ID) и session-backend.md (B=78 ID), allocation.json покрывает все 137 открытых ID. Задания подготовлены, worktree/чаты/модели ещё не запущены. A: клиент T162 wire→disk→save и интегратор; B: T163 quota SQL/API→guest/контракты. Свои ветки/publish config обязательны; общий Simulator только A. T172–T174 не входят в текущий запуск.
- Handoff/tasks/Git изменяет только управляющий процесс; в параллельных worktree каждый controller обновляет собственный handoff, A объединяет факты и итоговые tasks. Fixtures ≠ live; снятый объём не выполнение. Задания A/B разрешают существующий Developer/Reviewer/QA workflow; дополнительные деревья субагентов на старте не запускаются.
<!-- /orchestrator:project-state -->

<!-- orchestrator:task-summary -->
## Task Summary

parallel-backend-t163-registration-ledger-v2: проверки и Review/QA пройдены; публикация фиксируется в state.
Отчёт: [parallel-backend-t163-registration-ledger-v2](validation/automation/tasks/parallel-backend-t163-registration-ledger-v2.md).
Продуктовые checkbox не менялись автоматически. Следующий шаг — следующая независимая задача manifest.
<!-- /orchestrator:task-summary -->

Recovery negative control `--baseline --anchors` повторён: ожидаемый exit1 на старом Free1/calendar, `/tmp/narat-b163-baseline-v2.log`; это не продуктовый PASS.
