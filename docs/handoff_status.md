# Narat — текущий статус и передача работы

**Обновлено 2026-11-09.** Принят и опубликован room-срез T158: SQL room retirement/плоский sync и TS/Swift overrides без комнат. Ранее приняты компактные Condition2/Plant2 и удаление трёх неиспользуемых Swift DTO. Точная приёмка и оставшаяся работа — ниже. Владелец принял рекомендации аудита. Спецификация и связанные действующие документы приведены к пути **распознавание → диагностика → рекомендации → уход**. Конституция 5.0.0. Документальное сокращение scope завершено; принятые runtime-срезы и ограничения перечислены ниже.

**Workspace:** `/Users/ruslansabirov/Documents/ChatGPT/Plants`, ветка `main`.
**Источники:** [spec](../specs/001-plants-ios-mvp/spec.md), [tasks](../specs/001-plants-ios-mvp/tasks.md), [решения](validation/spec-simplification-2026-11-09.md), [аудит и карта зависимостей](validation/overengineering-review-2026-11-09.md).

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

Следующий ограниченный manifest **T158: убрать Free-места и free_care.select, заменить их атомарным collection count<3 для Free / unlimited для действующего paid**. Проследить `BasicCareService.ts`, `EntitlementGate.ts`, SQL basic_care/compute_next_available_step/schedule/create writers, sync/profile projections и Swift FreeSelection/membership DTO. Исторические memberships/flags/расход не удалять. Согласовать все writers и owner-lock admission; clean/upgrade + concurrent/retry/A-B, Deno и iOS обязательны. Автоматический выбор трёх после paid expiry не возвращать; остановка ухода после expiry и месячные периоды — отдельные согласованные срезы T158. Не закрывать parent по одному RPC/build.

T157 остаётся частичной: новые карточки требуют редакционной публикации и итоговой интеграции. T159 восстановит guest proof/семь дней/cleanup/media и заменит устаревшие assertions; T160 — простой уход. Текущие fixtures не подтверждают live фото→уход маршрут.

T148 остаётся на прежней остановке до запуска следующего pipeline-среза; фактические дефекты имён/переводов/медиа перечислены в обновлённом `tools/automation/tasks.t148-pipeline.json` и [архиве handoff](archive/handoff_status_before_simplification_2026-11-09.md). Полная редакционная приёмка отдельна; минимум охвата снят, сохранность 606 карточек проверяется.

**Git:** основной коммит `905d71e` (`docs: apply approved MVP simplification and align delivery scope`) создан и успешно отправлен в `origin/main`, push exit 0. Staged whitespace check — PASS; 17 PNG и генератор распознаны Git как переносы 100%. Эта запись подтверждённой публикации сохраняется отдельным документационным коммитом.

<!-- orchestrator:project-state -->
## Project State

- Narat: Swift 6/SwiftUI/SwiftData, Supabase, StoreKit 2, EN/PL; конституция 5.0.0.
- Scope принят 9 ноября: простой путь и уход, OPEN-PLAN разрешён; документы не подтверждают runtime.
- 151 задача: 13 отмечены (12 исторических + T156 документ), 138 открыты; 23 снятых. Из открытых T172–T174 — отдельные необязательные комнаты; пакеты T161–T174 описаны в orchestrator-cleanup-tasks.md, executable manifests/gates готовятся перед запуском. T155/T157–T160 открыты; T148 остановлена перед pipeline slice.
- Runtime AI классифицирует, советы из проверенных карточек. Sync/outbox, история/приватность/покупки сохранены. Тарифы/expiry не изменены.
- T157 question-bank f15e6c6 и follow_up a97ff20 опубликованы (COMPLETED). Score/DTO 31a465f и evidence e2a446d опубликованы. SQL mode guard bd481a9 опубликован: clean/upgrade по 50 pgTAP PASS, history unchanged. Компактные Condition2/Plant2 e7d2d7b/eb40f28 опубликованы: 257 Deno PASS. Три неиспользуемые Swift DTO удалены в 93d77bc: 27 PlantsTests/build/welcome/Simulator PASS. Rooms run-02 COMPLETED: SQL b80a74e и клиент 0d8d4ee опубликованы; clean/upgrade по 66 pgTAP + real owner-lock retry, 259 Deno, 28 PlantsTests/build/welcome/Simulator PASS. Run-01 WAITING по timeout без patch сохранён. Следующий срез T158 — убрать Free slots/free_care.select и атомарно ограничить коллекцию count<3 для Free; месячные периоды/expiry отдельно. PostgreSQL17/pgTAP доступен. Guest claim baseline несовместим с таблицами/API: не объявлять положительный перенос проверенным, исправление T159. Остальная T157/T158–T160 открыта; T148 независима. Применённые миграции не переписывать.
- Handoff/tasks/Git изменяет только управляющий процесс. Fixtures ≠ live; снятый объём не выполнение. Субагенты не запускаются без отдельного разрешения.
<!-- /orchestrator:project-state -->

<!-- orchestrator:task-summary -->
## Task Summary

t158-room-client-retirement: проверки и Review/QA пройдены; публикация фиксируется в state.
Отчёт: [t158-room-client-retirement](validation/automation/tasks/t158-room-client-retirement.md).
Продуктовые checkbox не менялись автоматически. Следующий шаг — T158 Free-места и атомарный лимит коллекции.
<!-- /orchestrator:task-summary -->
