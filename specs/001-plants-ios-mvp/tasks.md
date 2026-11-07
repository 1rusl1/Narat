# Tasks: Narat — iOS MVP, PL/EN

> **Синхронизация 2026-11-01:** технический дизайн приведён к спецификации Narat
> от 2026-10-30 и конституции 3.0.0: 68 FR, 25 SC, 9 историй.
> Актуальный статус пересмотрен 2026-11-07. Части реализации и тестовый стенд работают; готовность пользовательских сценариев фиксируется отдельно.

**Date**: 2026-11-01 · **Branch**: `main` · **Logical feature**: `001-plants-ios-mvp`
**Input**: `spec.md` (FR-001..068, SC-001..025, Clarifications включая 2026-10-30), `plan.md`, `research.md`, `data-model.md`, `contracts/{api.md,sync.md,ai-result.schema.json}`, `quickstart.md`, `knowledge-base-pipeline.md`, schemas PlantProfile/ConditionProfile/Classification 3.0.

Формат: `- [ ] Tnnn [P?] [USn?] действие + путь`.
Маркер `[P]` разрешает параллельное выполнение только после завершения общих prerequisites и в разных файлах. Общие миграции, `plants-api/index.ts` и `Localizable.xcstrings` обновляются последовательно.

## Порядок исполнения после сверки 2026-11-07

Основание — spec.md от 2026-11-06 и конституция 3.0.0. [Отчёт сверки](../../docs/validation/spec-plan-reconciliation-2026-11-07.md).
Статусы отражают полный объём задачи; наличие компонента или теста на фикстуре не закрывает интеграционную задачу.

1. T152 — безопасное поведение текущей тестовой сборки и API при отсутствующей интеграции. Это обязательное устранение нарушения, а не новый продуктовый этап.
2. T148 — редакционная приёмка 606 карточек, изображений, EN/PL и атрибуции; доказательства и отклонённые записи. Подготовку кода T149 можно вести на явно ограниченных тестовых данных, закрытие зависит от T148.
3. T149 — законченный каталог без полной KB. Включает нужные части T019/T024/T025/T041/T044–T048/T097: общий API, поиск/пагинация/кеш, постоянный вход, сохранение экземпляра без фото/опроса, server commit/retry, перезапуск и изоляция владельцев.
4. T150 — реальное фото и identification без обязательной полной care/condition KB; сначала T153 и части T015/T016/T030/T031/T033–T036/T042/T043/T101. Камера/галерея, исправление вида, личное фото, устойчивый черновик и сохранение.
5. T151 — приёмка каталога EN/PL на фикстурах и живом стенде/iPhone; T154 проверяет изменения среды и контур доступа перед расширением стенда.
6. После базового каталога — проверенные факты полива (T108–T115/T021), PlanService/ScheduleCalculator T055/T117 и Basic Care T129–T131. Свет и субстрат добавляются отдельными партиями согласно spec.md.
7. Отдельный поток данных — ConditionProfile/40 проблем/T120, затем законченный US1/T116/T121/T122/T125 и повторная диагностика без вопросов. T150 не ждёт полного выпуска диагностики.
8. Далее планы/подписки → ежедневный уход → дневник/правки → напоминания/профиль/контроль → отчёты/метрики → общая приёмка T092–T099/T146. Сохраняются все девять историй и критерии выпуска.

Personal Team позволяет тестировать гостевой каталог на устройстве. Для постоянного входа подготовить Google OAuth либо Apple Developer/Sign in with Apple в T097; тестовая подпись не подтверждает native OAuth или покупки.
Существующие компоненты и результаты сохраняются. Переоткрытые задачи перечислены в отчёте; остальные отметки не являются повторной полной сертификацией.

## Ближайший этап 2026-11-04 — базовый каталог (T147–T151)

Основание и критерии: [базовый каталог](../../docs/plant-catalogue-skeleton.md).
База из 606 видов собрана. Ближайшая работа с содержанием — редакционная приёмка и отдельный учёт проверенных фактов ухода по FR-052/053/056.
Сначала получение данных T148; изменение контрактов T147 не блокирует локальный импорт.
Эти задачи выполняются до продолжения полного care/diagnosis pipeline. Они не требуют
заполнения всех тем ухода и подготовки 40 протоколов. Старые задачи сохраняют ID и статус; их полный объём
не считается выполненным после реализации только базового среза.

- [X] T147 Согласовать модель и контракты базового каталога в `data-model.md`, `contracts/api.md` и `knowledge-base-pipeline.md`; реализовать независимую от полной KB публикацию в `supabase/migrations/`, поля описания/названий и связь вида с экземпляром. Проверить миграцию и чтение каталога без care/condition release.
> T147 закрыта 2026-11-06. Исправлены оба дефекта активации. Проверены обновление ранее повреждённого каталога, запрет поддельных триггеров и переключение через status в обоих направлениях. На PostgreSQL 17.11 прошли 18 миграций, 235/235 pgTAP и три конкурентных сценария. Для 606 видов совпали 1212 SQL/TS-карточек EN/PL. [Сводка прогона](../../docs/validation/t147-activation-2026-11-06/summary.json).
- [ ] T148 Выбрать источники и массово выгрузить 300 разных видов в `catalogue/releases/skeleton-300-v1/`: научное имя, распространённые названия, одно основное фото, общее описание и происхождение/атрибуция. Реализовать повторяемый импорт в `knowledge-base/`, проверить реальные записи/медиа и offline-сборку без полного PlantProfile; отдельно измерить покрытие EN/PL и завершить редакционную проверку/локализацию до закрытия задачи. Локальная выгрузка не зависит от T147; подключение к приложению зависит.
> T148, факт 2026-11-05: каталог расширен со стартовых 300 до **606 видов** (включены 222 вида, ранее отсечённые лимитом 300, и 84 дополнительных популярных вида из Plantfolio/монотипных родов): 606 записей/изображений, **606 EN-описаний** и **606 PL-описаний** (`190` оригинальных статей польской Wikipedia + `416` переводов вступлений английской Wikipedia по лицензии CC BY-SA 4.0 с сохранением `source_revision` и атрибуции); распространённые названия у **407 EN / 430 PL**; добавлено поле `watering` из Plantfolio для всех 606 видов (`278` точный вид, `16` синоним, `222` представитель рода, `90` по ботанической группе). 26 unit-тестов и проверка реальных данных/offline — PASS. Редакционная вычитка остаётся открытой: [отчёт](../../docs/validation/catalogue-300-import-2026-11-04.md).

- [ ] T149 Реализовать выдачу и поиск базового каталога в `supabase/functions/plants-api/catalogue.ts`, DTO/кеш и список/простую карточку в `ios/Plants/`; показывать описание и названия, сохранять экземпляр из каталога без care profile и вопросов об уходе. Проверить поиск, сохранение, перезапуск и отсутствие KB. Зависимости: T147/T148; использует соответствующие части T045/T046/T048, не закрывает их полный объём.
- [ ] T150 Подключить добавление по фото к базовой карточке: реальное определение и подтверждение/исправление вида, загрузка личного фото, сохранение экземпляра с этим главным фото; ошибки/повтор/ручной выбор сохраняют черновик. Использовать существующие auth/upload/claim-компоненты с необходимыми исправлениями; проверить доступ владельца и сохранность после перезапуска. Зависимости: T149 и рабочие auth/upload/identification/save; diagnosis/care pipeline не требуется.
- [ ] T151 Выполнить все пять критериев приёмки базового каталога на EN/PL и записать доказательства в `docs/validation/catalogue-skeleton.md`: отдельно fixtures и live API/Storage/iOS, включая отсутствие полной KB, фото пользователя и каталог без фото. Незавершённые интеграции явно оставить открытыми. Зависимости: T149/T150.

## Phase 1: Setup — окружение и каркас проекта

- [X] T001 Проверить Xcode/Swift, доступный Simulator, Docker, Supabase CLI и Deno; зафиксировать версии и статус G01 в `docs/validation/environment.md`.
- [X] T002 Создать `ios/Plants.xcodeproj/project.pbxproj`, SwiftUI app и схему `Plants` (iOS 17+, Swift 6, unit/UI targets, структура папок из `plan.md`); добавить `ios/Configuration/StoreKit.storekit` с двумя продуктами: месяц 49,99 PLN без trial, год 199,99 PLN с 7-дневным trial для eligible; фактическая цена из StoreKit.
- [X] T003 Подготовить `supabase/config.toml`, `supabase/functions/deno.json`, `supabase/.env.example` и `.gitignore` (включая server-only ключ подписи analysis_receipt); отделить публичный конфиг от серверных секретов.
- [X] T004 Закрепить зависимости Supabase Swift, GoogleSignIn, Anthropic SDK и Apple App Store Server Library в `Package.resolved` и `supabase/functions/deno.lock`.
- [ ] T005 Выполнить G02 для Anthropic structured classification schema 3.0 (identification/diagnosis/follow_up, без plan/советов) и Apple SignedDataVerifier в точном Edge Runtime в `supabase/functions/_shared/tests/runtime_compatibility_test.ts`. Provider-compatible schema не ослабляет серверную canonical validation; credentials/модель из конституции. В 3.0 проверить top-2/confidence/visual_markers, invalid scores и отсутствие сгенерированных вопросов.
- [ ] T006 Настроить CI-проверки Deno/SQL и сборку/тесты PL/EN в `.github/workflows/validate.yml` на базе фикстур (без вызова платного API на каждый PR).

## Phase 2: Foundational — схема БД, RLS, синхронизация и базовые сервисы

