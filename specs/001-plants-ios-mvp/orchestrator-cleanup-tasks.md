# Пакеты задач для оркестратора — 9 ноября 2026

Источник: [аудит текущего кода](../../docs/handoff_status.md), [принятые упрощения](../../docs/validation/spec-simplification-2026-11-09.md). ID и статусы находятся в [tasks.md](tasks.md). Это задания для подготовки отдельных запусков, **не исполняемый JSON manifest**. Реализация и запуск очереди этим документом не подтверждаются.

Комнаты запрошены отдельной задачей после очистки: простая группировка, название, список растений, фильтр. Основание — обсуждение в чате «Проверить спецификацию на оверинжиниринг» и поручение владельца создать задачу на возврат. Комнаты остаются отдельным необязательным расширением; их наличие не блокирует приёмку MVP.

## Передача в исполнение

Контроллер берёт один пакет, перечитывает текущий HEAD и материализует `tools/automation/tasks.<id>.json` по существующему формату: точные `files`/`write_files`, `constraints`, `acceptance_criteria`, `checks`, `mode`. Перечни ниже — границы подготовки; каталог миграций не является разрешением менять все файлы. Новый migration filename выбирается после последнего принятого номера. Старые SQL неизменны.

Перед `run` контроллер готовит и проверяет исполняемые проверки каждого AC. Для SQL нужен отдельный настоящий PostgreSQL17/pgTAP clean/seeded-upgrade runner, отрицательные проверки и реальные гонки, где они указаны. Старый `t158-rooms-upgrade` проверяет удаление комнат и не подходит для их возврата или новых тарифов. Нельзя заменить SQL-проверку `deno-tests`, поиском строки или наличием файла. Gate/config и изменения smoke-инструментов принадлежат контроллеру: `tools/automation/` защищён от agent patch. Для изменённого UI контроллер заранее обновляет устаревшие welcome/Simulator ожидания; нельзя требовать одновременно старую и новую навигацию.

После подготовки — `orchestrator.py validate`, просмотр `context`, чистый Git и отдельный run. Для разных manifest внешние зависимости проверяет контроллер по принятому коду/отчётам: не вставлять отсутствующие ID в `depends_on` и не считать зависимость выполненной по Markdown. Внутри manifest использовать реальные ID задач этого manifest. Новая задача не должна автоматически запускать всю очередь или комнаты.

Общие проверки: `deno-tests` (fixture) и `deno-check` (local) для backend; `ios-tests` и `simulator-smoke` (local) для клиента; `diff-check` (local). Специальные проверки перечислены в каждом пакете. Отсутствующий runner — работа подготовки, а не PASS и не повод убрать AC. Review/QA независимы. Реальные интеграции фиксируются отдельно от fixtures. Parent T155/T157–T160 не закрывать по одному пакету.

Общие ограничения: сохранять owners/RLS, фото, пользовательскую историю, operation receipts, расход, общий sync/outbox и pending/error состояние; не вводить фиктивные успехи. Никаких deploy, удаления пользовательских данных, переписывания applied migrations или force push. Проверки приёма нового ввода отделять от чтения старого cache/receipt. В handoff записывать точный результат, ограничения и следующий шаг, затем commit/push управляющим процессом.

## Очередь и зависимости

| ID | Пакет | Родитель / внешняя предпосылка | Зависимости пакетов |
| --- | --- | --- | --- |
| T161 | Убрать Free-места, ввести атомарный cap на сервере | T158; принятый room retirement | — |
| T162 | Удалить FreeSelection и согласовать клиент | T158/T022/T025 | T161 |
| T163 | Месяцы от регистрации и Free=3/paid=100 | T158/T007/T012/T013/T028/T030 | T161 |
| T164 | Остановить всю автоматику после expiry | T158/T020/T064 | T162, T163 |
| T165 | Удалить отчёты и server notification claims | T159/T084/T128 | — |
| T166 | Восстановить guest claim без deleted fallback | T159/T019/T042/T150; реальные auth/media adapters для live | T161, T163 |
| T167 | Убрать товарный таймер и активные product blocks | T159/T009/T059/T114 | — |
| T168 | Удалить новый ввод камеры света | OLD-02/T010/T022/T037 | — |
| T169 | Удалить сезонные overrides | T160/T022/T047 | T166, T168 |
| T170 | Простой вход и единый результат | OE-13/T038/T039; реальные analysis/save для итогового маршрута | T162, T166, T168 |
| T171 | Простой уход вместо старых зависимостей | T160/T018/T051/T062/T063/T075; опубликованные применимые карточки T111–T116 | T164, T165, T167, T169 |
| T172 | Простые комнаты: сервер и sync | Отдельное расширение; [контракт](contracts/simple-rooms.md) | T161, T166, T169 |
| T173 | Простые комнаты: клиент и UI | Рабочие коллекция/карточка T049/T051 | T162, T170, T172 |
| T174 | Сквозная приёмка простых комнат | T154/live auth/API/Storage и два test owner | T171, T173 |