- [X] T007 Создать таблицы профилей и квитанций идемпотентности в `supabase/migrations/202610200001_ownership_sync.sql`: `profiles` (`id`, `account_state`, `anonymous`, `app_account_token`, `preferred_locale`, `reminder_hour_local INT DEFAULT 9 CHECK (reminder_hour_local BETWEEN 0 AND 23)`, `starter_identification_consumed`, `starter_diagnosis_consumed`, `starter_identification_job_id`, `starter_diagnosis_job_id`, `first_starter_success_at`, `quota_anchor_at`, `updated_at`) и `operation_receipts` (`owner_id`, `operation_id`, `command_name`, `payload_hash`, `response_payload`, `committed_at`). Общие поля и монотонная owner-метка — `data-model.md`; без отдельных голов/лент синхронизации. Покрытие: FR-010, FR-024, FR-025, FR-035, FR-039.
- [X] T008 Создать таблицы каталога и KB release в `supabase/migrations/202610200002_catalogue.sql`: `kb_releases`, `catalogue_releases`, `catalogue_taxa` (plant_id TEXT ↔ taxon UUID), `taxon_external_ids`, `taxon_names`, `catalogue_media`, `source_registry`, `source_documents`, `evidence_sources`. Pin, aliases, 300/40, atomic publish и права — data-model.md. Покрытие: FR-042/043/052/053/059.
- [X] T009 Создать `care_profiles` (PlantProfile с safety cat/dog/evidence/unknown), `condition_profiles`, `kb_vocabularies`, `kb_fallback_protocols`, `treatment_options`, `product_evidence`, `treatment_blocks` в `supabase/migrations/202610200003_editorial.sql`. RLS: full Golden Records server-only, товар <=30 дней и только разрешённое применение PL. Покрытие: FR-019/044/052–059.
- [X] T010 Создать таблицы коллекции, комнат, условий и черновиков в `supabase/migrations/202610200004_collection.sql`: `guest_drafts` (TTL 24ч), `draft_claims` (proof 15м, `overrides JSONB nullable`), `rooms`, `plants`, `condition_snapshots` (включая `light_source` и `light_confirmed` для различения ручного ответа, оценки камерой и `unknown`), `photo_assets`. Добавить `origin_draft_id` с UNIQUE(owner_id, origin_draft_id), текущий snapshot экземпляра и ограничения light_source/light_confirmed из `data-model.md`. Покрытие: FR-004, FR-009–FR-014, FR-034, FR-046, FR-047. photo_assets хранит nullable capture_at и неизменяемый server uploaded_at при первом ready; claim/fallback сохраняет подтверждённую исходную дату. Добавить flow_id/intent/add_method у guest_drafts и origin_flow_id/creation_intent/add_method у plants; creation_source допускает identification (FR-049/050). Conditions содержат optional pot_type/default unknown и season_override/default auto, оба в overrides/care_revision (FR-062).
- [X] T011 Создать таблицы анализов, планов и ухода в `supabase/migrations/202610200005_analysis_care.sql`: `analysis_jobs`, `analysis_results` (включая `evidence_basis`, `limitations`, `context_state`), `care_plans` (включая `comparison_traits JSONB`, `photo_angle_hint TEXT nullable`, `next_check_date`), `task_rules` и `care_tasks` (включая `comparison_traits`, `photo_angle_hint`, статус `needs_review` и `condition_code = 'check_soil_first'`), `care_entries`, `care_reversals`, `schedule_changes`. Закрепить quota_kind/quota_state и ссылки резерва в job, source snapshot/photo/revision и подписанную analysis_receipt у результата; timestamps/tombstones по `data-model.md`. Покрытие: FR-005, FR-019, FR-023–FR-030, FR-037, FR-046. Добавить mode=identification, result.mode, nullable diagnostic fields, flow_id/intent/add_method у job и plan_kind=routine/recovery у care_plans; схема provider 3.0: советы/планы — backend-проекция, job/result/receipt с kb_release_id (FR-050/054/059). Добавить immutable diagnostic_decisions/diagnostic_answers с revision/receipt/owner и ссылки решения в recovery plan; task_rules поддерживают treatment step/phase/start/repeat index (FR-063/064). QuotaKind = starter_identification/starter_diagnosis/free_monthly/paid_monthly/none; care_plans.access_tier IN ('basic','full'), basic только routine; опубликованный own full читается после expiry.
- [X] T012 Создать `purchase_ownership`, `subscription_events`, `entitlements` в `supabase/migrations/202610200006_billing.sql`: state active/grace/billing_retry/expired/revoked, offer_kind trial/paid, verified trial_end_at/valid_until/auto_renew_enabled. Первое подтверждённое предоставление доступа, включая trial, фиксирует profiles.quota_anchor_at; ownership UNIQUE(environment,original_transaction_id). Покрытие: FR-015–FR-021, SC-008.
- [X] T013 Создать `installation_access`, `monthly_quotas`, `provider_daily_budget` в `supabase/migrations/202610200007_analysis_quota.sql`: независимые starter consumed/job pointers для identification/diagnosis и first_starter_success_at; monthly quota_kind free_monthly/paid_monthly, UNIQUE(owner_id,quota_kind,period_start), limit_count=1/100 и CHECK(consumed_count >= 0 AND reserved_count >= 0 AND consumed_count + reserved_count <= limit_count). Резерв в analysis_jobs, terminal один раз; поля/locks по data-model §4. Покрытие: FR-005/017/065, SC-008.
- [X] T014 Создать таблицу задач удаления в `supabase/migrations/202610200008_deletion.sql`: `deletion_jobs` (`scope IN ('plant','account')`, `encrypted_apple_ref`). Сохранять tombstone приватной metadata до удаления аккаунта. Покрытие: FR-040, FR-041.
- [ ] T015 Настроить политики RLS и приватного Storage в `supabase/migrations/202610200009_access_policies.sql`: доступ только для `active` владельца, `full_body` планов исключен из бесплатных проекций, каталог отдает только `published`/`approved` записи. Покрытие: FR-017, FR-020, FR-041, FR-043. RLS новых memberships/aid/observations/transitions/claims проверяется также по owner; чтение собственного опубликованного full через owner API после expiry разрешено, сырые Golden Records остаются server-only. Зависимости: T127.
- [ ] T016 [P] Написать pgTAP-тесты изоляции данных A/B, анонимных/удаляемых аккаунтов и прав Storage в `supabase/tests/rls_boundary.test.sql`. Покрытие: FR-041, SC-009.
- [X] T017 Реализовать функции обработки идемпотентных команд (`operation_receipts`) и дельта-выборки `GET /sync` по `updated_at/deleted_at` с since/until и пагинацией (updated_at, entity_type, id) в `supabase/migrations/202610200010_command_protocol.sql`: команды ухода (`care.record`, `care.undo`) применяются без ошибки конфликта ревизий, если растение не удалено. Все writers/worker/billing сериализуются profiles FOR UPDATE с монотонной updated_at; полный refresh сохраняет outbox, поздний commit не теряется. Покрытие: FR-010, FR-024–FR-030, SC-005.
- [X] T018 Реализовать SQL `calculate_plant_schedule` и общий SQL access predicate в `supabase/migrations/202610200011_schedule_calculator.sql`, тесты `supabase/tests/schedule_calculator.test.sql`: фактическая дата/один открытый occurrence/check_soil_first, access_class basic_care (Free-место или paid), first_aid_control (один контроль), premium (paid). Проверять применимость и срок на commit; одна basic rule family на plant, pause сохраняет факты и снимает reminders. Зависимости: T011/T012/T127. Покрытие: FR-023/027–030/066, SC-021.
- [ ] T019 Создать входной роутер `supabase/functions/plants-api/index.ts` и валидацию авторизации/ошибок в `supabase/functions/_shared/http.ts` по `contracts/api.md`.
- [X] T020 Реализовать `supabase/functions/_shared/EntitlementGate.ts`: canReadExistingPlan отдельно от canGenerateFullPlan, paid access = active/grace с подтверждённым сроком, включая offer_kind=trial; Free-места и first-aid control. Исчерпание 100 не закрывает остальные права, safety независима. SQL T018 остаётся автором права INSERT. Покрытие: FR-017/020/023/066.
- [ ] T021 Создать импорт опубликованного KB release в `catalogue/import.ts` и `catalogue/manifests/sources.json`: JSON/hash/schema/300-40/aliases/evidence/EN-PL, quarantine → validate → atomic publish/rollback. Каталоговая проекция не отдаёт full protocols/paid планы. Зависимости: T008/T009/T108/T115. Покрытие: FR-042–044/052/053/059.
- [X] T022 [P] Создать Sendable DTO и доменные модели в `ios/Plants/Domain/PlantTypes.swift` и `ios/Plants/Data/Remote/APIModels.swift`, включая `LightSource`, `NextAvailableStep`, `PreliminaryAnalysis` и протокол `LightingEstimating`, поля reminderHourLocal/lightConfirmed и DTO overrides/recovery_check/analysis_receipt; enum NextAvailableStep = enable_basic_care/select_free_plants/record_first_aid/open_first_aid_control/generate_plan/open_plan/view_plant; optional paid_action отдельно. Покрытие: FR-005, FR-034, FR-046–FR-048. Добавить AddIntent, AddMethod, AddFlowState, IdentificationResult, PlanKind и plan_availability; отделить определение вида от диагноза (FR-049/050). Добавить ConditionProfile DTO, DiagnosticDecision/Question/Answer, confidence как score, marker IDs, pot/season и treatment steps/repeats (FR-061–064). Добавить QuotaKind, StarterAccess, FreeSelection, RequestedAction, BasicCareMembership, FirstAidFollowup, CareObservation, ProgressReportDTO по API/data-model; коммерческие поля не входят в Vision schema.
- [X] T023 Реализовать `LocalStore.swift` (SwiftData `ModelActor`) с изолированным хранилищем на аккаунт и таблицей `LocalOutbox` (атомарное сохранение намерения до отправки по сети). Хранить GuestDraftCache (фото/ответы/результат/receipt/overrides) после server TTL до confirmed сохранения либо явного отказа. Покрытие: FR-025, FR-041. AddFlowState и GuestDraftCache сохраняют flow_id/intent/add_method/шаг/подтверждённый вид и mode результата; смена намерения не стирает совместимый ввод.
- [X] T024 Реализовать сетевой клиент `ios/Plants/Data/Remote/PlantsAPIClient.swift` с передачей `operation_id`, `X-Installation-Credential` и `X-Client-Locale`.
- [X] T025 Реализовать `ios/Plants/Data/Sync/SyncEngine.swift` согласно `contracts/sync.md`: последовательная отправка очереди по растению, бесконфликтное слияние записей ухода, сохранность `LocalOutbox` при полном сбросе курсора. Реализовать since/until, устойчивую пагинацию/tombstones, повтор окна без потери поздних commit и overlay pending поверх кеша. Покрытие: FR-010, FR-024–FR-030, FR-041. Синхронизировать memberships/aid/observations/claims, Free selection revision и entitlement dates; PlanHistoryCache сохраняет чтение после expiry, ReportCache инвалидируется по watermark. Новые места ждут server confirmation, offline снятие reminders по sync contract. Зависимости: T127/T128.
- [X] T026 Написать unit-тесты устойчивости очереди при перезапуске, обрыве связи после коммита и смене аккаунта в `ios/PlantsTests/SyncPersistenceTests.swift`. Дополнить тестами одинаковых updated_at, commit во время paging, удаления комнаты и полного refresh без потери outbox. Покрытие: FR-025, FR-041, SC-005.
- [X] T027 Реализовать выбор языка PL/EN (с fallback на EN), `LanguageStore.swift` и базовый `Localizable.xcstrings` в `ios/Plants/App/PlantsApp.swift`. Покрытие: FR-001, FR-045.

- [X] T127 Дополнить foundation schema в `supabase/migrations/202610200005_analysis_care.sql` и profile preferences в `202610200001_ownership_sync.sql`: basic_care_memberships, first_aid_followups, care_observations, recovery_transitions, notification_claims; поля/constraints data-model §§9/10. free_selection_explicit BOOLEAN NOT NULL DEFAULT false; free_slot INT CHECK(free_slot BETWEEN 1 AND 3), UNIQUE(owner_id,free_slot) WHERE free_slot IS NOT NULL; UNIQUE(owner_id,plant_id,origin_analysis_id) для aid; UNIQUE(owner_id,kind,period_key) для claims, report key без timezone. task_rules.access_class IN ('basic_care','first_aid_control','premium'), ровно plan_id либо first_aid_id, rule_state active/paused/superseded; care_tasks.reminder_eligible/inactive_reason, owner FKs и watermark. Править draft foundation миграции до применения, не добавлять позднюю schema после использующих её SQL-функций. Зависимости: T007/T010/T011/T012. Покрытие: FR-020/023/066–068, SC-021–024.
- [X] T128 Реализовать `supabase/functions/plants-api/notifications.ts` и `supabase/migrations/202611010001_notification_claims.sql`: POST /notifications/claim, opt-ins false по умолчанию, owner/kind/period dedup, проверенные trial dates, progress current/completed month scheduling; claim после отмены не выдаёт вторую отправку другому устройству. Зависимости: T127/T017/T019/T020. Покрытие: FR-016/068, SC-008/024.

## Phase 3: US1 — Первая помощь без регистрации (P1)

- [ ] T028 [P] [US1] Написать `supabase/tests/quota_admission.test.sql`: 20 запросов на последнюю попытку, starter ID/diagnosis независимо, Free UTC=1 со следующего месяца первого starter success, paid=100 от первого trial/access, OR/earliest при bind, starter_in_progress, ошибки/unknown, job через месяц/покупку/expiry, paid до starter, без fallback/reset/накопления. Зависимости: T013. Покрытие: FR-005/017/065, SC-008, V44/V45/V50.
- [X] T029 [P] [US1] Написать positive/negative проверки classification 3.0 в `supabase/functions/_shared/tests/analysis_result_test.ts`: три режима, closed plant/condition/symptom IDs, unknown/out-of-scope, ранги, отсутствие советов/товаров/plan/full_plan, непригодное фото, pinned release. Проверить, что invalid output не списывает starter/Free/Paid. Покрытие: FR-005–007/054/059. Проверить max 2, confidence 0..1, distinct ranks/conditions, visual_markers из опубликованного профиля (FR-061).
- [ ] T030 [US1] Реализовать `supabase/migrations/202610200012_quota_operations.sql`, `supabase/functions/_shared/AnalysisAccess.ts` и endpoints в `plants-api/installations.ts`, `analysis-access.ts`: алгоритм data-model §4, два starter, Free/Paid monthly, locks/резерв/lease terminal, bind по режимам и earliest success, неизменность источника job. GET mode-specific остатки/даты, guest только starter, follow_up только paid. Зависимости: T013/T028. Покрытие: FR-005/017/065, SC-008.
- [ ] T031 [US1] Реализовать эндпоинты загрузки медиа `/media/upload-ticket` в `supabase/functions/plants-api/media.ts` (проверка MIME, размера нормализованного файла, выдача signed URL на 60 сек). Покрытие: FR-003, FR-006, FR-033, FR-041.
- [X] T032 [US1] Реализовать классификационный AnthropicAdapter и AnalysisValidator в `supabase/functions/_shared/AnthropicAdapter.ts` и `AnalysisValidator.ts`: schema 3.0, отдельный identification prompt, release/ID membership, stop/refusal/truncation. Подписывать backend-проекцию с kb_release_id; советы формирует T116, а не модель. Зависимости: T005/T029/T108/T115. Покрытие: FR-005–007/044/054/059. В новой версии top-2/confidence используются только для backend routing; вопрос не генерируется Vision (FR-061).
- [ ] T033 [US1] Реализовать эндпоинты `/analysis/jobs` (POST, GET status/result) в `supabase/functions/plants-api/analysis.ts` с проверкой `operation_receipts` до проверки квот. Покрытие: FR-005–FR-007, FR-031, FR-045.
- [ ] T034 [US1] Реализовать worker `supabase/functions/analysis-worker/index.ts`, `ProviderBudgetGuard.ts` и reconciler `supabase/functions/maintenance/analysis-jobs.ts`: timeout 40с, deadline 55с, lease/quota release ровно раз. Provider вызывается только для identification/diagnosis/follow_up; plan детерминирован и не использует provider budget. Guard <=10; период резерва сохраняется. Покрытие: FR-007/017/054/060, SC-002.
- [X] T035 [US1] Реализовать подготовку фото на устройстве в `ios/Plants/Integrations/Photos/AnalysisPhotoInput.swift`: автоматическое сжатие и ресайз любых поддерживаемых снимков (включая > 10 МБ) до облачного варианта <=10 МБ и AI JPEG 1568px, удаление EXIF, показ контекстной подсказки снять растение и заметный симптом (`US1.12`); отказ только при нечитаемом/поврежденном файле. Покрытие: FR-003, FR-006, FR-033, US1.12.
- [ ] T036 [US1] Реализовать хранение `installation_credential` в Keychain и репозиторий `AnalysisAccessRepository.swift`. Покрытие: FR-005, FR-017. Показать раздельные остатки/источник/дату до скана; не называть стартовую попытку trial; ошибка не скрывает каталог и бесплатный путь. Покрытие: FR-065, V44/V45.
- [ ] T037 [US1] Создать экран приветствия и 3 вопроса об уходе (`CareQuestionsView.swift`) с индикатором шага «N из 3», вариантом «не знаю» в каждом вопросе, сохранением фото/ответов при возврате назад (`US1.13`) и кнопкой вызова оценки света. Покрытие: FR-001, FR-002, FR-004, FR-034, US1.13. Welcome использует общий выбор двух равнозначных намерений T100; CareQuestionsView переиспользуется после определения/выбора вида в care (FR-049/050).
- [ ] T038 [US1] Создать `AnalysisFlowModel.swift` и `PreliminaryResultView.swift`: нейтральный экран ожидания без обещания выявленной болезни (`US1.14`), первый экран результата с вероятной причиной/здоровьем, основанием вывода, ограничениями и первым действием (`US1.15`). Покрытие: FR-005–FR-007, FR-045, US1.14, US1.15, SC-013.
- [ ] T039 [US1] Проверить сценарии **US1.1–US1.15** на PL и EN в `ios/PlantsUITests/FirstHelpTests.swift`. Включить читаемый исходник >10 МБ, unknown, возврат назад, retry без списания, лимит и смену языка; качественные метрики SC-013 измеряются отдельно T096. Покрытие: FR-001–FR-007, FR-045, SC-001, SC-013.

## Phase 4: US2 — Коллекция, проверка перед сохранением и каталог (P1)

- [ ] T040 [P] [US2] Написать тесты переноса гостевого результата (`guest_claim`), применения `overrides` перед сохранением, перевода анализа в `stale` и локального fallback-сохранения после истечения 24ч TTL черновика в `supabase/tests/guest_claim.test.sql` и `supabase/functions/_shared/tests/claim_transfer_test.ts`. Проверить неверную подпись/хеш receipt, гонку claim/fallback, неполный кеш, создание комнаты и атомарность snapshot версии 2 / care_revision=2. Покрытие: FR-005, FR-008–FR-014, FR-046, FR-048. Повторить claim/fallback для identification без диагноза, с тем же flow_id и подтверждёнными видом/условиями (FR-050). Проверить перенос решений/ответов/обоих receipt, pending ответы и новый decision revision без квоты (FR-064).
- [X] T041 [US2] Реализовать вход через Apple и Google в `ios/Plants/Integrations/Auth/NativeAuthService.swift` с сохранением гостевого результата при отмене входа. Покрытие: FR-008, FR-009, FR-041.
- [ ] T042 [US2] Реализовать `/claims/prepare` и `/claims/commit` с поддержкой `overrides` (исправление вида, условий, выбор/создание комнаты до сохранения) в `supabase/migrations/202610200013_guest_claim.sql` и `supabase/functions/plants-api/claims.ts`: при изменении вида или условий выставлять `care_revision = 2` и помечать исходный анализ `context_state = 'stale'`; возвращать `next_available_step` (`FR-048`). Изменение только комнаты не делает stale; исходный snapshot сохраняется, source result неизменен; staging copy и retry bound к одному owner/operation. Покрытие: FR-005, FR-008–FR-010, FR-046, FR-048, US2.9, US2.13. Bind переносит независимые starter flags через OR и earliest success; живой starter_in_progress повторяется после terminal, без повторной выдачи. Покрытие: FR-065.
- [ ] T043 [US2] Реализовать двухфазное копирование фото черновика и фоновую очистку в `supabase/functions/maintenance/guest-claims.ts`. Покрытие: FR-009, FR-010, FR-041.
- [ ] T044 [US2] Реализовать команды `plant.create` (включая добавление из каталога без фото и fallback-сохранение локального гостевого результата старше 24ч) и `room.create/rename/delete` в `supabase/migrations/202610200014_collection_commands.sql`. Fallback проверяет подписанную analysis_receipt и origin_draft_id, применяет overrides без ИИ/фотоквоты, возвращает next_available_step. Покрытие: FR-009–FR-014, FR-048.
- [ ] T045 [US2] Реализовать поиск по каталогу (PL/EN/Latin/синонимы, научный fallback) и выдачу лицензий/авторства в `supabase/functions/plants-api/catalogue.ts`. Покрытие: FR-042–FR-044.
- [ ] T046 [US2] Реализовать `CollectionRepository.swift` и `ClaimFlowModel.swift` (с автоматическим fallback на `plant.create` из локального кеша, если серверный `guest_draft` истек по 24ч TTL). После подтверждённого fallback очищать GuestDraftCache; неполный кеш сохранять до явного решения пользователя. Покрытие: FR-009–FR-014, FR-046.
- [ ] T047 [US2] Создать экран выбора сценария добавления (`AddPlantView.swift`: сначала problem/care, затем scan/catalogue в care; общий роутер T100), экран проверки и правки перед сохранением (`PreSaveReviewView.swift`: вид, условия с различением `camera_estimate` и `unknown`, выбор/создание/пропуск комнаты) и экран следующего шага после сохранения (`PostSaveNextStepView.swift`). Бесплатный переход enable_basic_care/select_free_plants/record_first_aid/open_first_aid_control либо open_plan/view_plant брать из next_available_step; paid_action отдельно по запросу, не обещать несуществующие задачи. Покрытие: FR-011–FR-014, FR-046–FR-048, US2.8–US2.13. Пользователь сначала выбирает намерение; выбор метода вложен в care. UI опирается также на plan_kind/plan_source/plan_availability, недоступный профиль объясняется до оплаты ради этого плана (FR-049/050).
- [ ] T048 [US2] Создать карточку растения `ios/Plants/Features/PlantDetail/PlantDetailView.swift` (условия, журнал, фото, анализы со статусом актуальности `current`/`stale`). Покрытие: FR-013, FR-014, FR-046.
- [ ] T049 [US2] Проверить сценарии **US2.1–US2.18** и поиск по каталогу на PL и EN в `ios/PlantsUITests/CollectionTests.swift`. Включить TTL 24ч, overrides вида/условий/комнаты, отмену создания комнаты, camera_estimate vs unknown и post-save шаг с подпиской/без неё. Покрытие: FR-008–FR-014, FR-042, FR-046–FR-048, SC-012, SC-014. Включить скан → подтверждение вида → 3 вопроса, каталог без фото, смену намерения и отсутствие диагностики в care (T105).

- [ ] T129 [US2] Реализовать `supabase/functions/_shared/BasicCareService.ts`, `plants-api/basic-care.ts` и `supabase/migrations/202611010002_basic_care.sql`: enable/disable/free_care.select, стабильный enabled_at, первые три/явный выбор/revision и free_selection_explicit; select атомарно валидирует/включает ранее не enabled растение и заменяет выбранное, paid unlimited/expiry fallback, pause reminders без удаления истории, удаление освобождает место. Basic plan через PlanService, одна basic rule family; команды/worker/foreground проверяют access_class SQL. Зависимости: T127/T018/T020/T044/T055/T117. Покрытие: FR-023/028/048/050, SC-014/021, V46/V50.
- [ ] T130 [US2] Создать `ios/Plants/Features/Collection/FreeCareSelectionView.swift` и `BasicCareFlowModel.swift`: явное включение/выбор до трёх, четвёртое сохраняется, pending/confirmed/error, смена выбора без потери истории, объяснение missing profile/места. Зависимости: T022/T024/T047/T129. Покрытие: FR-023/048/050, SC-021.
- [ ] T131 [US2] Проверить Free catalogue/scan/четвёртое растение, concurrent selection/expiry/delete/care, paid→Free и повторное включение в `supabase/tests/free_care.test.sql` и `ios/PlantsUITests/FreeCareTests.swift`; факты сохраняются, reminders снятого места отключены, нет дублей. Зависимости: T129/T130/T063. Покрытие: SC-014/021, V46/V50.

## Phase 5: US3 — Полный план, подписка и месячный лимит 100 анализов (P1)