Сначала T161 → T162 → T163 → T164. Независимые T165/T167/T168 допускают отдельные последовательные запуски. T166 предшествует правкам guest context/UI. Комнаты — отдельная очередь T172 → T173 → T174, не часть автоматического запуска очистки. Независимость не означает разрешения запускать конкурирующие контроллеры.

## T161 — Free-места → ограничение коллекции

**Результат:** новые экземпляры на Free создаются только при числе неудалённых растений <3, paid без лимита коллекции. `free_care.select`, автоматический выбор трёх и активные slot projections прекращаются. Исторические memberships/flags остаются читаемыми в истории. Не возвращать автоматическую тройку после paid expiry.

**Scope:** новая migration; `supabase/functions/_shared/{BasicCareService,EntitlementGate}.ts`, `plants-api/basic-care.ts`; `free_care.test.sql`, новые `collection_cap.test.sql`/seed; `foundational_services_test.ts`. Читать последние `execute_plant_create_command`, `commit_guest_claim`, `compute_next_available_step`, `execute_basic_care_command`, `can_owner_schedule_rule`, `owner_sync_entries` и command router. T166 чинит положительный guest, но cap должен быть заложен во все writers и повторно проверен там. API/sync тексты согласовать в этом scope.

**AC:** (1) Free 0/2/3 и paid >3, два одинаковых retry и два разных конкурентных создания при count=2: один свободный остаток, без дубля/обхода; (2) отказ retired select без мутации, прежний точный receipt возвращается, hash mismatch конфликтует; (3) clean/upgrade сохраняет владельцев/историю/расход, RLS A/B, projections без slots; (4) никакого скрытого назначения первых трёх. Не выдавать пока неисправный guest за проверенный.

**Gate подготовки:** PostgreSQL clean/upgrade + два реальных соединения с наблюдаемым lock; Deno behavior/typecheck. Нужен новый runner коллекции, существующий room gate не заменяет его. Риск высокий.

## T162 — Клиент без FreeSelection

**Результат:** убрать `FreeSelection`, активные `freeSlot`/selection revision/profile flags и UI выбора тройки; показать серверный cap до сохранения, различать pending/ошибку/подтверждение.

**Scope:** `ios/Plants/Domain/PlantTypes.swift`, `Data/Remote/{APIModels,PlantsAPIClient}.swift`, `Data/Sync/SyncEngine.swift`, `Data/Local/LocalStore.swift`, существующие catalogue/result views и `SyncPersistenceTests.swift`. Новый UI-файл допускается только после включения точного пути в manifest.

**AC:** decode старого сохранённого JSON без потери прочих полей, новые writers не посылают slot keys; cap/server rejection не теряет ввод и не создаёт локальное ложное сохранение; restart/owner switch/retry сохраняют pending и историю. Paid не получает экран выбора трёх. Исторические raw memberships не стираются. Backend T161 обязателен.

**Gate:** реальные Swift persistence/encoding/limit cases и UI Free/paid/error, build/unit/Simulator. Welcome smoke сам по себе недостаточен. Риск средний.

## T163 — Единый месячный период

**Результат:** убрать Free=1 и UTC-month/first-starter anchor. После регистрации общий период от регистрации, Free=3, paid/trial=100; starter правила и стоимость успешного анализа — по FR-065.

**Scope:** новая migration для quota/billing/profile RPC; `_shared/AnalysisAccess.ts`, `plants-api/{analysis-access,installations,analysis}.ts`, worker при затронутом reserve/finalize, Swift access DTO/repository; `quota_admission.test.sql`, `analysis_mode_guard.test.sql`, новые seed/concurrency tests. Сначала зафиксировать правило короткого месяца/UTC instant и таблицу перехода старых reservations/consumed без двойного счёта.

**AC:** последний день месяца/високосный февраль/граница периода; starter своего режима на Free, paid quota на paid; смена тарифа/restore/trial/expiry не меняет anchor и не обнуляет расход. 20 реальных одновременных запросов на последний остаток, retry/finalizeOnce/technical failure без лишнего списания. Upgrade старых buckets/reservations с сопоставлением ledger, owner A/B, UI remaining/reset согласован с сервером. При неопределимом историческом расходе — явная ошибка/зафиксированная политика, не бесплатный reset.

**Gate:** новый PostgreSQL quota clean/upgrade/concurrency runner, Deno и Swift tests. Проверка StoreKit на fixture отдельно от live. Риск высокий.

## T164 — Expiry без автоматической Free-тройки

**Результат:** после конца подтверждённого paid/trial все автоматические задачи и напоминания коллекции остановлены, включая первые три. Чтение и ручной журнал/undo/backdate доступны. Отключение auto-renew не означает немедленное expiry.

**Scope:** новая migration schedule/access projection, `EntitlementGate.ts`, `SyncEngine.swift`, care/notification consumers (точные пути определить перед manifest), SQL schedule tests и Swift sync/notification tests.

**AC:** active/grace/expired/revoked/billing_retry с проверенными датами; expiry при offline/restart/смене owner не оставляет локальных reminders; ручной record/undo не оживляет автоматику. Повторная подписка не активирует неприменимое/paused. Expiry→Free не меняет размер коллекции/историю, новое добавление только count<3. Paid quota exhaustion отдельно от care access.

**Gate:** PostgreSQL schedule/access upgrade, Deno entitlement, реальные локальные notification scheduling/cancellation tests с управляемым временем. Не объявлять операционную систему доставившей уведомление по одному вызову mock. Риск высокий.

## T165 — Отчёты и claims уведомлений

**Результат:** убрать monthly report DTO/cache/preferences/projections, API `/notifications/claim` и распределённый trial claim; оставить локальное opt-in напоминание по подтверждённому trial end.

**Scope:** `plants-api/{notifications,index}.ts`, новая migration RPC/sync/profile projection; `APIModels.swift`, `SyncEngine.swift`, новый `ios/Plants/Integrations/Notifications/TrialReminderService.swift` и тест; `foundational_services_test.ts`, persistence tests. Контроллер отдельно обновляет устаревшие check entrypoints при удалении файла.

**AC:** старый endpoint не пишет claim, прямой RPC тоже не создаёт новый claim; historical receipts/rows сохраняются. Новая delta/profile без report/claim keys; owner switch/restart не возвращают кеш отчёта. Opt-in по умолчанию off; permission denied, отменённый/истёкший/изменившийся trial, logout корректно отменяют локальный reminder. Нет обещания единственного уведомления на всех устройствах, billing facts не зависят от reminder.

**Gate:** SQL negative/upgrade, Deno route tests, Swift local scheduling/cancellation и старый cache read. Риск средний.

## T166 — Guest семь дней без local_fallback

**Результат:** согласовать реальные таблицы и prepare/copy/commit/cleanup; живой draft доступен семь суток от success. Удалённый/expired draft не восстанавливается из клиентского JSON/receipt и не запускает скрытый AI.

**Scope:** новая migration последнего guest/create RPC, `plants-api/claims.ts`, `maintenance/guest-claims.ts`, router и media adapters по фактическим consumers; `ProtocolResolver.ts` только для решения судьбы подписи; Swift guest/auth/cache DTO; `guest_claim.test.sql`, `claim_transfer_test.ts`, новые upgrade/media race fixtures. `.env.example` и другие protected files правит контроллер после проверки consumers, не агент.

**AC:** положительный prepare→media→commit с настоящими RPC сигнатурами; wrong owner/proof, replay/mismatch, до/на/после TTL, concurrent cleanup/commit, потерянный ответ, partial media failure; один plant/receipt, cap из T161, starter/расход из T163 не сбрасывается. Ввод переживает отмену входа; кеш удаляется только после подтверждения. `local_fallback` явно отвергается. Подписанный `analysis_receipt` удалять только если все необходимые consumers заменены; operation receipts/claim proof/проверка покупки остаются. Legacy signed history не переписывать.

**Gate:** новый PostgreSQL guest clean/upgrade/race, Deno media/claims, Swift disk restart; отдельная live API/Storage проверка для сквозной приёмки T042/T150. Fixtures могут принять узкий кодовый срез, но не закрыть live-зависимые parents. Риск высокий; при большом diff делить prepare и commit/media на зависимые manifest.

## T167 — Убрать товарную зависимость

**Результат:** удалить активный SKU/offer/30-day timer/product-block путь. Применимость действующих веществ, права источников и подтверждённые безопасные рекомендации сохраняются.

**Scope:** `EntitlementGate.ts`, `SyncEngine.swift`, `KnowledgeTypes.ts`/`ProtocolResolver.ts` только при найденных consumers, новая migration plan read/schedule/редакционных writers; соответствующие Deno/Swift/SQL tests. Таблицы `product_evidence`/`treatment_blocks` сохраняются как история; не считать удаление таблиц условием готовности.