- [ ] T050 [P] [US3] Написать тесты верификации JWS подписи App Store, дедупликации Notifications V2, привязки `appAccountToken` и расчета месячных окон квот от первого verified access, включая trial в `supabase/functions/_shared/tests/billing_verification_test.ts` и `supabase/tests/subscription_quota.test.sql`. Покрытие: FR-015–FR-021, SC-008. Добавить eligible/ineligible year trial, два продукта, confirmed trial end, trial→paid без reset, чтение старых планов при expiry/refund и Free-тройку. Покрытие: V49/V50.
- [ ] T051 [P] [US3] Написать `supabase/functions/_shared/tests/full_plan_test.ts`: routine/recovery/stale из Golden Records без LLM/квоты/provider budget, applicability и reassessment_required, context_changed, expiry, consumed=100, full_body в owner history projection; чтение после expiry, блокировка неприменимых инструкций. Проверить неизменность анализа, recovery_check и отсутствие скрытого скана. Покрытие: FR-017/019/020/023/046/054/060. Recovery требует выбранного применимого diagnostic decision, treatment_start/steps/timeline и verified option; неполный диагноз → diagnosis_unresolved (FR-061/063/064).
- [ ] T052 [US3] Реализовать серверную проверку транзакций и статус-реконсиляцию Apple в `supabase/functions/_shared/AppleBilling.ts` и `supabase/functions/plants-api/billing.ts`. Покрытие: FR-017, FR-018, FR-020.
- [ ] T053 [US3] Реализовать обработчик вебхуков `supabase/functions/billing-webhook/index.ts` и фоновую сверку `supabase/functions/maintenance/subscriptions.ts`. Покрытие: FR-017, FR-018, FR-020.
- [ ] T054 [US3] Реализовать `supabase/migrations/202610200015_subscription_access.sql`: paid_monthly=100, anchor первого verified access включая trial, без reset при trial→paid/restore/смене тарифа; reconciliation поздних verified данных сохраняет расход/reserved. Free ledger не меняется, expiry сохраняет Free-выбор и пересчитывает права. Покрытие: FR-017/020/023/065, SC-008/021.
- [ ] T055 [US3] Реализовать `supabase/functions/_shared/PlanService.ts`: routine по опубликованным применимым фактам конкретного действия, recovery по сохранённым наблюдениям и применимому ConditionProfile. Оба без LLM/квоты/provider budget, paid access для full либо Free-место/paid для basic при admission/commit, pin release/context revision. Stale → повторная проверка применимости либо reassessment_required; старый результат неизменен. Зависимости: T051/T116. Покрытие: FR-014/017/019/023/044/046/050/054/060. Принимать revision решения и явный treatment_start/option; строить steps из ConditionProfile, даты делегировать SQL (FR-063/064). Access_tier basic/full; basic только routine и только условные проверки грунта; одна basic rule family на plant, full не дублирует полив. Schema/политика T127/T018 должны быть готовы до интеграции.
- [ ] T056 [US3] Реализовать атомарную публикацию плана, правил и первых задач (`calculate_plant_schedule`) и защищенный эндпоинт `GET /plans/:plant_id/current` в `supabase/migrations/202610200016_plan_publication.sql` и `supabase/functions/plants-api/plans.ts`. Перенести recovery_check в care_plans/task_rules/care_tasks (comparison_traits и photo_angle_hint); старые неприменимые задачи не выдавать за актуальные. Покрытие: FR-017, FR-019, FR-020, FR-023, FR-028. Owner GET current/versions читает ранее опубликованные планы после expiry с датой/версией/applicability/safety, без права на новый full. Basic publication не требует paid access при активном Free-месте.
- [ ] T057 [US3] Реализовать `StoreKitService.swift` (загрузка продуктов, покупка с серверным `appAccountToken`, восстановление покупок, переход к управлению подпиской App Store). Покрытие: FR-015–FR-018, FR-020, FR-021.
- [ ] T058 [US3] Создать `ios/Plants/Features/Paywall/PaywallView.swift` и `FullPlanView.swift`: два тарифа, фактические цена/валюта/период, eligible годовой trial/дата/полная цена, Free/платная граница, 100/мес и reset date. Contextual offer после бесплатной пользы, отказ возвращает к Free без повторного обязательного paywall. Recovery/routine действия, срок/признаки/ракурс; история плана с версией/applicability после expiry. Покрытие: FR-015–021/048/050, SC-008/013/022.
- [ ] T059 [US3] Реализовать `ios/Plants/Data/Local/PlanHistoryCache.swift`: encrypted owner-scoped ранее полученные версии/даты/context_revision, чтение после trial/expiry/refund; неприменимые/отозванные инструкции и просроченная chemical validity скрываются online/offline, logout изолирует кеш. Покрытие: FR-020/041/045/057, V50.
- [ ] T060 [US3] Проверить сценарии **US3.1–US3.13** на PL и EN в `ios/PlantsUITests/SubscriptionTests.swift`. Включить явный plan по stale с исходным фото/актуальными условиями без квоты и контрольную задачу того же экземпляра. Покрытие: FR-015–FR-021, FR-023, SC-008, SC-013. Включить routine после scan/catalogue, missing care_profile до paywall и отсутствие дополнительного расхода квоты (FR-050).

- [ ] T132 [US3] Реализовать `ios/Plants/Domain/Entitlements/RequestedAction.swift`, resume в `PaywallFlowModel.swift` и verification fields в `supabase/functions/plants-api/billing.ts`: eligible/ineligible year trial, confirmed offer_kind/end/auto-renew, контекст покупки и возврат, pending/cancel/error без ложного успеха. Зависимости: T052/T054/T057/T058. Покрытие: FR-015–020, SC-008/022, V48–V50.
- [ ] T133 [US3] Реализовать `ios/Plants/Integrations/Notifications/TrialReminderScheduler.swift`: opt-in до trial, server claim T128, local request за 24ч verified trial_end_at, стабильный ID, отмена/перестройка при expiry/refund/изменении срока/opt-out/logout; запрет push не скрывает дату. Зависимости: T128/T132/T075/T084. Покрытие: FR-016, SC-008, V49/V50.
- [ ] T134 [US3] Дополнить `ios/PlantsUITests/SubscriptionTests.swift` и `supabase/tests/subscription_quota.test.sql` сценариями T132/T133/PlanHistoryCache: 7 из 100 в trial → 93 после оплаты, restore/refund, чтение старого плана и safety offline, контекстный отказ/возврат. Зависимости: T050/T059/T060/T132/T133/T129. Покрытие: SC-008/021/022, V48–V50.

## Phase 6: US4 — Ежедневные задачи и история ухода (P1)

- [ ] T061 [US4] Реализовать адаптер расписания `supabase/functions/_shared/ScheduleCalculator.ts` к SQL-функции `calculate_plant_schedule`. Не дублировать SQL-алгоритм в TypeScript; проверить контракт адаптера в `supabase/functions/_shared/tests/schedule_adapter_test.ts`. Покрытие: FR-023, FR-027–FR-030.
- [ ] T062 [US4] Реализовать команды `care.record` и `care.undo` в `supabase/migrations/202610200017_care_commands.sql`: принимать уход в том числе для задач в статусе `needs_review` и без ошибки конфликта ревизий растения; проверять access_class для новых задач: basic Free-повторы продолжаются, premium после expiry запрещены. Принимать care.correct_date без revision-конфликта; повтор записи/отмены возвращает already_recorded/already_undone; для needs_review не создавать следующий occurrence по старому плану. Покрытие: FR-024–FR-030, US4.8, US4.9. Добавить care.postpone только базовой проверки без care_entry, дата >=сегодня; атомарное объяснение даты, ограничения для chemical steps сохраняются. Покрытие: SC-021.
- [ ] T063 [US4] Написать pgTAP-тесты консистентности ухода (включая undo, запись задним числом, условие `check_soil_first` для первого полива по `US4.9` и выполнение задач после окончания подписки) в `supabase/tests/care_consistency.test.sql`. Проверить конкурентные record/undo двух устройств и устаревшие ревизии, идемпотентные no-op, needs_review без блокировки и запрет новых задач после expiry. Покрытие: FR-022–FR-030, SC-005, SC-006. Проверить Free-повторы/undo/postpone, смену тройки/expiry гонкой с уходом, отсутствие второй basic цепочки после full plan. Покрытие: SC-021.
- [ ] T064 [US4] Реализовать пересчет при смене часового пояса (`schedule.relocalize`) и фоновую актуализацию в `supabase/migrations/202610200018_schedule_relocalize.sql` и `supabase/functions/maintenance/schedules.ts`. Покрытие: FR-020, FR-023, FR-028–FR-030.
- [ ] T065 [US4] Реализовать `CareRepository.swift` с оптимистическим сохранением в `LocalOutbox` и автоматической синхронизацией без ручных диалогов разрешения конфликтов. Покрытие: FR-024–FR-030.
- [ ] T066 [US4] Создать главный экран задач `ios/Plants/Features/CareTasks/TodayView.swift`: задачи на сегодня и просроченные, условие проверки грунта для первого полива (`US4.9`), ненавязчивый бейдж на задачах `needs_review` без блокировки их выполнения. Отметка needs_review в один тап; старые инструкции не выдаются за актуальные. Покрытие: FR-022–FR-025, FR-028, US4.9.
- [ ] T067 [US4] Создать экран истории ухода, ввода прошедшей даты, отмены действия и объяснения переноса даты в `CareHistoryView.swift` и `NextCheckReasonView.swift`. Покрытие: FR-026–FR-030.
- [ ] T068 [US4] Проверить сценарии **US4.1–US4.9** на PL и EN (с обрывом связи после коммита и перезапуском) в `ios/PlantsUITests/CareTasksTests.swift`. Добавить конкурентные care.record/care.undo, needs_review без диалогов и сохранность pending после reset sync. Покрытие: FR-022–FR-030, SC-005–SC-007.

- [ ] T135 [US4] Реализовать `supabase/functions/_shared/FirstAidService.ts`, `plants-api/first-aid.ts` и `supabase/migrations/202611010003_first_aid.sql`: first_aid.record/observation.record, один контроль на origin_analysis_id без Free-места/full плана, срок из опубликованного протокола, undo/correct_date переиспользуют связь; undo ставит reminder_eligible=false/inactive_reason=first_action_undone у незавершённого контроля, повторная отметка пересчитывает тот же control; note/photo остаются owner-private без AI. Нет срока/действия → reason, не выдуманная задача. Зависимости: T127/T018/T044/T062/T116/T121. Покрытие: FR-024/066, SC-022, V47.
- [ ] T136 [US4] Создать `ios/Plants/Features/CareTasks/FirstAidControlView.swift` и интегрировать `PreliminaryResultView.swift`: после сохранения отметить первое действие, pending/confirmed/error, контроль/наблюдение/своё фото без AI, платный follow_up отдельным запросом; повтор не дублирует. Зависимости: T135/T038/T046/T065/T073. Покрытие: FR-066, SC-022.
- [ ] T137 [US4] Проверить record/retry/undo/correct_date, отсутствие protocol сроков, смену decision revision, ограничения owner/photo в `supabase/tests/first_aid.test.sql` и `ios/PlantsUITests/FirstAidControlTests.swift`. Зависимости: T135/T136/T123. Покрытие: FR-066, SC-020/022, V41/V47.
- [ ] T139 [US4] Обновить `ios/Plants/Features/CareTasks/TodayView.swift` и `ReturnAfterBreakView.swift`: пустой день с ближайшей проверкой/нет расписания, уточнение фактов после перерыва, «не знаю», без фиктивного здоровья/автоотметок/догоняющих обработок. Зависимости: T066/T067/T129. Покрытие: FR-022, SC-023, V52.

## Phase 7: US5 — Исправление сведений и фотодневник (P1)

- [ ] T069 [P] [US5] Написать тесты неизменности UUID растения при смене вида, перевода старых анализов в `stale`, пометки задач `needs_review` и назначения главного фото в `supabase/tests/plant_history.test.sql` и `ios/PlantsTests/PlantEditingTests.swift`. Покрытие: FR-028, FR-031, FR-032, FR-042.
- [ ] T070 [US5] Реализовать команды `plant.edit` и `photo.set_main` в `supabase/migrations/202610200019_plant_editing.sql`: смена вида/условий инкрементирует `care_revision` и переводит открытые задачи в `needs_review` (оставляя их доступными для выполнения). Покрытие: FR-028, FR-031, FR-032.
- [ ] T071 [US5] Создать экран редактирования вида и условий `ios/Plants/Features/PlantDetail/EditPlantView.swift` с ненавязчивым предложением обновить план при изменении данных. Покрытие: FR-013, FR-028, FR-031, FR-042.
- [ ] T072 [US5] Создать фотодневник и выбор главного фото в `ios/Plants/Features/PlantDetail/PhotoDiaryView.swift`. Покрытие: FR-031, FR-032, FR-037.
- [ ] T073 [P] [US5] Реализовать сохранение собственных снимков в системную галерею в `ios/Plants/Integrations/Photos/PhotoExportService.swift`. Покрытие: FR-032, FR-033.
- [ ] T074 [US5] Проверить сценарии **US5.1–US5.6** на PL и EN в `ios/PlantsUITests/PlantHistoryTests.swift`. Покрытие: FR-031–FR-033, FR-042, SC-006, SC-007.

## Phase 8: US6 — Напоминания и контрольные фото (P2, входит в MVP)

- [ ] T075 [P] [US6] Написать unit-тесты планировщика локальных уведомлений (время по умолчанию 09:00, пользовательский час доставки, пересчет при выполнении/отмене/выходе из аккаунта, сохранение уведомлений для задач `needs_review`) в `ios/PlantsTests/ReminderSchedulingTests.swift`. Проверить границы 0/23, timezone/DST, смену часа, отсутствие дублей/повторной доставки прошедшего времени. Покрытие: FR-033, FR-035, FR-036, FR-041. Reminders учитывают reminder_eligible=false для basic tasks исключённого места; offline expiry использует подтверждённые Free-места. Отдельные trial/report reminders реализуются T133/T143.
- [ ] T076 [P] [US6] Написать `supabase/functions/_shared/tests/followup_test.ts`: Vision только классифицирует изменения/candidates по schema 3.0; один успешный follow_up расходует 1 monthly, unsuitable фото/ошибка — нет. Первая помощь/обновление плана выбираются из протокола, LLM не генерирует лечение. Покрытие: FR-017/037/038/054/059.
- [ ] T077 [US6] Реализовать `ReminderScheduler.swift` (очередь до 30 ближайших уведомлений в выбранный пользователем час, по умолчанию 09:00 по местному времени). Использовать profiles.reminder_hour_local; включать open/needs_review, исключать completed/superseded/deleted, нейтральный текст для needs_review. Покрытие: FR-033, FR-035, FR-036, FR-039, FR-041.
- [ ] T078 [US6] Создать `supabase/functions/_shared/FollowUpService.ts`: классификация динамики и кандидатов, затем явное детерминированное обновление плана через PlanService с проверкой KB/applicability. Никаких сгенерированных советов; comparison traits из протокола. Зависимости: T055/T076/T116. Покрытие: FR-017/037/038/054/060.
- [ ] T079 [US6] Создать экран контрольной проверки и сравнения фото `ios/Plants/Features/PlantDetail/FollowUpView.swift` с показом признаков сравнения (`comparison_traits`) и подсказки по ракурсу (`photo_angle_hint`). Покрытие: FR-033, FR-037, FR-038, US6.3.
- [ ] T080 [US6] Создать экран запроса разрешения на уведомления после появления первых задач в `ios/Plants/Features/CareTasks/ReminderConsentView.swift`. Покрытие: FR-033, FR-035, FR-036.
- [ ] T081 [US6] Проверить сценарии **US6.1–US6.5** на PL и EN в `ios/PlantsUITests/FollowUpReminderTests.swift`. Покрытие: FR-035–FR-038.

- [ ] T138 [US6] Реализовать `supabase/functions/_shared/RecoveryTransitionService.ts`, `supabase/migrations/202611010004_recovery_transition.sql` и `ios/Plants/Features/PlantDetail/RecoveryTransitionView.swift`: observation+care_revision+confirm, re-evaluate applicability, unknown/worse→reassessment_required, атомарно согласовать recovery/basic rules без дублей; нет места→select_free_plants до изменения. Зависимости: T127/T123/T129/T135/T079. Покрытие: FR-067, SC-023, V51.
- [ ] T140 [US6] Проверить timeline completion без recovered, worse/unknown, явный переход, expiry/места/перерыв/retry в `supabase/tests/recovery_transition.test.sql` и `ios/PlantsUITests/RecoveryTransitionTests.swift`. Зависимости: T138/T139. Покрытие: FR-022/067, SC-023, V51/V52/V56.

## Phase 9: US7 — Профиль, время напоминаний, язык и удаление данных (P2, входит в MVP)

- [ ] T082 [P] [US7] Написать тесты удаления растения/аккаунта, отзыва Apple-токена и изоляции данных при смене пользователя в `supabase/tests/account_deletion.test.sql` и `supabase/functions/_shared/tests/deletion_worker_test.ts`. Покрытие: FR-040, FR-041, SC-009.
- [ ] T083 [US7] Реализовать удаление растения/аккаунта и обновление настроек профиля в `supabase/migrations/202610200020_deletion_commands.sql`, `supabase/functions/plants-api/account.ts` и `supabase/functions/maintenance/deletions.ts`. Команда profile.update валидирует reminder_hour_local целым 0..23, default 9, возвращает профиль через GET /me и sync. Покрытие: FR-039–FR-041.
- [ ] T084 [US7] Создать экран профиля `ios/Plants/Features/Profile/ProfileView.swift`: статус аккаунта и подписки, остаток лимита анализов, переключатель языка PL/EN, включение напоминаний и **выбор часа уведомлений (по умолчанию 09:00)**, ссылка на управление подпиской App Store, выход и удаление аккаунта с предупреждением. После сохранения часа перестроить будущие локальные уведомления без изменения фактов ухода. Покрытие: FR-021, FR-035, FR-039, FR-040, FR-045. Добавить независимые opt-in trial/report reminders (default false), подтверждённые даты trial/auto-renew и Free-выбор; нет удаления истории при expiry.
- [ ] T085 [US7] Реализовать очистку локальных контейнеров и уведомлений при выходе/смене аккаунта в `ios/Plants/App/SessionCoordinator.swift`. Покрытие: FR-005, FR-039–FR-041, FR-045.
- [ ] T086 [US7] Проверить сценарии **US7.1–US7.5** на PL и EN в `ios/PlantsUITests/ProfilePrivacyTests.swift`. В US7.1 проверить default 09:00, изменение/перезапуск, некорректный час и новую timezone. Покрытие: FR-039–FR-041, FR-045, SC-009.

## Phase 10: US8 — Приблизительная оценка освещения камерой (P2, входит в MVP)

- [ ] T087 [US8] Провести калибровку и тест прототипа на физических iPhone (`G03`) в `ios/Plants/Integrations/Camera/LightingProbe.swift` и зафиксировать пороги в `docs/validation/lighting-prototype.md`. Запустить физический прототип после T002/T022 до приёмки интеграции US1; поздняя нумерация не откладывает G03 до конца MVP. Покрытие: FR-034.
- [ ] T088 [P] [US8] Написать unit-тесты классификатора экспозиции и fallback в `unknown` при нестабильном кадре в `ios/PlantsTests/LightingHintTests.swift`. Покрытие: FR-033, FR-034.
- [ ] T089 [US8] Реализовать `LightingEstimator.swift` (AVFoundation, выключенная вспышка, категории `low`/`bright_indirect`/`unknown`, запрет автовыбора `direct_sun`). Покрытие: FR-034.
- [ ] T090 [US8] Создать `ios/Plants/Features/Analysis/LightingHintView.swift`: контекстная подсказка по положению камеры и ограничениям до замера (`US8.3`), явное подтверждение или ручное изменение результата пользователем (`FR-047`). Применять только подтверждённую категорию, сохранять light_source/light_confirmed; пропуск оставляет unknown, direct_sun не выбирается автоматически. Покрытие: FR-033, FR-034, FR-047, US8.1–US8.3.
- [ ] T091 [US8] Проверить сценарии **US8.1–US8.3** на PL и EN на физических устройствах и обновить `docs/validation/lighting-prototype.md`. Проверить подтверждённую оценку/ручное исправление/пропуск, сохранение источника в PreSaveReview и отсутствие подмены unknown. Покрытие: FR-033, FR-034, SC-014.

## Phase 10a: Намерение, скан для ухода и воронка (P1, поправка 2026-10-22)

Все задачи ниже обязательны до приёмки T096/T098/T099; ID T001–T099 сохранены.

- [ ] T100 [US2] Реализовать общий `ios/Plants/Features/Onboarding/AddPlantRouter.swift`, выбор двух намерений и отдельный care method picker. Welcome и AddPlantView используют один маршрутизатор; Today открывается после завершённого приветствия, незавершённый flow восстанавливается, смена намерения не запускает AI и сохраняет совместимый ввод. Зависимости: T022/T023/T027; T037/T047 подключают готовый роутер. Покрытие: FR-049, US2.8/18.
- [ ] T101 [US2] Реализовать identification-only путь в `ios/Plants/Features/Analysis/IdentificationFlowModel.swift` и `IdentificationResultView.swift`, подключив T030/T032/T033/T034 к mode=identification; до скана показать общий доступ/лимит, после — подтверждение вида и возможность дополнить известные условия по FR-004, с переходом в каталог при отказе камеры/unknown/лимите. Зависимости: T028–T036, T040–T047, T100. Покрытие: FR-005/017/050, US2.14–US2.16.
- [ ] T102 [US3] Реализовать `ios/Plants/Features/Collection/PostSaveNextStepView.swift`: после problem применимое first_action/control, после care enable_basic_care/select_free_plants; missing data → объяснение. Optional full предложение только по запросу; successful purchase возвращает RequestedAction без автозапуска лечения. Интеграция с `supabase/functions/_shared/PlanService.ts`. Зависимости: T051/T055/T056/T058/T100/T101/T129/T130/T135/T136. Покрытие: FR-015/023/048/050/066, SC-014/022.
- [ ] T103 Реализовать `supabase/migrations/202610220001_funnel.sql`, `supabase/functions/plants-api/funnel.ts` и `_shared/FunnelService.ts`: fixed enum events, дедупликация event_id, приватные данные не принимаются, RLS, guest/permanent flow proof в том числе без AI; server-only result/save/purchase/plan после commit. Новая verified purchase учитывается один раз, restore/pending/cancel не покупка. Зависимости: T007/T015/T019/T033/T042/T044/T052–T056. Покрытие: FR-051. Расширить fixed enum/data fields по data-model §6: client/server events, source_context, Free/Trial/Paid, nullable flow вне onboarding, semantic dedup_key; серверные billing/usage факты не принимаются от клиента. Покрытие: SC-025.
- [ ] T104 Реализовать `ios/Plants/Data/Local/FunnelOutbox.swift` и `ios/Plants/Domain/Funnel/FunnelTracker.swift`: устойчивые flow/event UUID, intent_selected vs intent_changed, method, подтверждение вида, предложение и billing flow attribution; очередь не блокирует сценарий, перенос guest flow по proof не смешивает аккаунты. Зависимости: T023/T024/T100/T102/T103. Покрытие: FR-049/051. Включить paywall_shown/dismissed, trial_requested, app_opened, report_viewed и paid_action_requested; eligibility/покупку не доказывает клиент. ReportView интегрировать после T142, основные tracker API доступны раньше.
- [ ] T105 Проверить обе ветки на PL/EN в `ios/PlantsUITests/IntentCareFlowTests.swift` и `supabase/functions/_shared/tests/identification_care_test.ts`: раздельные starter, Free=1/Paid=100, переключение/перезапуск, unknown/камера/каталог, nullable schema, claim/TTL, routine plan без diagnosis/LLM/списания, missing profile до предложения оплаты. Зависимости: T100–T102/T039/T049/T060. Покрытие: FR-049/050, SC-012/014, V30/V31.
- [ ] T106 Проверить fixed payload, guest proof, A/B isolation, retry/offline и server-only stages в `supabase/functions/_shared/tests/funnel_test.ts` и `ios/PlantsTests/FunnelTrackingTests.swift`. Подтверждённая purchase один раз, restore и смена намерения не новые люди/покупки. Зависимости: T103/T104. Покрытие: FR-051, SC-015, V32. Проверить Free scan/report attribution, trial vs purchase/renewal, reject private note/diagnosis/photo payload, missing windows/usage unknown. Покрытие: SC-025.
- [ ] T107 Создать сервисный отчёт `analytics/intent-funnel.sql` и инструкцию чтения `docs/validation/intent-funnel.md`: первые выборы, переключения и конверсия по intent/method, distinct flow_id, первоначальная ветка отдельно от текущей на этапе. Проверить ожидаемые числа на fixtures обеих веток; не называть flow числом уникальных людей. Зависимости: T103/T106. Покрытие: FR-051, SC-015.