**AC:** старая дата chemical revalidation не запрещает сама по себе новый допустимый совет; неизвестная/отозванная/неприменимая рекомендация по-прежнему не исполняется. Новый результат и schedule не требуют SKU/offer/product block. История после expiry читается owner; новый advice формируется только из применимой карточки, без выдуманного вещества/дозировки. Regression текущих compact profiles.

**Gate:** SQL read/schedule upgrade, Deno applicability и Swift cached plan. Риск высокий из-за изменения оснований запрета рекомендаций.

## T168 — Удалить камеру света

**Результат:** новые условия света только manual/unknown; убрать `applyEstimatedLighting`, новый camera estimate contract и obsolete protocol. Исторический camera estimate остаётся историческим, не становится ручным подтверждением.

**Scope:** `PlantTypes.swift`, `AnalysisFlowModel.swift`, `APIModels.swift`, `claims.ts`, analysis/provider input validators; новая migration guards condition writers; `SyncPersistenceTests.swift`/Deno input tests/SQL guards. Читать все light_source consumers, включая несовпадение Swift manual и TS manual_selection.

**AC:** новый camera input явно отклоняется через API и прямой service RPC; manual/unknown согласованы TS/Swift/SQL, неизвестное не подтверждено автоматически. Decode старого cache/history сохраняет значение/происхождение; повторная отправка требует текущий разрешённый ввод. Удалены только tests новой camera-функции, историческое чтение покрыто.

**Gate:** SQL guards/upgrade, Deno validation, Swift old cache/manual UI. Риск средний.

## T169 — Убрать сезонный override

**Результат:** пользователь не задаёт расширенные сезонные overrides; старые snapshot поля не влияют на новый анализ/расчёт. Опубликованные сезонные факты каталога не удаляются.

**Scope:** Swift conditions/claim DTO, `claims.ts`, `analysis.ts`, worker/`AnthropicAdapter.ts`, новая migration condition writers/sync; SQL/Deno/Swift regressions. Не переписывать snapshots, каталог JSON/SQLite или историю подписей.

**AC:** active writers/prompt/projections без override, новый запрещённый ключ явно отвергается; чтение старого snapshot не теряет другие условия. Старый summer/winter и Swift spring_summer не конвертируются в выдуманные новые факты. Ручные условия и обычные опубликованные правила продолжают работать. Не строить универсальный seasonal engine.

**Gate:** SQL input/projection upgrade, provider payload tests, Swift legacy decode/re-encode. Риск средний.

## T170 — Простой вход и единый результат

**Результат:** основное действие «Проверить растение», каталог/определение как альтернативы. Убрать обязательный intent screen и активные diagnosticRefinement/preSaveReview/postSaveNextStep, единый результат с сохранением.

**Scope:** `PlantsApp.swift`, `AddPlantRouter.swift`, `PlantTypes.swift`, `AnalysisFlowModel.swift`, `PreliminaryResultView.swift`, `CareQuestionsView.swift`, `LocalStore.swift`, `Localizable.xcstrings`, `PlantsUITests.swift`/`FirstHelpTests.swift` и unit tests. Контроллер до запуска обновляет doctor/simulator_smoke/t152 UI gate под новый UI, сохраняя проверки запуска/ошибок.

**AC:** EN/PL прямой вход, альтернативный каталог, back/retry/login cancellation сохраняют фото/ввод; три существующих вопроса условий не путать с удалённым post-analysis diagnostic bank. Старый persisted route восстанавливается в безопасный текущий шаг без потери ввода. Реальные unknown/error не выглядят как успех. Единый result→save подтверждается API; если backend недоступен, честный error, без локального fake result. Полный маршрут не закрывается только screenshot welcome.

**Gate:** UI маршрут плюс unit/disk restore, обновлённый Simulator smoke; live photo→result→save отдельно после готовых adapters. Риск средний.

## T171 — Простые действия и следующая проверка

**Результат:** согласовать SQL/Swift/UI/notifications с Condition2/Plant2: действие, основание, применимость и nullable следующая проверка; обычный repeat и один связанный first-aid control. Нет лечебных стадий, фотосравнения/экспорта/выбора главного фото из истории, отдельного журнала пересчётов.

**Scope:** новая migration schedule/task rules/active projections, Swift action/task DTO, care card/log/notification consumers (точные новые файлы фиксируются при подготовке), `schedule_calculator.test.sql`, care/undo tests; resolver только для адаптации контракта. Удалять дополнительные фотоflows только если найдены реальные consumers, личные/контрольные фото и историю сохранить.