## Phase 10b: Golden Records — offline/runtime (поправка 2026-10-25)

Порядок задают зависимости, не поздние номера. Моки допустимы для разработки;
полный релиз/приёмка требуют реальных прав, данных и отчётов. Все задачи обязательны.

- [ ] T108 Создать `knowledge-base/manifests/source-registry.json` и `knowledge-base/pipeline/rights.py`: все доноры из модуля, operation-level права/terms snapshot/дата, candidate/allowed/blocked/expired, лимиты/LLM use. До сетевого сбора подтвердить права, не обходить 403/paywall. Зависимости: T001. Выполнить до T109/T110 и live ingestion. Покрытие: FR-043/053.
- [ ] T109 Подготовить `knowledge-base/manifests/plant-seed.json` (606 существующих видов, aliases/UUID mapping и покрытие по действиям) и `conditions.json` (ровно 40 IDs из модуля), реализовать `pipeline/taxonomy.py`. Точные species matches, ASPCA cat/dog с unknown и provenance, без глобальной замены рода/догадок severity. Зависимости: T108/T008. Покрытие: FR-052/058.
- [ ] T110 Реализовать async API/HTML adapters `knowledge-base/pipeline/ingest.py` и `pipeline/donors/`: 3–4 независимых донора на запись, Markdown/hash/locator/date/rights snapshot, rate limits/cache/retry и source independence; дефицит → карантин. Зависимости: T108/T109. Покрытие: FR-053.
- [ ] T111 Реализовать Pydantic-модели и Structured Outputs synthesis в `knowledge-base/pipeline/models.py`, `synthesize.py`: совпадение с каноническими JSON Schema, field_evidence, conflict handling, unknown, отдельный offline бюджет/версии. Не изобретать параметры/дозировки. Зависимости: T109/T110. Покрытие: FR-053/054/056/058. Каноническая ConditionProfile содержит visual_markers, diagnostic_disambiguation и treatment_plan; не сохранять прежнюю проектную модель как второй независимый формат.
- [ ] T112 Реализовать `knowledge-base/pipeline/guardrails.py` и `knowledge-base/tests/test_guardrails.py`: No-Misting с учётом purpose, substrate presets/recipes, abiotic priors без подавления явных вредителей, unknown, unit/depth/semi-hydro, противоположные действия/числа и negative fixtures обоих языков. Зависимости: T111. Покрытие: FR-055/056/057. Проверять yes/no targets, локализации вопросов, конечность repeats, duration cap, интервал/варианты/PL label и несовместимость альтернатив (FR-061/063).
- [ ] T113 Реализовать `knowledge-base/pipeline/localize.py` и `knowledge-base/tests/test_localization.py`: EN/PL эквивалентность step IDs, чисел/условий/единиц, понятное объяснение bigos и обязательные safety ограничения. Зависимости: T111/T112. Покрытие: FR-059.
- [ ] T114 Реализовать `knowledge-base/pipeline/pl_market.py`: treatment category/active ingredients/biocontrol → точный SKU, MRiRW/PL label/scope/indoor/non-professional/expiry, затем Allegro/Castorama/Leroy Merlin offer. Товары/бренды задания — кандидаты, не whitelist. <=30 дней, отзыв/unknown → блок; smoke fixtures без реальных неподтверждённых назначений. Зависимости: T108/T112/T113. Покрытие: FR-019/057, SC-018. Не считать бренды примера синонимами; выбранные interval/repeat должны быть разрешены конкретной этикеткой, нет автоматического смешивания препаратов и биоконтроля.
- [ ] T115 Реализовать `knowledge-base/pipeline/publish.py` и `knowledge-base/tests/test_release.py`: независимые партии фактов по виду и действию, evidence/source independence/rights, canonical + semantic validation, quarantine, signed/hash manifest, atomic publish/rollback/pin и отчёт KB01–03/05. Зависимости: T009/T109–T114. Адаптировать прежний импорт T021 и флаг care_profile_available: новые сведения открывают отдельное действие без полного PlantProfile. Хранить совместимость с результатом T147. Проверка полива, признак для действия и недоступный свет — отдельные случаи. Покрытие: FR-052/053/059, SC-016.
- [ ] T116 Реализовать `supabase/functions/_shared/ProtocolResolver.ts` и tests: classification → host/prerequisite checks → первая помощь/объяснение/протокол, fallback healthy/unknown/out-of-scope, treatment blocks; никакой online генерации советов. Backend DTO отдельно от provider schema, бесплатная проекция без full KB; receipt с release. Зависимости: T009/T029/T032/T115/T021/T120. Покрытие: FR-005/019/044/054/057/059/060, SC-017/018. Принимать DTO state решения из T120 (пока через fixtures, без зависимости от реализации DisambiguationService T121): pending/uncertain → готовая безопасная первая помощь, resolved → применимый профиль; без выдуманного уточнения.
- [ ] T117 Дополнить единственный SQL ScheduleCalculator в `supabase/migrations/202610250001_kb_schedule.sql` и `supabase/tests/kb_schedule.test.sql`: версионные season/base/modifiers/clamp, unknown=не применяется, semi-hydro и check_soil_first, история/undo/backdate/DST/access_class INSERT. Новую логику не дублировать в Edge/iOS. Зависимости: T018/T111/T115/T055. Покрытие: FR-023/028/056.
- [ ] T118 Создать `evals/reference-protocol.md` и `evals/tests/reference_integrity_test.ts`: provenance независимых меток/разрешённых фото, фиксация до eval, отсутствие self-labeling и source leakage, coverage 40 проблем и видов вне поддерживаемого каталога. Специалист не обязателен. Зависимости: T109/T108. Выполнить до T093/T094. Покрытие: SC-003/004/016/017. Тестовые ответы уточнений и истинные visual markers фиксировать независимо до запуска (FR-061/064).
- [ ] T119 Выполнить V33–V39 и KB01–KB07 на PL/EN, включая stale/expiry/отзыв/офлайн cache/rollback/TTL, в `docs/validation/knowledge-base.md`; сохранить фактические результаты и ограничения качества/прав. Зависимости: T092/T094/T114–T118/T055/T078. Покрытие: FR-052–060, SC-016–018.

## Phase 10c: Полный промпт — уточнение и лечебный timeline

Ниже дополнение к T108–T119, а не отдельный новый продукт. Не требуется писать
рабочий ingestion/synthesis скрипт в рамках текущего редактирования документации.

- [ ] T120 Реализовать models/validators контрактов ConditionProfile и Vision 3.0 в `supabase/functions/_shared/KnowledgeTypes.ts`, `knowledge-base/pipeline/models.py` и `knowledge-base/tests/test_condition_profile.py`: top-2/confidence/markers, вопросы и EN/PL steps, 40 IDs включая nutrient_deficiency, semantic refs/finite repeats. Зависимости: T005/T009/T011. Покрытие: FR-054/061/063, V43.
- [ ] T121 Реализовать `DisambiguationService.ts`, `plants-api/clarifications.ts` и SQL-команды в `supabase/migrations/202610250002_disambiguation.sql`: для первой диагностики threshold<0.80/gap<0.10, max 2 вопросов; для повторной по тому же экземпляру — ноль, даже при пустом журнале, score от исходного snapshot, skip/uncertain/stale, immutable answer/decision revisions, signed decision_receipt и replay/claim/TTL. Без LLM/квоты. Зависимости: T007/T011/T116/T120/T042/T044. Покрытие: FR-061/064, SC-019, V40.
- [ ] T122 Реализовать `ios/Plants/Features/Analysis/DisambiguationView.swift` и `DisambiguationFlowModel.swift`: после анализа 1–2 вопроса Да/Нет и skip, сохранение pending/current/receipt, restart/back/claim/TTL, EN/PL, safe first action при unsure. Зависимости: T024/T038/T121. Покрытие: FR-061/064, SC-019, V40.
- [ ] T123 Расширить SQL ScheduleCalculator и `supabase/tests/treatment_schedule.test.sql` в `supabase/migrations/202610250003_treatment_schedule.sql`: explicit start, start_offset/interval/total repeat_count, finite timeline/phase/action codes, один ближайший occurrence, PL option/label, late execution/undo/expiry/product blocks; обновить DTO/ReminderScheduler без второй логики расчёта. Зависимости: T055/T075/T077/T117/T120. Покрытие: FR-023/063/064, SC-020, V41. Совместимое выполненное первое действие T135 учитывается в timeline без повторной обработки; один бесплатный контроль не превращается в premium цепочку. Дополнительная зависимость: T135.
- [ ] T124 Добавить optional pot_type/season_override в `CareQuestionsView.swift`, `PreSaveReviewView.swift`, API/plant.edit и `ios/PlantsTests/CareEnvironmentTests.swift`: те же три базовых шага, unknown/auto defaults, manual vs calendar, care_revision/stale, известные модификаторы. Зависимости: T010/T037/T047/T070/T117. Покрытие: FR-056/062, SC-020, V42.
- [ ] T125 Дополнить `evals/run.ts`, `evals/cases/manifest.json` и `evals/reports/quality.json` начальными/final scores, тестовыми ответами, threshold boundary/tie, skip/no question/contradiction, eligibility/PL-EN и итоговым reference match после уточнения. Проверить первую и повторную диагностику: для повторной учесть только актуальные факты ухода экземпляра (record/undo/correct_date), ноль вопросов, безопасный результат при пустой истории. Разделить tuning/held-out, не объявлять model confidence вероятностью; сохранить отсутствие повторного provider call. Зависимости: T094/T118/T121/T122. Покрытие: SC-003/004/019, KB08, V40/V43.
- [ ] T126 Выполнить V40–V43 / KB08–KB10 на PL/EN и записать `docs/validation/full-prompt-addendum.md`: ответы/race/replay/TTL, лечение/подписка/отзыв, optional env, schema/semantic validation и показатели без self-labeling. Зависимости: T119/T122–T125. Покрытие: FR-061–064, SC-019/020.

## Phase 10d: US9 — Progress Report (P2)

Цель: бесплатный итог завершённого местного месяца с фото/наблюдениями и следующими актуальными задачами. Независимая приёмка: V53/V54 на EN/PL с исправлениями, пустыми данными, timezone и двумя аккаунтами.

- [ ] T141 [US9] Реализовать `supabase/functions/_shared/ProgressReportService.ts`, `plants-api/reports.ts` и `supabase/migrations/202611010005_progress_report.sql`: owner GET завершённого month/timezone, период [start,end), active occurred_at/reversals/corrections, фото capture_at/uploaded_at с date_source/наблюдения, upcoming отдельно, coverage/partial/missing_data/data_as_of; no AI/квота и Free доступ. Зависимости: T127/T017/T062/T073/T135. Покрытие: FR-068, SC-009/024, V53.
- [ ] T142 [US9] Создать `ios/Plants/Features/ProgressReport/ProgressReportView.swift`, `ProgressReportRepository.swift` и `Data/Local/ReportCache.swift`: EN/PL, вход из коллекции/дневника, period/пробелы/фото, переход в карточку/задачу; owner/month/timezone/locale/watermark, offline дата кеша/pending отдельно, invalidate по delta. Зависимости: T141/T025/T048/T071. Покрытие: FR-068, SC-024, V53/V54.
- [ ] T143 [US9] Реализовать `ios/Plants/Integrations/Notifications/ReportReminderScheduler.swift`: opt-in, server claim owner+YYYY-MM без timezone, attempt до scheduling, pending/delivered reconciliation без повторной доставки, первый день следующего месяца/час профиля, logout/permission/timezone, доступ к отчёту без push. Зависимости: T128/T075/T084/T142. Покрытие: FR-068, SC-024, V54.
- [ ] T144 [US9] Написать `supabase/tests/progress_report.test.sql` и `ios/PlantsUITests/ProgressReportTests.swift`: совпадение с журналом при undo/переносе даты, неполный/пустой месяц, photo privacy, DST/year/timezone, Free/Trial/Paid/expiry, logout A→B, несколько устройств/сбой claim, отсутствие AI/квоты/ложного здоровья. Зависимости: T141/T142/T143. Покрытие: FR-068, SC-009/024, V53/V54/V56.

## Phase 10e: Сквозная аналитика и приёмка Narat

- [ ] T145 Реализовать server-only `supabase/migrations/202611010006_product_metrics.sql`, `supabase/functions/_shared/UsageLedger.ts`, `analytics/monetization.sql` и `docs/validation/monetization.md`: billing_facts UNIQUE(environment,transaction_id,fact_kind), provider_usage UNIQUE(job_id,provider_attempt_id), unknown cost не ноль; события data-model §6, cohorts/D7/D30/renewal/отказ/возврат, Free scan/report attribution, реальные окна/знаменатели/валюты, без личного содержимого/LTV обещаний. Подключить worker даже для ошибок, billing webhook, T104 к T142; fixtures и сверка NR-A10/V55/V56. Зависимости: T034/T052/T053/T103/T104/T106/T107/T132/T142. Покрытие: FR-051, SC-015/025.
- [ ] T146 Выполнить NR-A1–10 и V44–V56 на PL/EN, сохранить реальные результаты в `docs/validation/narat-access-report.md`: quotas/concurrency, Free slots/first aid, trial/expiry/cache, transitions/report/analytics, offline/account isolation; не отмечать pass по документам. Зависимости: T030/T131/T134/T137/T140/T144/T145/T126. Покрытие: FR-015–023/051/065–068, SC-008/014/021–025.

## Phase 11: Приёмка, reference-based eval и закрытие Release Gates

- [ ] T092 Проверить итоговое покрытие фактов ухода по SC-016 (не менее 300 видов с применимой проверкой полива, отчёт по всем 606) и отдельно опубликовать 40 протоколов проблем, PL/EN, safety cat/dog, права/атрибуцию, товары PL и validation report в `knowledge-base/releases/` и `catalogue/licenses/attribution.json`. Зависимости: T108–T115; неполный manifest не публикуется. Покрытие: FR-042–044/052/053/055/057–059, SC-010/016.
- [ ] T093 Сформировать заранее размеченные минимум 200 reference cases в `evals/cases/manifest.json` и `evals/expected/labels.json` по независимым от синтеза/классификатора источникам с разрешёнными фото. Специалист не обязателен; метки/условия/допустимые действия закрепить до eval, не выдавать reference match за экспертную сертификацию. Зависимости: T118. Покрытие: SC-003/004.
- [ ] T094 Запустить Haiku 5.5 classification + ProtocolResolver eval отдельно PL/EN в `evals/run.ts`; сохранить `evals/reports/quality.json` (вид >=85%, основная причина >=80%, первое действие reference match >=90%, uncertainty >=90%). Проверить closed IDs, out-of-scope, identification-only, provenance действий и запрет online генерации планов. Зависимости: T032/T092/T093/T116; source leakage audit обязателен. Покрытие: SC-003/004/017.
- [ ] T095 Измерить задержку анализа (`SC-002`: >= 95% попыток <= 30 сек, таймаут <= 60 сек) и нагрузочную работу квот в `evals/reports/performance.json` и `supabase/functions/_shared/tests/load_admission_test.ts`. Покрытие: SC-002, SC-008.
- [ ] T096 Провести usability-испытания (**SC-001, SC-007, SC-012, SC-013, SC-014**) минимум на 20 участниках для каждого языка (`PL`/`EN`) и проверку локализации редакторами в `docs/validation/usability-localization.md`. Для FR-046–FR-048 проверить понятность подтверждения/правок и next step; SC-012: >=90% выбора путей и сохранения каталога <=90с; SC-013: >=90% понимания действия/основания/проверки. Покрытие: FR-046–FR-048, SC-001, SC-007, SC-011–SC-014. SC-012 расширен до трёх заданий: problem/scan, care/scan и care/catalogue; проверить понимание раздельных стартовых попыток и месячной Free-квоты и персонального обычного плана.
- [ ] T097 Настроить боевые/Sandbox интеграции Apple, Google, Supabase и StoreKit и задокументировать прохождение `G01/G02/G07` в `docs/validation/integrations.md`.
- [ ] T098 Выполнить V01–V56 на PL/EN в `docs/validation/mvp-acceptance.md`; перед приёмкой T100–T146 завершены (ID сохранены, порядок — по зависимостям). Проверить FR-001–068 и SC-001–025, NR-A1–10, права/кеш/схемы/pin/stale/300-40. Это будущая приёмка, не отмечать выполненной по наличию документов. Зависимости: T126/T131/T134/T137/T140/T144/T145/T146/T096/T097.
- [ ] T099 Сверить quickstart/KB module и закрыть G01–G08 / KB01–KB10 в `docs/validation/release-gates.md`; все T108–T126 обязательны. Не утверждать импорт, rights audit, live compatibility или качество без отчётов. Зависимости: T098. Закрыть также US9/Free/trial/Progress Report/analytics; нет pass без доказательств.

## Dependencies and execution order

Ниже зависимости полного MVP. Для ближайшего исполнения действует порядок 2026-11-07 в начале файла; базовый каталог не ждёт полного US1/KB.

1. T001–T006 → T007–T015 → транзакционные сервисы T017–T020 и foundation клиента T022–T027. Схема/общие роутеры/локализация изменяются последовательно; [P] действует только после prerequisites.
2. T028/T029 → T030–T038 → T039 закрывают US1. T087 (физический прототип G03) выполняется после T002/T022 до приёмки камеры, несмотря на поздний ID; T088/T089/T090 интегрируют LightingEstimating после прототипа.
3. US2 зависит от US1 для guest claim; каталог можно проверить на foundation/fixtures. T040 → T041–T048 → T049.
4. US3 зависит от сохранённого экземпляра US2; billing fixtures доступны раньше live Sandbox. T050/T051 → T052–T059 → T060. Общая SQL-функция расписания уже создаётся T018.
5. US4 использует планы/fixtures US3 и SQL foundation; T061–T068 завершаются до US5 (T069–T074). US6 (T075–T081) использует задачи и историю US4/US5. US7 (T082–T086) завершает профиль/настройку часа для интеграционных проверок US6.
6. T091 проверяет US8 на устройствах после интеграции с US1/US2. T092–T099 проходят после соответствующих stories; G01–G08/KB01–KB10 и SC-001–SC-025 обязательны до выпуска. Все 9 историй P1 и P2 входят в MVP; закончить только US1 недостаточно.

7. Поправка намерений: foundation T010/T011/T022/T023 и классификационная схема 3.0 → T100/T101 → T102; серверная воронка T103 → клиент T104 → T106/T107; T105 проверяет маршруты. Все T100–T107 → T096/T098/T099.
8. KB: T108 → T109 → T110 → T111 → T112 → T113/T114 → T115 → T021; T029/T032 → T116 → T055 → T117; T108/T109 → T118 → T093 → T094; T092/T094/T114–T118 → T119 → T098/T099. Этот порядок заменяет прежнюю приёмку каталога/AI-plan; offline синтез не лежит в runtime user path.

9. Полный промпт: T005/T009/T011 → T120; T116/T120 → T121 → T122; T055/T117/T120 → T123; T010/T037/T047/T070/T117 → T124; T094/T118/T121/T122 → T125; T119/T122–T125 → T126 → T098/T099.

### Возможности параллельной работы

Это свойства зависимостей задач, а не поручение запускать агентов. После foundation можно независимо писать T028/T029 (US1), T050/T051 (US3), T075/T076 (US6); T069 и T073 (US5) работают с разными файлами после готовой схемы/PhotoKit. В US2, US4 и US7 общие команды/миграции выполняются последовательно. T088 использует отдельный test file после прототипа US8; T061 не имеет [P].

### Independent acceptance per story

| Story | Проверяемый законченный маршрут |
| --- | --- |
| US1 | US1.1–US1.15, фото >10 МБ, starter/Free/Paid retry и первый экран помощи; T039, T096 |
| US2 | US2.1–US2.18, scan/catalogue/claim/fallback, намерение/next step; T049, T105 |
| US3 | US3.1–US3.13, billing, stale plan без квоты, recovery check; T060 |
| US4 | US4.1–US4.9, offline/undo/backdate/needs_review/check_soil_first; T063, T068 |
| US5 | US5.1–US5.6, стабильный экземпляр и фотодневник; T074 |
| US6 | US6.1–US6.5, выбранный час и контрольное фото того же экземпляра; T075, T081 |
| US7 | US7.1–US7.5, профиль/час/язык/delete/изоляция; T086 |
| US8 | US8.1–US8.3, подсказка, подтверждение/unknown на реальном устройстве; T091 |
| US9 | US9.1–US9.6, завершённый местный месяц/исправления/права/уведомление; T141–T144 |

## Requirement Traceability

Поддерживающие задачи также имеют основание: T001/T003/T004/T005/T006/T019/T024/T097/T099 обеспечивают конституционные границы стека, секретов, CI, G01/G02/G07 и общую проверку; T012 создаёт billing foundation для FR-015–FR-021. Они не являются отдельными продуктовыми функциями.

Связи ниже — план покрытия, а не утверждение, что код/испытания выполнены. Централизованные constraints находятся в data-model.md и contracts/; дублирующие автогенерированные блоки в задачах не требуются.