**AC:** enable не равен выполнению; record/undo/backdate без дубля, undo первой помощи снимает незавершённый контроль; нет подтверждённого правила/anchor — нет выдуманной даты. Paused/expired не продолжают автоматическую цепочку; обновление KB заменяет только допустимое будущее. Unsupported multi-stage treatment явно ограничен, не сокращён до опасного рецепта. Offline/restart/retry сохраняют ручной журнал и права owner.

**Gate:** SQL clean/upgrade + concurrent record/undo/retry, Deno applicability, Swift disk/notification/UI. При необходимости отдельные manifest SQL → DTO/UI → integration. Риск высокий. Parent T160 закрывается только после полного соответствующего сценария.

## T172 — Простые комнаты: сервер

**Результат:** реализовать [simple-rooms.md](contracts/simple-rooms.md): private named group, необязательный room_id у растения, create/rename/delete/assign и sync. Новая migration поверх всей очистки, без revert retirement.

**Scope:** новая migration rooms/plant assignment/owner_sync_entries, `plants-api/index.ts` и новый `plants-api/rooms.ts`, API/sync/data-model addendum; новые `simple_rooms.test.sql`, `simple_rooms_upgrade.seed.sql`, Deno endpoint tests. Брать последние функции T161/T166/T169, не копировать старые полные определения с slots/fallback/season. Старые gates/tests retirement не стирать: исторический checkpoint отдельно от текущей комнаты.

**AC:** создание/переименование/назначение/снятие/удаление; delete группы сохраняет растения и переводит их в «Без комнаты». Owner A/B, guest denied, deleted/nonexistent/cross-owner IDs отклонены. Retry receipt/hash mismatch, concurrent assign/delete с определённым итогом, tombstones/pagination. Уход/анализ/условия/квоты/доступ не меняются при перемещении. Upgrade не переписывает старые ID/receipts; legacy live rooms доступны владельцу, orphan/deleted link отображается «Без комнаты».

**Gate:** новый PostgreSQL rooms clean/seeded-upgrade/real race runner + Deno commands/auth. Минимум один реальный положительный путь через API adapter к SQL в изолированном окружении. Риск высокий.

## T173 — Простые комнаты: приложение

**Результат:** название группы, список растений, фильтры «Все»/«Без комнаты»/комната, простое создание/переименование/удаление и назначение из карточки уже сохранённого растения. Не вставлять обязательный room step в добавление.

**Scope:** новые `Features/Collection/RoomsView.swift`, `Data/Repositories/RoomsRepository.swift`, room DTO в `PlantTypes.swift`/`APIModels.swift`, `PlantsAPIClient.swift`, существующие sync/store, collection/card UI, локализация EN/PL; Swift persistence и room UI tests. Collection/card предпосылки T049/T051 проверяются по коду: при их отсутствии сначала отдельный ограниченный manifest foundation, не скрытый весь продукт внутри rooms.

**AC:** фильтр не меняет данные и квоты; rename/delete/assign имеют pending/confirmed/error, lost response retry не дублирует комнату. Offline команда сохраняется existing outbox, restart/owner switch/full refresh не теряют её и не смешивают аккаунты. Delete комнаты не удаляет растение/фото; пустой список и ошибка доступны в EN/PL. Не добавлять условия комнаты, AI, расписание, вложенность, sharing, автогруппировку.

**Gate:** PlantsTests на дисковом store, реальные UI cases и актуальный Simulator smoke. Не создавать второй sync/outbox. Риск средний.

## T174 — Сквозная приёмка простых комнат

**Результат:** отдельно принять rooms-сценарий на fixtures/Simulator и живом test окружении. Никаких заявлений о live по одному fake adapter.

**Scope:** room integration/UI tests и проверяемые отчёты управляющего процесса. Пакет read-only приёмки (`write_files: []`) возможен только когда все нужные tests/gates уже подготовлены; иначе сначала отдельный test implementation manifest. Runtime дефекты возвращаются в T172/T173, не исправляются скрыто внутри read-only приёмки.

**AC:** owner A создаёт комнату, назначает растение, другой клиент A получает sync; B ничего не видит; offline rename→restart→sync, повтор после потери ответа, assign/delete race, удаление группы сохраняет растение/фото/историю. Регрессии: cap/expiry/квоты/guest и простой уход неизменны; комнаты не обязательны для основного пути. Записать build/commit/environment и фактические результаты без секретов.

**Gate:** SQL/Deno/Swift fixture suites плюс отдельный live API/iOS gate двух test owners. Если test environment недоступно, задача остаётся открытой с точной точкой остановки, T172/T173 могут иметь только локальную приёмку. Публикация/production deploy не входит. Риск высокий.