| Requirement | Tasks | Проверка |
| --- | --- | --- |
| FR-001 | T027, T037, T039, T096 | PL/EN UI и результаты |
| FR-002 | T037, T039 | один снимок, три вопроса, помощь до входа |
| FR-003 | T031, T035, T039 | камера/галерея/замена |
| FR-004 | T010, T037, T039 | ответы/unknown/прогресс |
| FR-005 | T013, T028, T030, T033, T036, T039 | starter ID=1/diagnosis=1, бесплатный результат |
| FR-006 | T029, T031, T032, T035, T039 | нормализация >10 МБ и честная ошибка |
| FR-007 | T033, T034, T038, T039, T095 | jobs/ожидание/retry/deadline |
| FR-008 | T040, T041, T049 | native sign-in и отмена |
| FR-009 | T040, T042, T043, T044, T046, T049 | claim и fallback после TTL |
| FR-010 | T017, T025, T042, T044, T049 | идемпотентное сохранение |
| FR-011 | T010, T044, T047, T049 | необязательная комната/создание |
| FR-012 | T010, T044, T049 | удаление комнаты сохраняет растения |
| FR-013 | T048, T071, T074 | явный доступ к истории/условиям |
| FR-014 | T044, T047, T049, T055 | каталог без фото/анализа |
| FR-015 | T050, T057, T058, T060 | два тарифа, voluntary trial и прозрачная граница |
| FR-016 | T002, T057, T058, T060 | ориентиры и реальные StoreKit цены |
| FR-017 | T020, T028, T030, T050, T054, T060 | active/grace и 100/мес |
| FR-018 | T050, T052, T057, T060 | restore и ownership |
| FR-019 | T009, T051, T055, T056, T058, T060 | объяснения, продукты, recovery_check |
| FR-020 | T020, T053, T056, T059, T060 | expiry сохраняет чтение прежних планов |
| FR-021 | T057, T060, T084 | управление подпиской |
| FR-022 | T063, T066, T068 | today/overdue/add |
| FR-023 | T018, T020, T055, T056, T062, T063 | access_class INSERT, check_soil_first |
| FR-024 | T017, T062, T063, T065, T068 | один факт на операцию |
| FR-025 | T023, T025, T026, T062, T065, T068 | устойчивый outbox, нет revision-диалогов |
| FR-026 | T062, T063, T067, T068 | undo без потери истории |
| FR-027 | T018, T062, T063, T067, T068 | фактическая дата и запрет будущего |
| FR-028 | T018, T062, T063, T066, T069, T070, T075 | пересчёт и неблокирующий needs_review |
| FR-029 | T018, T061, T063, T067, T068 | причина смены даты |
| FR-030 | T018, T064, T068, T075 | local date/timezone |
| FR-031 | T069, T070, T071, T074 | правка без потери экземпляра |
| FR-032 | T070, T072, T073, T074 | фото/экспорт |
| FR-033 | T035, T073, T075, T080, T090 | отказы разрешений |
| FR-034 | T022, T037, T087, T088, T089, T090, T091 | приблизительная camera hint |
| FR-035 | T007, T075, T077, T080, T084, T086 | default 09:00 и выбор часа |
| FR-036 | T075, T077, T081, T086 | актуальные reminders без дублей |
| FR-037 | T011, T056, T072, T076, T079, T081 | контрольное фото/признаки/ракурс |
| FR-038 | T076, T078, T079, T081 | оценка динамики с историей |
| FR-039 | T007, T083, T084, T086 | профиль и час |
| FR-040 | T014, T082, T083, T084, T086 | удаление и подписка |
| FR-041 | T015, T016, T026, T082, T085, T086 | owner isolation и secrets |
| FR-042 | T008, T021, T045, T074, T092 | PL/EN/Latin/synonyms |
| FR-043 | T008, T021, T045, T092 | лицензии/атрибуция |
| FR-044 | T009, T021, T029, T032, T055, T092 | reviewed care, safety cat/dog с unknown |
| FR-045 | T027, T033, T039, T059, T084, T085, T086 | язык до входа и история |
| FR-046 | T010, T011, T040, T042, T047, T049, T051, T055, T060 | overrides/snapshot/stale/plan без квоты |
| FR-047 | T010, T022, T047, T049, T090, T091 | source/confirmation/unknown |
| FR-048 | T042, T044, T046, T047, T049 | next_available_step и TTL fallback |
| FR-049 | T010, T022, T023, T037, T047, T100, T104, T105 | намерение отдельно от метода, возврат/повторный запуск |
| FR-050 | T005, T010, T011, T028–T033, T040, T047, T055, T058, T101, T102, T105 | care scan/catalogue, подтверждение, условия, routine plan |
| FR-051 | T103, T104, T106, T107 | события по веткам, server purchase, без дублей/приватного контента |
| SC-001 | T039, T096 | >=90% / >=20 на язык, помощь <=3мин |
| SC-002 | T034, T095 | >=95/100 до 30с, ошибка к 60с |
| SC-003 | T093, T094 | вид >=85%, причина >=80% |
| SC-004 | T093, T094 | действие и uncertainty >=90% |
| SC-005 | T026, T063, T068, T098 | повтор/обрыв/перезапуск без дублей |
| SC-006 | T063, T069, T074, T098 | история/фото сохраняются |
| SC-007 | T068, T074, T096 | исправления <=60с |
| SC-008 | T028, T050, T054, T060, T095, T098 | billing/starter/Free/Paid concurrency |
| SC-009 | T016, T082, T086, T098 | A/B и разрешения |
| SC-010 | T021, T092, T096, T098 | источники/лицензии/редакторы |
| SC-011 | T027, T039, T086, T096, T098 | все маршруты PL/EN |
| SC-012 | T047, T049, T096, T098, T100, T101, T105 | problem/scan, care/scan, care/catalogue; каталог <=90с |
| SC-013 | T038, T058, T060, T096, T098 | действие/основание/срок/признак |
| SC-014 | T040, T049, T051, T060, T090, T091, T096, T098 | подтверждение света, unknown, stale plan/TTL без квоты |
| SC-015 | T106, T107, T098 | сверка метрик обеих веток и переключений |

### Traceability поправки Golden Records

| Требования | Задачи | Приёмка |
| --- | --- | --- |
| FR-052 | T008/T009/T109/T115/T092 | KB01, V36, SC-016 |
| FR-053 | T108/T110/T111/T115/T118 | KB02/03/06, V36, SC-016 |
| FR-054 | T005/T029/T032/T055/T116 | KB04, V33/34, SC-017 |
| FR-055 | T112/T116 | KB03/04, V33/36, SC-017 |
| FR-056 | T018/T111/T117 | V35, SC-017 |
| FR-057 | T009/T114/T116/T119 | KB05, V38, SC-018 |
| FR-058 | T009/T109/T111/T113/T119 | V37, SC-018 |
| FR-059 | T008/T011/T113/T115/T116/T119 | V39, SC-016/018 |
| FR-060 | T051/T055/T078/T116/T119 | V34, SC-017/018 |
| SC-016 | T092/T108–T115/T118/T119 | KB01–03/06 |
| SC-017 | T094/T112/T116/T117/T119 | KB04/06/07 |
| SC-018 | T114/T115/T116/T119 | KB05/07 |

Исторический блок T001–T146 дополнен T147–T154. Старые ID сохранены,
содержание затронутых задач обновлено вместо дублирования старой архитектуры.

### Traceability полного промпта

| Требования | Задачи | Приёмка |
| --- | --- | --- |
| FR-061 | T120/T121/T122/T125/T126 | KB08, V40/43, SC-019 |
| FR-062 | T010/T117/T124/T126 | KB10, V42, SC-020 |
| FR-063 | T011/T051/T055/T120/T123/T126 | KB09, V41, SC-020 |
| FR-064 | T011/T040/T121/T122/T123/T126 | V40/41, SC-019/020 |
| SC-019 | T121/T122/T125/T126 | V40/43 |
| SC-020 | T123/T124/T126 | V41/42 |

### Traceability Narat (заменяет прежнюю семантику доступа)

| Требование | Задачи | Приёмка |
| --- | --- | --- |
| FR-005 / FR-065 | T007/T013/T028/T030/T036/T042/T054/T146 | V01/V16–18/V44/V45/V50, SC-008 |
| FR-015 / FR-016 / FR-017 / FR-018 / FR-021 | T002/T012/T050/T052–T058/T084/T132–T134/T146 | V08/V48–V50, SC-008/022 |
| FR-020 | T015/T020/T025/T054/T056/T059/T134 | V09/V21/V50 |
| FR-022 | T066/T139/T140 | V52, SC-023 |
| FR-023 / FR-028 / FR-048 / FR-050 | T018/T020/T022/T055/T062/T063/T075/T102/T127/T129–T131 | V20/V21/V46/V48/V50, SC-014/021/022 |
| FR-051 | T103–T107/T145/T146 | V32/V55/V56, SC-015/025 |
| FR-066 | T127/T135–T137/T123/T146 | V10/V41/V47, SC-022 |
| FR-067 | T138–T140/T146 | V51/V52/V56, SC-023 |
| FR-068 | T128/T141–T144/T146 | US9, V53/V54, SC-024 |
| SC-021 | T129/T130/T131/T063/T134/T146 | Free-повторы/места/expiry |
| SC-022 | T102/T132/T134/T135–T137/T146 | бесплатный следующий шаг/контроль/контекст покупки |
| SC-023 | T138/T139/T140/T146 | восстановление/пустой день/перерыв |
| SC-024 | T128/T141–T144/T146 | журнал/периоды/права/уведомление отчёта |
| SC-025 | T103–T107/T145/T146 | фактические события/затраты/окна когорт |

### Исполнение дополнений и контроль зависимостей

ID T001–T126 сохранены для существующих ссылок; T127–T146 встроены в соответствующие истории.
Номер ID не является порядком выполнения. Foundation T007/T010/T011/T012 → T127 → T015/T018;
T017/T019/T020/T127 → T128 → T025. SQL schema T127 дополняет ранние draft-файлы до первого db reset;
поздние November migrations добавляют только команды/projections, не поля, нужные ранним функциям.
KB preparation T108–T115 и T120 выполняется до зависящих от него импорта/классификатора/PlanService,
несмотря на размещение разделов; запись моделей T111/T120 последовательная, не параллельная.
T055/T117 → T129 → T130; T062/T116/T121 → T135 → T136; T135 → T123;
T130/T136 → T102 → T104/T105. US3 core T052–T058 → T132; notifications/profile T075/T084 → T133 → T134.
T123/T129/T135 → T138, T066/T067/T129 → T139, затем T140. T141→T142→T143→T144;
T104/T142→T145; приёмка stories/KB → T146 → T098 → T099.

Внутренние срезы: foundation/fixtures → guest помощь и catalogue/basic care → full/trial/history →
ежедневный уход/контроль → reminders/переход → US9 и метрики. Каждый срез проверяется на EN/PL;
это не сокращение согласованного MVP. Внешние G01/G02/G07 и KB/eval остаются обязательны.
После prerequisites независимо можно выполнять T028/T029 и писать тестовые fixtures T050/T051; SQL/RLS/shared router/localization и T111/T120 выполняются последовательно.


## Phase 12: Convergence

Новые задачи закрывают сквозные разрывы, выявленные 2026-11-07. Остальной объём учтён в существующих задачах.

- [ ] T152 CRITICAL Устранить фиктивные пользовательские результаты и подтверждения в `ios/Plants/Features/Analysis/AnalysisFlowModel.swift`, `CareQuestionsView.swift`, `PreliminaryResultView.swift` и `supabase/functions/plants-api/index.ts`: демонстрационные фото/диагноз/receipt/квоты допустимы только в явных тестовых зависимостях; штатная сборка сообщает о недоступности анализа и даёт возврат/каталог, без пустого экрана. Пока persistence не подключён, commands/sync возвращают явную ошибку, outbox сохраняет намерение. Проверить care/scan, problem/scan, отсутствие ложной успешной записи и повтор. Основание: конституция II/IV, FR-005/007/010/024/044/054, SC-005/017 (contradicts). Не заменяет T019/T038/T039.
- [ ] T153 Согласовать и реализовать независимый identification для T150 в `contracts/api.md`, `supabase/functions/_shared/AnthropicAdapter.ts`, `KnowledgeTypes.ts` и `analysis-worker/index.ts`: закрепить версию опубликованного каталога, closed species IDs, unknown/out-of-scope, происхождение результата и receipt без требования полного care/condition release. Сначала сверить текущий контракт kb_release_id с независимой публикацией T147; никаких советов от модели. Проверить отсутствие care/condition KB, отклонённый вид и сохранность версии. Основание: FR-014/050/052/054/059, T147/T150, plan: независимый каталог (partial).
- [ ] T154 Проверить развёрнутые изменения инфраструктуры в `supabase/tests/` и `docs/validation/integrations.md`: чистая установка и обновление со старых 18 миграций до текущих 21, права RPC anon/authenticated/service_role, приватный Storage после T015, гостевой профиль и переход к постоянному аккаунту, повтор регистрации/обновление сессии, сохранность владельца. Зафиксировать повторяемые команды, rollback тестовых данных и разделение fixtures/live; синхронизировать версии/конфигурации стенда и локальной БД. Основание: FR-008/009/041, SC-005/009, T097, plan: Supabase/Auth/RLS (partial).
