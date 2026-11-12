# Narat — текущий статус и передача работы

**Обновлено 2026-11-12.** Сквозной EN-срез распознавания, коллекции и ручного ухода прошёл на `narat-staging`. Повторная диагностика V02 принята на стенде со сверкой B. Полная T098 открыта, T057 остаётся на паузе.

**Workspace A:** `/Users/ruslansabirov/.codex/worktrees/d09a/Plants`, ветка `codex/plants-ios`, исходный HEAD `4bbd35a`. Общий Simulator — только A; backend/SQL/contracts — B. Интеграция в main — только после повторных gates из отдельного чистого checkout.
**Источники:** [spec](../specs/001-plants-ios-mvp/spec.md), [tasks](../specs/001-plants-ios-mvp/tasks.md), [решения](validation/spec-simplification-2026-11-09.md), [аудит и карта зависимостей](validation/overengineering-review-2026-11-09.md).

## Очередность EN-приёмки и пауза StoreKit

T057 сохранена в отдельной ветке `origin/codex/plants-ios-t057-storekit`, коммит `1c52713`. `StoreKitService.swift` загружает месячный и годовой продукты через StoreKit 2 и читает локализованную цену, период и доступность годового trial. `StoreKitServiceTests.swift`, `project.yml` и Xcode project подключают существующий файл `StoreKit.storekit` к тестовому target. `T057StoreKitLocal01` прошёл 1/1 в локальном StoreKit Test: два тарифа в PLN, месячный без trial, годовой с доступным семидневным trial. Покупки не запускались. После отдельной продуктовой приёмки возобновить с T052 wire для серверного `appAccountToken`, подписанной транзакции и restore. Маршрут и точные поля не добавлялись до контракта. T057 открыта.

Отметка T154 сверена с опубликованным B `1d5beb8`. В iOS перенесён точный `docs/validation/integrations.md`, соответствие проверено `cmp`, статус в `tasks.md` обновлён. Отчёт разделяет 43 миграции, живой Auth/Storage и clean/upgrade fixtures. [Отчёт T154](validation/integrations.md).

**Прогон T098.** Подписанная сборка `f74f12f`, владелец `b35efa69-337c-43bd-be8d-00a7addf1bc9`, стенд 023. Из галереи прошли `unknown / released` и Monstera `identified / consumed`. Сохранение Monstera и запись полива после потери ответа повторили исходные операции, PostgreSQL подтвердил одну карточку с тем же фото и одну запись. После перезапуска `My plants` показала то же фото, совет с источником и `Undone`. Adenium без профиля и опроса открылся по тому же UUID после запуска, совет отсутствует. Независимая сверка B совпала по UUID и квитанциям. Обновлены `docs/validation/mvp-acceptance.md`, handoff и `tasks.md`. Живой Simulator/API/SQL и diff-check прошли, runtime не менялся. [Матрица и UUID](validation/mvp-acceptance.md).

### V02 — повторная диагностика карточки

`GuestCatalogueView.swift` и `PlantsApp.swift` добавляют вход из сохранённой карточки постоянного владельца на EN staging. `AnalysisFlowModel.swift`, `AddPlantRouter.swift`, `CareQuestionsView.swift` и `PreliminaryResultView.swift` переиспользуют выбор нового фото и результат. Опрос пропускается, возврат ведёт в исходную карточку, сохранения новой карточки из результата нет. `PlantsAPIClient.swift` передаёт согласованный с B `target_plant_id`, а `APIModels.swift` сверяет UUID карточки и фото в ответах create/GET. iOS повторяет исходную операцию и locale, сервер читает текущие условия и журнал.

**Локально.** Diff-check, `V02RepeatDiagnosis01` (220/220 Swift unit) и `V02RegressionUI01` (5/5 XCUITest) прошли. `FirstHelpUnitTests.swift` проверяет прямой переход к выбору фото и сохранение входа на повторе. `CollectionWireTests.swift` проверяет потерю create, точный replay, отклонение чужого фото в status и lease другого владельца. UI-регрессия покрыла обычный вход First Help в EN/PL и открытие карточки после запуска.

**Живой стенд.** B `11fd55a` подтвердил выкладку 025, plants-api v15 и analysis-worker v8. EN-сборка `8a70ab5` открыла карточку `76e1633a-21c0-485f-b4a5-a081dfb5c375` владельца `ff9d0db1-779b-414a-8101-15b666bd24ff`. Новый JPEG из галереи дал job `411092c0-7323-49d3-8b13-42950559ae43`, операцию `0d9089e9-21ad-4179-b116-0757273aabb3`, фото `c5e0d8d7-8df8-4679-a697-d79e69eb983a`. Тестовый транспорт потерял реальный 202, `Retry` получил 200 для того же job, живой результат `healthy / consumed`. После возврата и холодного запуска открылись главное фото `2efef527-e1cb-420c-8a8d-44fb6c9ecea5` и активный полив `f1469f6b-9cac-4e9f-86a9-129ab9bdf012`. SQL A подтвердил snapshot `8912e76a-cfac-4e02-b76b-66b951e9c1ec`, контекст, один job и совпадение хешей карточки и журнала. [Прогон и ограничения](validation/mvp-acceptance.md#v02--повторная-диагностика-из-сохранённой-карточки).

**Сверка B.** `41118be` подтвердил то же задание, одно списание starter, приватное новое фото, контекст и неизменные карточку, журнал и отмены. Отдельный владелец получил 404 на чужие create/GET. V02 принят для EN staging. [Серверный отчёт B](https://github.com/1rusl1/Narat/blob/41118be/docs/validation/repeat-plant-diagnosis.md).

### V11 — чтение сохранённой карточки без сети

`CollectionRepository.swift` при сетевом сбое читает последний успешно синхронизированный снимок только под текущим lease владельца. `GuestCatalogueView.swift` показывает пометку о последней синхронизации и открывает прежнюю карточку с локальным журналом. При отсутствии снимка остаётся ошибка загрузки. `CollectionRepositoryTests.swift` проверяет тот же UUID карточки и активной записи после открытия SQLite, отсутствие записей при смене владельца и сохранность очереди. `CatalogueUIFixtureTests.swift` сверяет обычную загрузку с сервера.

**Локально.** Diff-check и `V11OfflineCollection01` прошли, 221/221 Swift unit-тестов и 1/1 XCUITest открытия сохранённой карточки после запуска. Доказательство offline использует сетевую фикстуру.

**Данные стенда.** Подписанная `63d7f0c` холодно открыла карточку V02 и прежний активный полив из SQLite. API транспорта тестовой сборки был отключён. После нового запуска с живым API открылись те же UUID карточки и записи. Скриншоты `v11-cached-collection.png`, `v11-cached-history.png` и `v11-reconnected-history.png` в `DerivedData/TRepeatDiagnosis/`. Команды ухода в этом прогоне не отправлялись.

### V11 — исправление даты полива

B `d1d2605` принял `care.correct_date` и выложил 026 / plants-api v16. `GuestCatalogueView.swift` добавляет выбор даты у активной записи сохранённой EN-карточки и повтор на открытой карточке при восстановлении сети. `PlantsAPIClient.swift`, `LocalStore.swift`, `CollectionRepository.swift` и `SyncEngine.swift` сохраняют исходный envelope в outbox и снимают его после проверки квитанции и применения канонического sync. До подтверждения журнал показывает прежнюю дату с пометкой ожидания. В `CollectionWireTests.swift` проверены перезапуск SQLite, неверный entry в квитанции, сбой sync после 200 и точный replay.

**Локально.** Diff-check, 222/222 Swift unit и 1/1 XCUITest открытия коллекции в `V11DateCorrection01` прошли.

**Стенд.** Подписанная EN-сборка `f39de34` поставила исправление `074c6f75-9c34-4ff7-b148-4d2f0c269599` в очередь при отключённом API. На холодном запуске она отправила его при открытии карточки `2284cde7-8c4e-4863-a69a-c91f86747a8f`. Транспорт отбросил первый живой 200. Повтор отправил побайтно тот же запрос и получил тот же receipt. После канонического sync и ещё одного запуска запись `80ca3159-8074-421a-ada1-d8ebfd575fc5` показала 10 вместо 11 ноября. PostgreSQL подтвердил одну запись, исходное время внесения, один receipt исправления, отсутствие изменений карточки и автоматических задач. Владелец `ae41d79d-4b50-49c8-a77f-748c42d63d8c` отдельный от прогона B и V02. [Прогон и UUID](validation/mvp-acceptance.md#v11--исправление-даты-полива).

Live-проверка доставки охватила открытие карточки после перезапуска. Потеря сети и ответа задавалась тестовым транспортом. T062 и T065 открыты для остальных команд и общей синхронизации.

### V11/V19 — дата следующей проверки грунта

`PlantsAPIClient.swift` читает опциональный `next_check` по контракту B `bc74c66`, сверяет календарные дни, интервал и HTTPS-источник. `CatalogueSaveView.swift` и `GuestCatalogueView.swift` показывают дату без пересчёта часового пояса, краткое основание и ссылку на источник интервала. `CatalogueSaveModel.swift` обновляет совет после подтверждения записи, исправления и отмены полива. В коллекции правка запускает новое чтение после синхронизации журнала. Пропущенный или null `next_check` сохраняет прежний совет.

**Фикстуры.** Diff-check и 223/223 Swift unit прошли в `V11V19NextSoilCheck02`. В первом прогоне `V11V19NextSoilCheck01` открытие сохранённой карточки после перезапуска прошло 1/1 XCUITest. В Swift-фикстуре исправлено ожидание состояния после недоступного sync, продуктовый код между прогонами совпал. `CollectionWireTests.swift` проверяет даты на границе месяца, пропущенный и null `next_check`, ошибочные дату, интервал и источник, обновление совета после записи, правки и отмены.

**Стенд.** B `f92689d` выложил 027 / plants-api v17. В опубликованном KB один профиль и ноль подтверждённых числовых интервалов. Живой GET B сохранил условный совет Monstera и вернул `next_check: null`. iOS-приёмка положительной даты ждёт опубликованного правила. [Отчёт B](https://github.com/1rusl1/Narat/blob/f92689d/docs/handoff_status.md).

**Следующий шаг.** После публикации правила с подтверждённым интервалом пройти в подписанной EN-сборке запись, исправление и отмену полива и сверить дату с сервером. Обычный повтор и один контроль первой помощи V19 остаются отдельными критериями. V11/V19, T160 и T171 открыты. Недельный остаток Codex на контрольной точке 17%. Миграция 024 и StoreKit на паузе.

## T150 — распознавание, личное фото и гостевой перенос

`AnalysisFlowModel.swift`, `PreliminaryResultView.swift` и `PlantsApp.swift` связывают явное подтверждение вида с текущими flow и операцией, результатом `identification`, UUID задания и ID загруженного фото. Экран предлагает подтверждение только для определённого вида с названием и связанным фото. Смена фото или выход очищают подтверждение. В `FirstHelpUnitTests.swift` проверены отказ для `unknown` и результата без ID фото, подтверждение точного задания и сброс после смены фото.

**Локально.** Diff-check, сборка, welcome и 214 Swift-тестов прошли без пропусков. Новый целевой тест прошёл. Run `ios-t150-identification-confirmation-start-20261112`. Живой стенд в этом срезе не запускался. T150 остаётся открытой.

`PlantsAPIClient.swift` и `GuestCatalogueView.swift` читают выбранный вид по публичному taxon UUID и сверяют UUID и slug. Старое восстановление по slug сохранено. `CatalogueUIFixtures.swift` и `CatalogueUIFixtureTests.swift` проверяют оба способа lookup. Два целевых Swift-теста и один XCUITest открытия карточки после перезапуска прошли в `t150-published-taxon-id-01`. Отдельный живой GET по UUID `83f27806-3577-4bdc-9b18-222bedcf06d7` вернул `monstera_deliciosa` и `Swiss Cheese plant`.

### Отдельный wire identification

Контракт B из `03ac0c1`, backend Review/QA приняты в `8ba3756`. `APIModels.swift` и `PlantsAPIClient.swift` декодируют отдельный результат `identified|unknown`, проверяют версию, UUID задания/каталога/вида, наличие имени и состояние квоты. `PlantsApp.swift` повторно использует upload-ticket, PUT, complete и polling, передаёт `flow_id` для identification, читает публичную карточку по точному taxon UUID и сохраняет имя из закреплённого результата. Включение только для выделенного staging Simulator с `--narat-staging-analysis --narat-staging-identification`. `AnalysisFlowModel.swift` и `PreliminaryResultView.swift` показывают отдельный результат, подтверждение вида с ID фото и отказ `QUOTA_REGISTRATION_REQUIRED`.

**Локально.** `ios-t150-identification-wire-20261112-01`: diff-check, сборка, welcome и 216 Swift-тестов без пропусков. `CollectionWireTests.swift` проверяет ошибочные UUID, версию, unknown/identified и квоту, восстановление после потери PUT через complete, точный create и публичный lookup. `FirstHelpUnitTests.swift` проверяет выбор и очистку подтверждения. Диагностические тесты прошли.

**Живой iOS unknown.** На `narat-staging` подписанная сборка `9dd1924` в выделенном Simulator отправила через штатную галерею синтетическое изображение B. Изолированная постоянная сессия начинала без identification-заданий. Через 4,68 с экран показал `Species could not be determined.` с переходом в каталог и без действия подтверждения. PostgreSQL подтвердил единственное задание `32421c6f-fee9-43f6-b3eb-8d3fccf12e5d`, одну квитанцию, `succeeded / unknown / released`, пустые поля растения и `ready` для фото `3e5e7b7b-df46-46b8-97d7-ed0eb9280794`. Задание закрепило каталог `81bb49c1-0e39-5a9c-8327-7be12075f4ad`. Снимок экрана и SQL-выборка в `DerivedData/T150Identification/`.

**Живой iOS identified.** После выкладки B `a67dca8` (миграция 019 и обе Edge-функции) та же подписанная сборка `9dd1924` отправила лицензированное фото Monstera штатным путём. За 8,62 с экран показал `Swiss Cheese plant`, после нажатия — `Species confirmed.`. PostgreSQL подтвердил новое задание `46ea9380-e9cf-4db6-8422-e5522294454e`, taxon `83f27806-3577-4bdc-9b18-222bedcf06d7`, тот же закреплённый каталог, `succeeded / identified / consumed` и одну квитанцию. Фото `bacf5b42-c5db-4b07-89b1-81f0d92daa7d` принадлежит тому же тестовому владельцу и находится в `ready`. Прежний `unknown / released` сохранился. Снимок и SQL-выборка в `DerivedData/T150Identification/identified.*` и `identified-database.json`. Исходники не менялись, локальная приёмка 216 Swift-тестов выше.

### Сохранение личного фото

Клиент подключён к wire B `0d7a3ea`, принятому локально в `c81343c`. Подтверждённый taxon UUID и точный identification job входят в неизменяемый `plant.create` с `add_method=scan`. `CollectionRepository.swift`, `LocalStore.swift` и `CatalogueSaveModel.swift` сохраняют и восстанавливают тот же SQLite-чекпойнт. `PlantsAPIClient.swift` и `APIModels.swift` требуют `photo_id` в scan-квитанции. Канонические UUID вида и фото сверяются с `/sync`. `AnalysisFlowModel.swift`, `PreliminaryResultView.swift`, `PlantsApp.swift`, `CatalogueSaveView.swift` и `GuestCatalogueView.swift` связывают подтверждение с исходным владельцем и загружают фото по Bearer в рамках текущей сессии.

**Локально.** Diff-check, сборка, welcome и 217 Swift-тестов без пропусков прошли в `ios-t150-personal-photo-20261112-04`. Новый тест в `CollectionWireTests.swift` проверил потерю ответа, повтор того же тела из SQLite, квитанцию с фото, canonical readback и приватное чтение с проверкой MIME. Обновлены существующие фикстуры `CatalogueSaveModelTests.swift`, `CollectionRepositoryTests.swift` и `FirstHelpUnitTests.swift`. До итогового прогона исправлены ошибки компиляции после изменения модели.

**Живое сохранение фото.** После выкладки B `c81343c` и миграции 020 подписанная сборка `f593cc5` под новой постоянной тестовой сессией выполнила свежий gallery → identification → confirm → save. Задание `f3d1e24d-602c-4282-9674-4db3b2d8b7b7` привязало готовое фото `40ebf050-6108-4f32-87e7-b8d20af8cb22` к растению `0a2a1a6b-44e2-4b6a-a71c-246c7a8e6a9a`. Сборка отбросила первый реальный HTTP 200, после перезапуска повторила исходную операцию `f271bfdf-b975-4ae2-914a-4f94d2ec83ed`. PostgreSQL до и после подтвердил одну карточку, одно фото и одну квитанцию. Фото отрисовалось после повтора и нового перезапуска. Запрос фото карточки другого постоянного владельца вернул 404. Прежняя Monstera `9ee20834-951a-4c4e-9f63-cfe6221554ec` открылась после перезапуска и из `My plants` с прежними советом, ссылкой и записью `Undone`. Доказательства в `DerivedData/T150PersonalPhoto/` и `DerivedData/T149Validation/`.

### Гостевой draft/claim

В iOS подключён wire B `2f5a895`. Выделенный staging Simulator получает настоящую анонимную сессию, регистрирует установку и использует один Keychain credential для загрузки, распознавания, черновика и переноса. `PlantsApp.swift`, `PreliminaryResultView.swift` и `GuestCatalogueView.swift` сохраняют идентификаторы черновика и операций перед входом и привязывают перенос только к подтверждённой постоянной сессии. `PlantsAPIClient.swift` и `APIModels.swift` проверяют ответ bind/prepare/commit. При потере ответа commit повторяется с исходным operation ID. Серверный `DRAFT_EXPIRED` очищает локальное продолжение. Окончание proof обновляется тем же prepare после retryable conflict, с тем же claim ID и commit.

**Локально.** Diff-check, сборка, welcome и 218 Swift-тестов без пропусков прошли в `ios-t150-guest-transfer-20261112-03`. Новый тест `CollectionWireTests.swift` проверяет смену Bearer при том же installation credential, отказ устаревшей гостевой lease, точный повтор commit и типизированный plant/photo receipt. Локальные тесты используют фикстуры.

Первый независимый Review (`parallel-ios-t150-guest-transfer-20261112-01`) выявил блокировку продолжения после потери ответа `POST /drafts` и холодного запуска. `PlantsApp.swift` теперь восстанавливает запрос из журнала по исходному ID и показывает `Continue saving` только тому же гостю и установке. Тест `CatalogueConnectionTests.swift` прошёл в `T150GuestDraftRestart01` (1/1). Он проверяет повтор точного запроса через новый координатор, получение сохранённого черновика и очистку журнала при `DRAFT_EXPIRED`. Повторный `parallel-ios-t150-guest-transfer-20261112-02` принят в `ea5404b`: 219 Swift-тестов, diff-check, сборка, welcome, Simulator smoke, независимые Review и QA прошли. [Отчёт](validation/automation/tasks/parallel-ios-t150-guest-transfer.md).

**Живой гостевой перенос.** После выкладки B `d69d287` (миграция 021, `plants-api`, `analysis-worker`) подписанная сборка `02c10d7` на выделенном Simulator создала настоящую анонимную сессию. Галерея и живое распознавание показали `Swiss Cheese plant` за 6,52 с. Подтверждённый job `191ad6c8-2634-4286-9831-d8574c6e4613` создал черновик `c0461b38-e7a7-49ed-94c6-4d03946eb732` с фото `b39c7c98-1634-4f17-86af-342baaaea19d`. PostgreSQL подтвердил стартовую гостевую квоту и 604 800 секунд от успешного анализа до закреплённого срока. До входа фото принадлежало гостю и экземпляра не было.

После входа в отдельный постоянный тестовый аккаунт Supabase `acf70488-22ab-42ee-b901-a20395be11c8` сборка отбросила первый успешный ответ `claims/commit`. До повтора PostgreSQL показал один экземпляр `b213a1bd-a158-40dc-b359-a17616f4f492` с исходным UUID фото у нового владельца. Холодный запуск повторил commit `01a4e9d6-1aed-48c0-86ec-a9794dff28c0` с тем же claim `dec49d5f-5bf2-4489-9fbc-4f89893aa0d7`. После второго холодного запуска та же карточка и фото открылись из `My plants`. PostgreSQL подтвердил один экземпляр, по одной квитанции draft/prepare/commit, тот же SHA-256 и приватный объект Storage. Скриншоты и выборки в `DerivedData/T150GuestClaim/`. Отдельный живой backend-прогон B подтвердил 410 для удалённого и просроченного черновиков (`3806a1e`).

После миграции 021 прежняя Monstera `9ee20834-951a-4c4e-9f63-cfe6221554ec` снова открылась напрямую и из `My plants` с исходным советом, ссылкой и той же записью `Undone` (`DerivedData/T149Validation/t149-original-monstera-*`).

**Объём приёмки.** Принят английский сценарий Simulator со штатной галереей и реальным тестовым входом Supabase. Физическая камера и нативный Apple/Google остаются отдельными проверками.

## T151 — принята проверка EN каталога

Живые API и Storage подтвердили выпуск из 606 видов, поиск по английскому и латинскому названию, совпадение карточки по slug и UUID, EN-описание и точные байты двух лицензированных JPEG. B `22f913d` сверила все карточки, пять объектов, совместимость PL API, серверный Free 409 и четвёртое сохранение Paid. PostgreSQL и `/sync` подтвердили изоляцию и точный повтор после нового входа.

Подписанная сборка `b12d12a` на выделенном Simulator сохранила `Adenium arabicum` без профиля ухода и опроса. После потери HTTP 200 и двух холодных запусков из `My plants` открылась та же карточка `4954317c-53dc-4192-9ad0-e4d7f93f5dc9`. PostgreSQL подтвердил одну квитанцию исходной операции. Free остановился на трёх, второй постоянный аккаунт увидел пустую коллекцию. Тот же синтетический Paid-владелец B сохранил через iOS пятую карточку `7bb0e8c7-ec54-44b6-83e6-7b327e3ac1ef` и открыл её после перезапуска. В PostgreSQL пять карточек и пять квитанций. Скриншоты и SQL-доказательства в `DerivedData/T151Validation/`.

**Файлы и проверки.** Обновлены `docs/validation/catalogue-skeleton.md`, handoff и `tasks.md`. Подписанная сборка, живые iOS/API/Storage/SQL и diff-check прошли. Отдельные фикстуры описаны в отчёте. Живая покупка StoreKit и PL UI остаются отдельными проверками. **Следующий шаг:** начать T036 с проверки живого `/analysis/access` для Free/Paid и сверки с уже принятым iOS DTO. [Отчёт T151](validation/catalogue-skeleton.md).

## T036 — приняты квоты перед сканом

После приёмки T151 `7593456` два синтетических постоянных аккаунта B выполнили настоящий вход Supabase и по два чтения `/analysis/access`. Ответы повторились без изменений и содержали UUID своих владельцев. Free получил 3 из 3 в общем месячном пуле и отдельные нерасходованные стартеры распознавания и диагностики. Paid получил 100 из 100 в одном пуле для обоих режимов. Границы периода совпали с датой регистрации и тем же днём следующего месяца, включая серверную микросекундную точность. Создание заданий не запускалось.

Оба живых ответа в `DerivedData/T036Validation/live-{free,paid}.json` декодированы локальным Swift-прогоном с действующими `AnalysisAccessWireDTO`, `SQLTimestamp` и `SyncWireRules.sameTime` из `APIModels.swift`. Результат 2/2, diff-check прошёл. Обновлены handoff и `tasks.md`. Действующий экран iOS и гостевая квота в этом прогоне не проверялись.

`AnalysisAccessRepository.swift` подключён к `PlantsAPIClient.fetchAnalysisAccess` через lease текущего владельца из `GuestCatalogueView.swift`. В `PlantsApp.swift` и `CareQuestionsView.swift` английский staging-путь показывает стартовую и месячную квоты и серверную дату до галереи. При ошибке или запрете скана остаются повтор проверки и переход в каталог. Гость повторно использует Keychain credential регистрации и черновика. При конкурентном создании Keychain сохраняет первый записанный credential. GET квот запрещает перенаправления, устаревший SDK scope отбрасывается.

**Локально.** `T036PreScanFocused01`: 62 `CollectionWireTests` прошли, включая новый тест точного guest credential, постоянного Bearer и отказа устаревшего lease. Diff-check прошёл. Изменены `PlantsApp.swift`, `PlantsAPIClient.swift`, `AnalysisAccessRepository.swift`, `CareQuestionsView.swift`, `GuestCatalogueView.swift` и `CollectionWireTests.swift`.

Первый независимый Review (`parallel-ios-t036-prescan-20261112-01`) выявил, что постоянный GET мог унаследовать installation-заголовок из ранее настроенного клиента. `PlantsAPIClient.swift` явно очищает его для постоянной сессии. Тест теперь проверяет старый заголовок в клиенте и гостевую замену. Повторный `T036PreScanFocused02` прошёл, 62/62. B подтвердил живой переход того же гостевого Auth UUID в постоянный после 022 (`049b536`): израсходованный starter 0, диагностика 1, общий Free 3 и регистрационная граница сохранены после повторного входа и refresh.

**Живой iOS.** Подписанная сборка `54b416f` на `narat-staging` показала Free 3/3 с отдельным starter 1/1 и Paid 100/100 без стартового остатка в этом режиме. На обоих экранах до галереи видна серверная дата `Dec 12, 2026`. Тестовый вариант один раз отбросил настоящий успешный ответ GET: на экране ошибка, галерея скрыта, поиск `Swiss Cheese` из каталога вернул Monstera. В другом запуске явный `Retry quota check` восстановил экран Free. Задержка живого ответа на 8 секунд подтвердила состояние ожидания с доступным каталогом и появление галереи после ответа. Ответы сервера не подменялись.

**Гость.** Новый анонимный вход iOS показал identification 1/1 без месячной квоты. Monstera распознана за 7,34 с. Задание `2cbb0170-d074-4451-a525-f9f955ca8287` израсходовало `starter_identification`. После холодного запуска и нового потока — 0/1, каталог доступен, галерея скрыта. Остаток диагностики 1/1, диагностика гостя не запускалась. Read-only SQL сравнил живой снимок квот с тем же снимком через секунду после закреплённой семидневной границы черновика `80eec69f-d26c-46e0-8d32-36917cd4da66`: 0/1 сохранились. Часы и строки стенда не менялись. B `1d5beb8` отдельно подтвердил новую анонимную сессию на той же установке и конверсию того же Auth UUID в Free без выдачи нового starter.

**Приёмка.** `parallel-ios-t036-prescan-20261112-02` прошёл сборку, welcome, 220 Swift-тестов, Simulator smoke и Review. QA запросила доказательства нового экрана. В `parallel-ios-t036-prescan-20261112-03` повторились те же локальные gates, независимые Review и QA приняли живые PNG и JSON из `DerivedData/T036Validation/`. Принятый коммит `462976b`. Постоянный Paid использовал выделенный серверный entitlement, проверка StoreKit относится к биллингу. [Отчёт](validation/automation/tasks/parallel-ios-t036-prescan.md).

## T165 — совместимость iOS при снятии отчётной проекции

B `838d9ff` снял запись server notification claims. На стенде оба старых POST вернули 404, `/sync` сохранил прежние ключи (`f23d571`). `APIModels.swift` читает прежний Boolean `report_notifications_enabled` и допускает отсутствие ключа. Если поле присутствует, неправильный тип и `null` отклоняются. `trial_reminder_enabled` остаётся обязательным, прежний `notification_claim_summaries` читается.

**Локально.** `T165SyncCompatibility01`: 63 `CollectionWireTests` прошли. `CollectionWireTests.swift` проверил старую страницу и новую страницу без ключа через штатный `SyncEngine`, сохранение прежней claim-записи и `trial_reminder_enabled` после открытия SQLite. Diff-check прошёл. **Живой стенд:** реальный профиль из действующего `/sync` после миграции 023 с прежним Boolean прошёл новый Swift-декодер. Обновлены handoff и `tasks.md`.

**Приёмка.** `parallel-ios-t165-sync-compatibility-20261112-01` принят и опубликован в `145b5a2`: diff-check, сборка, welcome, 221 Swift-тест, Simulator smoke и независимые Review/QA прошли. [Отчёт](validation/automation/tasks/parallel-ios-t165-sync-compatibility.md).

**Следующий шаг.** B снимает серверную read-проекцию, затем iOS проверяет живой `/sync` без старых ключей. Локальный trial reminder зависит от подтверждённой даты и отдельной приёмки T133. Полная T165 открыта.

## T149 — живой каталог и коллекция iOS

Кандидат `26cfc63` перевёл iOS на публичные `GET /catalogue` и `GET /catalogue/{slug}`, добавил серверный поиск с постраничной загрузкой и открытие растения из `My plants` по его UUID. Активные карточки читаются из `/sync` по текущей постоянной сессии. Изменены `PlantsApp.swift`, `PlantsAPIClient.swift`, `CollectionRepository.swift`, `GuestCatalogueView.swift`, `CatalogueSaveView.swift`, `CatalogueUIFixtures.swift`, `CatalogueUIFixtureTests.swift`, `CollectionWireTests.swift` и `CatalogueSaveUITests.swift`.

**Живой стенд.** Backend B `7cc1f19`, миграция 018 и выпуск `skeleton-300-v1-en-85fcaba4` с 606 видами. Публичные страницы по 50 записей проверены без авторизации. Monstera отсутствует на первой странице и находится по `Swiss Cheese` в Simulator, карточка показывает Raul654 и CC BY-SA 3.0. Существующая Monstera `9ee20834-951a-4c4e-9f63-cfe6221554ec` после перезапуска и из `My plants` показала `Swiss Cheese plant`, тот же совет со ссылкой и ту же отменённую запись `a3a428a9-2822-428b-aba0-c763a4c564f0`.

На выделенном Simulator вошли двумя синтетическими постоянными владельцами в одну изолированную установку. В A сохранение из каталога создало растение `802103f1-d434-4bae-b43f-86c185d89d82` операцией `aba23abb-bdc6-4b7f-8546-6e14b905e693`. Подписанный тестовый вариант отбросил первый реальный HTTP 200. В повторе после холодного запуска использован исходный UUID операции. В базе до и после повтора по одной карточке и квитанции. Повторный запуск и `My plants` открыли тот же UUID. A сохранил три растения, четвёртое остановлено preflight, в PostgreSQL ровно три записи и три квитанции. После входа B из той же установки коллекция пуста, карточки A скрыты. Скриншоты и ограниченные SQL-выборки лежат в `DerivedData/T149Validation/`.

**Локальные проверки.** 5 EN XCUITest и 2 целевых Swift-теста прошли. На фикстурах проверены продолжение после нативного входа, Free cap, сохранение пятого и шестого растения в paid, повтор и открытие прежнего UUID из коллекции. Живой вход выполнен через тестовые постоянные учётные записи Supabase. StoreKit и живой Apple/Google остаются отдельными проверками. Итоговый `parallel-ios-t149-live-catalogue-20261112-01` принят в `edf05e9` за 309,87 с. Diff-check, сборка, welcome, 213 Swift-тестов, Simulator smoke, Review и QA Astra High прошли. [Отчёт](validation/automation/tasks/parallel-ios-t149-live-catalogue.md).

**Следующий шаг.** T150 начать с привязки подтверждения вида к результату identification и ID загруженного фото. Живой identification, привязка фото к экземпляру и семидневный draft/claim требуют опубликованного серверного контракта и отдельной сквозной проверки.

## Запись и отмена ручного полива

Кандидат `4f59a0e` добавляет действия `Record watering`, `Retry watering change` и `Undo` в английской staging-карточке. Изменены `LocalStore.swift`, `PlantsAPIClient.swift`, `CollectionRepository.swift`, `CatalogueSaveModel.swift`, `CatalogueSaveView.swift` и `CollectionWireTests.swift`. Повтор читает исходную операцию из существующего owner outbox. Результат и дата записи берутся из `/sync` после валидации квитанции, рекомендация читается отдельно. Backend — принятый контракт B `cc721ce`.

**Локальные проверки.** Три целевых теста прошли (3/3). Они проверяют точный HTTP-запрос, сохранение операции на диске, повтор, синхронизацию отмены, недействительные квитанции, смену владельца с возвратом и сбой обновления истории после подтверждённой записи. `parallel-ios-manual-care-write-20261111-01` прошёл 211 Swift-тестов. Review запросила дополнительные фикстуры. В `d22aeab` изменены только тесты. Повторный `-02` принят за 322,70 с в `6cfff16`. Diff-check, сборка, welcome, 213 Swift-тестов без пропусков, Simulator smoke, Review и QA Astra High прошли. Кандидат собран вручную, оркестратор выполнил независимую приёмку. [Отчёт](validation/automation/tasks/parallel-ios-manual-care-write.md).

**Живой стенд.** На карточке `9ee20834-951a-4c4e-9f63-cfe6221554ec` журнал до проверки пуст. Подписанная сборка от `4f59a0e` использовала изолированный SQLite и отбросила только первый настоящий HTTP 200 записи. Сервер уже имел одну запись `a3a428a9-2822-428b-aba0-c763a4c564f0` и одну квитанцию `a450a0bc-34e4-4d1b-946f-87215d3aed2d`. После холодного запуска без имитации сбоя приложение предложило повтор. PostgreSQL подтвердил те же UUID и одну квитанцию. Следующий перезапуск показал `Active`. Нажатие `Undo` создало отдельную операцию `f5407952-a615-4f5b-9c95-364e13bf6ae8` и единственную отмену `ea276d4c-4919-4d30-a900-7ff006f8a87e`. После нового запуска та же строка показана как `Undone`, английский совет и ссылка остались. Скриншоты, выборки интерфейса и PostgreSQL лежат в `DerivedData/AnalysisCreateLive/manual-watering-*`.

**Ограничения и следующий шаг.** Проверен одиночный ручной полив и отмена на одной staging-карточке. Полные T055/T065/T067/T068/T171 открыты. При объединении A и B повторить iOS gate и живой сценарий на том же тестовом проекте из отдельного чистого checkout интеграции.

## Совет по поливу Monstera

В `d30b91c` принят английский совет на подтверждённой staging-карточке. `PlantsAPIClient.swift`, `CatalogueSaveModel.swift` и `CatalogueSaveView.swift` используют owner-bound `GET /plants/{plant_id}/care/recommendation` с явным повтором после ошибки. `CollectionWireTests.swift` проверяет контракт, восстановление с диска, повтор и смену сессии. Backend B развернул контракт `77975cc` и подтвердил живой ответ в `99c995a`.

В `parallel-ios-care-recommendation-20261111-01` два патча Sol Low не применились. В `-02` прошли 210 Swift-тестов и Review, а QA запросила подтверждение отображения. `-03` с реальными скриншотами принят за 278,68 с. Review и QA Astra High по одному вызову. Прошли diff-check, сборка, welcome, 210 Swift-тестов и Simulator smoke. [Отчёт](validation/automation/tasks/parallel-ios-care-recommendation.md).

На живом `narat-staging` карточка `9ee20834-951a-4c4e-9f63-cfe6221554ec` показала исходный английский текст совета и ссылку до и после перезапуска. «Check the potting mix. Let it dry slightly between waterings. Once it has dried a little, water thoroughly.» Интервал отсутствует в ответе. Подписанная тестовая сборка использовала изолированное локальное хранилище, без replay или сбоя транспорта. Скриншоты и дерево интерфейса сохранены в `DerivedData/AnalysisCreateLive/watering-recommendation-{opened,reopened}.{png,json}`. В строке вида при восстановлении пока отображается slug `monstera_deliciosa`. [Источник](https://hort.extension.wisc.edu/articles/monstera-deliciosa/).

## Чтение журнала ручного полива

В `0819d0d285addcbb9737a81e54b289ef28e27631` приняты `CollectionRepository.swift`, `CatalogueSaveModel.swift`, `CatalogueSaveView.swift` и `CollectionWireTests.swift`. Подтверждённая staging-карточка читает `care_entries` из своего owner `/sync`, показывает записи полива и отмену по исходной локальной дате. Записи других растений, задачи и другие действия отфильтрованы.

`parallel-ios-manual-care-history-20261111-01` прошёл за 691,67 с. Developer Sol Low вызван трижды, Review и QA Astra High по одному. Первый кандидат нарушил существующий переход карточки в `loading`, правка прошла повторную проверку. Итоговые diff-check, сборка, welcome, 209 Swift-тестов без пропусков и Simulator smoke прошли. Фикстуры покрывают восстановление, active/voided и фильтрацию. [Отчёт](validation/automation/tasks/parallel-ios-manual-care-history.md).

B отдельно подтвердил живые `care.record` и `care.undo` на `narat-staging` по контракту из `cc721ce`. Живая клиентская проверка описана выше.

## Результат анализа → подтверждённая карточка

В `05e1c76c6d854d8a10174f34186949644f8ce89d` приняты `PlantsApp.swift`, `PreliminaryResultView.swift`, `CatalogueSaveView.swift`, `GuestCatalogueView.swift` и `CollectionWireTests.swift`. Английский staging-путь без переключателя даёт один вход в существующий `plant.create` для определённого вида. Определение болезни может оставаться неопределённым. Ошибка оставляет результат, подготовленное фото и исходный ввод в текущем потоке. При восстановлении карточка читается по тому же durable checkpoint и квитанции независимо от страницы каталога. Действующий контракт сохраняет вид и имя. Привязка фото и анализа к карточке остаётся отдельной задачей.

**Пилот и локальная приёмка.** Из `26ae2a0` перенесён только `roles.developer` в локальную копию конфига iOS. Lock и отсутствие активного контроллера проверены. `prepare` прошёл для всех запусков. `parallel-ios-analysis-create-20261111-01` прерван после 582,97 с, когда сессия Gemini 3.8 Flash High была IDLE с одной входной записью и без ответа. `-02` с GPT-6 Luna High завершён BLOCKED за 112,06 с. Три ответа за 109,51 с не дали патча. `-03` с GPT-6.1 Sol Low принят за 847,48 с, включая 424,00 с на три Developer-вызова. Первый diff не применился. Astra High приняла исправления после двух Review и одного QA. Прошли diff-check, сборка, welcome, 208 Swift-тестов без пропусков и Simulator smoke. [Отчёт](validation/automation/tasks/parallel-ios-analysis-create.md).

**Живой Simulator.** Backend `b894b9f` выложил миграцию 015 для `digest`. Использовал подписанный тестовый вариант от `05e1c76` с локальным overlay. Он сверял SHA-256 выбранного фото и читал ранее завершённый job через реальный `GET` с той же сессией, поэтому новый анализ не расходовал квоту. Отдельный SQLite и suite использованы из-за прежнего pending сохранения на этом Simulator. Для нечёткого фото кнопки сохранения не было. `Swiss Cheese plant` сохранилась с именем `Narat E2E 71a9c302`. Тестовый транспорт отбросил первый реальный HTTP 200. Интерфейс остался в `Save pending` и сохранил имя и результат. PostgreSQL подтвердил одну карточку уже до повтора.

Явный повтор использовал operation `76c1a403-9572-4b76-a9c9-476068a379f8`. Квитанция, карточка, `/sync` после перезапуска и PostgreSQL показали plant `9ee20834-951a-4c4e-9f63-cfe6221554ec`, вид `monstera_deliciosa`, один экземпляр и одну квитанцию. Перезапуск выполнялся с тестовым локальным scope, без подмены ответа и без повторного анализа. Подписанные `.app`, точный временный diff и скриншоты лежат локально в `DerivedData/AnalysisCreate-05e1c76c6d85/` и `DerivedData/AnalysisCreateLive/`. Проверочная карточка открыта в Simulator с `--narat-staging-analysis --narat-test-collection-scope 66ff3817-6b60-4264-8c9d-8eb31966f70d`.

Следующий шаг — клиентское чтение существующих `care_entries` из owner `/sync` на этой карточке и проверка после перезапуска. Запись и отмена идут по принятому контракту B. Полные T044/T046–T049/T150/T170 остаются открытыми.

## Живой фотоанализ из Simulator

Исходники сборки `c8b7b4ad3f93e00862120405753d560de5bfc5eb`. В `AnalysisPhotoInput.swift` удалены некорректные `kCFNull`-параметры ImageIO и добавлена проверка типа, кадра и статуса JPEG. `FirstHelpUnitTests.swift`, `project.yml` и `project.pbxproj` проверяют реальный JPEG каталога без копирования его в приложение. До исправления оба выходных файла из каталожной Monstera в тесте Simulator имели по 20 байт и не декодировались. Три живых задания из `8b1f131` также загрузили по 20 байт, получили HTTP 400 у OpenRouter и освободили квоту.

**Локальные проверки.** `xcodegen`, `git diff --check`, целевой тест после правки и gate `ios-photo-jpeg-fix-20261111-01` прошли. В тесте оба JPEG полностью декодируются в 960×1091. Сборка, welcome и 205 Swift-тестов прошли без пропусков и ошибок. Сборка с отключённой подписью не сохраняла сессию в Keychain. Ручная подпись копии не запустилась. Штатная подпись Xcode прошла, вход отдельной подтверждённой staging-учёткой и сохранение сессии после перезапуска проверены.

**Живой staging.** `plants-api` v6 и `analysis-worker` v4 из backend `c372c6b`, Claude Haiku 5.5 через OpenRouter. Оба задания завершились `succeeded`. Размеры из билетов совпали с метаданными приватного Storage. Время измерено от выбора фото до текста результата в UI.

| Кадр | Задание | Байты JPEG | Результат в Simulator |
| --- | --- | ---: | --- |
| Monstera из каталога | `c21ed170-dde7-4bc9-b203-44500d8c28ac` | 574 412 | `Swiss Cheese plant`, `No conclusive diagnosis is available.` за 9,34 с. На сервере `identified / monstera_deliciosa / insufficient_data`. |
| Нечёткий синтетический кадр | `a2f1295e-d979-4a09-be98-773fe6ecc4b5` | 125 601 | `Species could not be determined.`, `No conclusive diagnosis is available.` за 5,43 с. На сервере `unknown / insufficient_data`. |

Первое задание израсходовало стартовый диагноз. Второе завершилось с освобождением обычной месячной квоты, текущее использование 0 из 3. Учётка осталась в приложении на главном экране `Diagnose a plant problem`. Оба кадра в галерее Simulator. Синтетический кадр получен встроенным imagegen по запросу на сильно расфокусированное зелёное растение в тёмной комнате без различимых признаков. Локальный файл `DerivedData/StagingDiagnosis-8b1f131d4e6c/live-fixtures/narat-unclear.png`. Снимки результатов в `DerivedData/StagingDiagnosis-c8b7b4ad3f93/LiveEvidence/`.

Повторный запуск установленного приложения. При необходимости сначала установить подписанную `.app`.

```sh
xcrun simctl install 32009F39-32EF-426B-A91E-31B368D6C27E '/Users/ruslansabirov/.codex/worktrees/d09a/Plants/DerivedData/StagingDiagnosis-c8b7b4ad3f93/SimulatorXcodeSigned/Build/Products/Debug-iphonesimulator/Plants.app'
xcrun simctl launch --terminate-running-process 32009F39-32EF-426B-A91E-31B368D6C27E app.narat.plants.stagingdiagnosis --narat-staging-analysis
```

Следующий шаг — подключить сохранение результата в коллекцию и проверить запись ухода. Полные сценарии T037–T039 и T153 открыты.

## Сборка Simulator с раздельными UUID загрузки и задания

В `4753f2f` принят исходный коммит `8b1f131d4e6c92660192b13d3f422236376af902`. В `AnalysisFlowModel.swift` заморожен отдельный UUID для загрузки. `PlantsApp.swift` отправляет его на `upload-ticket` и сохраняет исходный UUID на `analysis/jobs`. В `CollectionWireTests.swift` проверены раздельные UUID и неизменные тела запросов при потере ответов билета и создания задания, подтверждение потерянного PUT и чтение задания по возвращённому ID.

Локально прошли diff-check, сборка и 204 Swift-теста без пропусков, Simulator smoke, Review и QA. По результатам `q-352f60300aabc9e3fb3f5d82` целевой тест `testStagingAnalysisRecoversLostUploadAndJobRepliesWithDistinctStableOperations` прошёл. Стендовая сборка отдельно прошла `xcodebuild`, установку, запуск и визуальную проверку пустой формы `Test account`. Фото Monstera из `catalogue/releases/skeleton-300-v1/media/48854fc7b2b6d711a508c396.jpg` добавлено через `simctl addmedia`. [Отчёт](validation/automation/tasks/parallel-ios-diagnosis-operation-ids.md).

Установка и запуск существующей `.app` на выделенном Simulator.

```sh
xcrun simctl install 32009F39-32EF-426B-A91E-31B368D6C27E '/Users/ruslansabirov/.codex/worktrees/d09a/Plants/DerivedData/StagingDiagnosis-8b1f131d4e6c/Build/Products/Debug-iphonesimulator/Plants.app'
xcrun simctl launch --terminate-running-process 32009F39-32EF-426B-A91E-31B368D6C27E app.narat.plants.stagingdiagnosis --narat-staging-analysis
```

По отчёту backend `d6b2bd5`, на `narat-staging` активны `plants-api` v3 и `analysis-worker` v1 из `368d0f2`. На стенде прошли Auth, `/analysis/access`, выдача билета, PUT в приватный Storage и `/media/complete`. Прямое чтение отклонено. `POST /analysis/jobs` с отдельным UUID вернул `503 PROVIDER_UNAVAILABLE`. На стенде отсутствует `ANTHROPIC_API_KEY`, задания и вызовы провайдера не созданы.

Сверил iOS-клиент с `diagnosis-photo-http.md` из `d6b2bd5` по раздельным UUID, PUT с Bearer на том же origin, подтверждению загрузки, созданию и опросу задания, nullable-названиям. В этой сверке исходники iOS не менялись, сборку и тесты повторно не запускал. После настройки ключа backend повторит smoke `staging-monstera-20261111-01`. Затем в Simulator войти через `Test account`, открыть `Diagnose a plant problem` и проверить Monstera и неоднозначное фото. T037–T039 и T153 открыты.

## Подключение к стенду и форма входа

В `b62645b` приняты `Info.plist`, `project.yml`, `PlantsApp.swift`, `APIModels.swift`, `AnalysisFlowModel.swift`, `PreliminaryResultView.swift` и `CollectionWireTests.swift`. Debug Simulator включает HTTPS-подключение к заданному тестовому origin по флагу `--narat-staging-analysis`. Сервис привязан к постоянной учётке и показывает полученные EN-названия или неопределённость. В `e8b6069` исправлена пустая форма входа в `PlantsApp.swift`.

Оба этапа прошли diff-check, сборку и 204 Swift-теста без пропусков, Simulator smoke, Review и QA. Установил staging-сборку исходников `b6c3f16` на выделенный Simulator и визуально подтвердил `Test account`, `Email`, `Password` и недоступный `Sign in` при пустых полях. Вход из приложения и живой диагноз не запускались. [Подключение](validation/automation/tasks/parallel-ios-staging-diagnosis.md), [форма](validation/automation/tasks/parallel-ios-staging-account-form.md).

QA backend выявил конфликт двух команд с одним UUID в общей `operation_receipts`. Исправление принято отдельным этапом выше.

## HTTP-транспорт фотоанализа принят

В `14f6d8b` приняты изменения `APIModels.swift`, `PlantsAPIClient.swift` и `CollectionWireTests.swift`. Клиент использует привязанный к сессии Bearer, SHA-256 JPEG, проверенный origin и точный путь PUT, подтверждение загрузки и создание/чтение задания. Ревью первой попытки выявило пропущенные поля билета и проверку диапазонов кандидатов. Исправления вошли в повторную приёмку.

Локально прошли 202 Swift-теста без пропусков, сборка, Simulator smoke, независимые Review и QA. Результаты транспорта получены на моках. Следующий шаг — принять Debug-подключение, собрать .app с публичной конфигурацией стенда, проверить форму и дождаться безопасного входа для двух реальных фото. [Отчёт](validation/automation/tasks/parallel-ios-analysis-http-wire.md).

## Галерея и результат анализа готовы для подключения к стенду

В `cfc47a3` приняты `AnalysisFlowModel.swift`, `CareQuestionsView.swift`, `PreliminaryResultView.swift` и тесты `FirstHelpUnitTests.swift`. Выбор из галереи использует текущую нормализацию фото. Повтор сохраняет замороженный запрос, результат после отмены или смены ввода отбрасывается. Экран показывает полученные названия, неопределённость или ошибку.

Локально прошли сборка, welcome, 197 Swift-тестов без пропусков, Simulator smoke, Review и QA. Фото и ответы в unit-тестах являются фикстурами. T037–T039 остаются открытыми. [Отчёт](validation/automation/tasks/parallel-ios-gallery-analysis-flow.md).

Согласованный wire B включает выдачу билета по UUID и SHA-256, PUT JPEG на точный путь `/functions/v1/plants-api/media/uploads/{photo_asset_id}`, подтверждение `/media/complete`, создание и опрос задания. Для ручного прогона нужны подтверждённый endpoint, постоянный тестовый email-аккаунт и опубликованные EN-названия. Родитель сообщает, что ключ провайдера ещё запрошен. Следующий шаг — принять клиентский транспорт, затем собрать тестовый вход и проверить оба фото на стенде.

## A: единственный T036 пилот принят, измерен и остановлен

Run `parallel-ios-t036-access-wire-pilot-20261110-01`, ровно1task `parallel-ios-t036-access-wire-pilot` — **COMPLETED / Verified and published**, accepted commit **e04103f41518f524d82fca9e099edf14a6a931c6** только в origin/codex/plants-ios. По договорённости пилот закончен: НЕ запускать новый task/run, внешнийrepair/другуюинтеграцию/CI/mainpromotion. [Измерения и сравнение](validation/automation/parallel-ios-t036-access-wire-pilot-2026-11-10.md), [JSON со всеми вызовами/путями](validation/automation/parallel-ios-t036-access-wire-pilot-2026-11-10.json), [отчёт задачи](validation/automation/tasks/parallel-ios-t036-access-wire-pilot.md).

**Документирование отдельно:** первый отчёт/stopcheckpoint **7011daf** опубликован ownbranch, подтверждениеUTC **2026-11-10T20:30:16.415Z**; послеrun это **422.257s** (~7мин2с) controller metrics/MD/JSON/handoff/docchecks/commitpush. Полный наблюдаемый путь задание→первыйотчёт **1799.415s** (~30мин), а не только935.649s runtime. Последующая короткая confirmation — metadata, без моделей/продуктовыхchecks.

**Сделано:** отдельный canonical `AnalysisAccessWireDTO` с owner_id/guest, одним sharedmonthly, nullableunknown, camelCase modes и исходными timestamp strings; реальный `PlantsAPIClient.fetchAnalysisAccess(context:expectedGuest:)` с captured bound lease/token, expected200, owner/kind проверкой послеawait, credential для guest/без него для permanent, failclosed errors/cancel/A-B/ABA. Только3existing Swift files: APIModels(+245),PlantsAPIClient(+28),CollectionWireTests(+414), прежний код/тесты сохранены. Семь встроенных canonicalfixtures точно совпали с6d689b7. Repository/UI/billing/installation HTTP/GETlive не подключены. Это один decode/transport сценарий, не весьT036.

**Реальные checks, каждый один раз — PASS:** diff0.024s; build/welcome/**191 unit**,184прежних+7новых,188XCTest methods+3SwiftTesting,0fail/skip/expectedFailure, sourcecoverage188/188 (`q-750c7fa9c2a28d4e30e1430f`),89.339s;Simulator smoke24.838s, QA просмотрела screenshots. Независимые highriskAstraReview81.336s иQA101.714s PASS безfindings; DeveloperSolmedium630.584s. Riskhigh/complexitymedium/criteria не менялись. SQL/Deno/automation/18ENPLUI/Release/CI/fullintegration не запускались; прежние результаты не выдаются за новые. Local/mockfixtures ≠ liveAuth/Supabase/GET/provider/StoreKit.

**Время UTC:** первое наблюдение получения20:00:17; transfer/config/gatesready20:07:38.566; realrunstart20:07:38.582; endrun+publication20:23:14.158. Prep **441.566s** (включая2merge/ручныеконфликты/config/manifest/preflight/commitpush); runtime поmonotonic **935.649s**. Модельное время **813.634s**, checks **114.201s**, controller/I/O/Gitпрочее **7.814s**. Wrapper exec17865/PID75324, orchestratorPID75332 завершились exit0. Последующий отчёт/stopcheckpoint не включён в runtime.

**Вызовы/повторы:** ровно3фактическихcalls: Developer `gpt-6.1-sol` medium/full/session01a1c712-c95a-7a53-a868-ebbea9e703cb; Reviewer `gpt-6-astra` high/full/session01a1c71d-cb80-7d53-9419-cbce5d56c5d8; QA `gpt-6-astra` high/full/session01a1c71f-6d95-74d0-93e7-d8e521c53342. ВсеPASS/retry0/error_category=null. Developerrepair0, re-review0, QArepeat0, timeout0. Два deterministic phase checkpoints Review/QA без LLMвызовов; contextreuse/timeoutreplan на этом cleanпилоте не понадобились. Все rawfields/elapsed вJSON, ambiguousCLI tokens не суммировались и не переводились в процент квоты.

**Воспроизводимость:** engine25a5830ca5447a3b25e7abd37350759e3e0841f3, mergeA20f49b6; packageSHA7f5f41e41e537612319aa9b702a3d3cfc4a6bde1eca032f3ee36591f4ab1ff2f. Config `parallel-ios-t036-pilot.config.json` SHA6bd5008b1fa38b96938a9f82a6eb14d92e309006743fe2db7d27b1bcee88a523 (толькоcontext6/read16000+preflight, прежниеchecks/providers/budgets900/publishA), before/after byte-identical. Validate1/fullcontext/actualPBX5SwiftSources+7inputs/evidence/scriptpaths PASS доrun. Engine package и CI files unchanged после переноса; source/contracts/tools1530files доa785d63abb8e539291a4fc4a73e8bdcc09d878bb46eeb895963345a17ebdbced, послеaeb2c2ca849cf4bddc7b8993e4eec43b3a42b488dc80e1eeea157189cee66437. Final taskfingerprint5a8664018513adf2e0e4c45f63096ddc3a34e1d59c6871e7ab53158bae6ced91, quality_contract85e2f9441290fdbaccf431938759c1831fef76be94135d8db6d6e0270b8311f2. State/metrics: ignored `docs/validation/automation/runs/orchestrator-parallel-ios-t036-access-wire-pilot-20261110-01/{state.json,metrics.jsonl}`.

**Сравнение:** closestA1canonicalsync transport прошёл3runs: WAITINGDeveloper3 (503.746+475.298s, третий elapsed неизвестен), BLOCKEDcompile41.029s, COMPLETEDcompile-repair7cb5893 (D48.141/R62.761/Q66.201s,checks71.535s). Последний был готовымкандидатом/riskmedium/SolReviewQA/43unit, новый — freshmonthly/ownertransport/riskhigh/Astra/191unit. Quality_contract разные, oldprep/runtimewall неизвестны; unknownelapsed не ноль, calls/checks не walltime. Новый код принят в1run безповторов, основной runtime — Developer630.584s; **причинное ускорение не доказано**. Это малыйпилот, не процентэкономииквоты.

**Стоп подтверждён:** stateCOMPLETED/done/inflight=null, PID75332 отсутствует; остаточный A mobilecli daemonPID80483 остановлен SIGINT(exit0), `ps` обоихPID показал отсутствие. Новых model/check/runtime послеterminal нет. Документационные JSON/links/diff проверки ниже не product gates. Main остаётся5d15123e1271f93e7575433d4a09f7f04612e64a; никаких CI helper/manifest/workflow изменений относительноначального2aafbdd. Последний новый BacceptedGET123c123 только принят к сведению, НЕ merged и НЕ основание следующегоrun.

**Точный следующий шаг:** сохранить эти MD/JSON/handoff/tasks ownbranchcommit/push, передать измерения родителю и ждать отдельного решения владельца. Автоматически не продолжать. T036/T163/T006/live открыты;15из151done/136open.

## Единственный T036 pilot manifest/config/preflight готовы

`tasks.parallel-ios-t036-access-wire-pilot.json` содержит РОВНО1task `parallel-ios-t036-access-wire-pilot`, riskhigh/complexitymedium. Write только3existing Swift files APIModels/PlantsAPIClient/CollectionWireTests; новыеtargetfiles не нужны. Реальный boundlease APIClient GETanalysis/access,7canonicalnullablefixtures, owner/sharedmonthly/exacttimestamps/failclosederrors/A-B-ABA. Repository/UI/billing/GETlive/installation mutations исключены. Старые184unit сохраняются, новые сценарии должны реально выполниться; fullT036/T163 не закрываются.

**Подготовка PASS, безmodel calls:** validate1; полный Developer context просмотрен; direct actual `verify_inputs` проверил все7inputs/nonemptyevidence и реальныеPBXfileRefs/Sources5Swiftfiles вPlants/PlantsTests. Конкретные scripts/executable paths существуют. Selected checks строго diff-check,`parallel_ios_sync_gate.py` all-source ios-tests(unitlocal1800s),`simulator_smoke.py`(qalocal1800s). SQL/Deno/CI/18UI/Release/fullintegration не выбраны и не запускаются. No newXcodegenneeded becauseexistingfiles membershipPASS.

**Ignored branch config:** `parallel-ios-t036-pilot.config.json`,SHA256 **6bd5008b1fa38b96938a9f82a6eb14d92e309006743fe2db7d27b1bcee88a523**. JSONdelta относительно старогоparallel-ios.config только новый context6/read16000 и preflight. Checks/providers/roles/budgets3/3/3/agenttimeout900/sessions3turns/maxrun14400/publishorigin/codex/plants-ios сохранены. Новая routinglogic25a5830: DeveloperSolmedium поcomplexity, highriskAstraReview/QA отдельно. Политикигейтов не ослаблялись.

**Следующий шаг:** сохранитьmanifest/handoff/tasks иpushA → cleanrun РОВНО `parallel-ios-t036-access-wire-pilot-20261110-01`. После любого terminal илиtimeout STOPиотчёт родителю; без2ndrun/externalrepair/mainpromotion/CI. Prep/run/endUTC иполные role/check elapsed/retries/error/session/qualitycontract будут записаны отдельно; ближнийbaselinecanonicalsync transport7cb5893, qualitycontractдругой — причинноеускорение пока не доказано.

## Принятый SQL/wire prerequisite6d689b7 перенесён для пилота

Обычный bounded merge только **6d689b7** после engine20f49b6. Добавлены SQL011/012, registration_installations/access tests, gateflags и agreedcontract/7nullablefixtures. ProductionGETHTTPcandidate из более поздней Bветки НЕ включён. Единственный конфликтhandoff разрешён вручную: история/актуальные15-of151/пилот A сохранены, B-specific records архивированы ниже; ProjectState/TaskSummary A не затёрты. SQL/TS/contracts/toolbytes сверены с6d, iOS и CI helpers/manifests/workflow не менялись. Это разрешённая предпосылка одного DTO/transport сценария, **не дополнительная полная интеграционная приёмка**. B511pgTAP/6x20/Deno336/automation123 — прежнее evidence B; SQLsuite/CIне запускаются в Aпилоте.

## Пилот throughput A: подготовка переноса и одного T036 wire пакета

Родительский чат01a1c3b4 передал прямое разрешение владельца, прочитанное A: «перенесём изменения в Plants A и Plants B и запустим по одному следующему пакету… CI пока не трогаем». Допустим один новый runtime `parallel-ios-t036-access-wire-pilot-20261110-01`,один task; новый terminal/timeout завершает пилот без другого run/repair controller/mainpromotion. Внутренний repair в исходном budget разрешён, timeout требует replan и остановки. A/B/parent техническая координация разрешена.

Между runs обычный merge25a5830 (ancestorcf5a6b1). Ручные конфликты только handoff/T006: текущая история/исходники A сохранены, новые audit/policy records сохранены ниже с датой; blanketours/theirs/reset/rebase/force нет. Engine/context/preflight/docs/config/tests совпадают с принятой веткой; no CI files изменения. ORCHESTRATOR.md и новый README прочитаны. Родительская приёмка147automationfixtures48.177s — evidence parent, не новый A запуск и не product proof.

Следующий подготовительный шаг: сохранить merge, перенести только принятый6d689b7 SQL005–012+nullable wire (без более позднего unacceptedHTTP), затем собственный ignored config с новым context6/read16000/preflight и прежними lanechecks/providers/budgets/publishA. Scope product: только APIModels/PlantsAPIClient/CollectionWireTests; реальный transport/owner-bound exacttimestamps/nullable sharedmonthly fixtures, без repository/UI/billing/GET live. Existing Swift membership проверяется preflight до моделей. Не добавлять CI coverage/полную SQLintegrationприёмку. T036/T163/T006 остаются открыты,15/151done.

UTC отметки получения/подготовки/run/end сохраняются в `/tmp/parallel-ios-throughput-pilot-timing.json` и итоговом отчёте; prep и runtime отделить, все вызовы/retries/timeouts/checks/quality_contract показать без суммы ambiguousCLI tokens/процента квоты. Точный следующий шаг после terminal — остановка и отчёт родителю, не следующий пакет.

## Остановка A перед изменением конфигурации (10 ноября)

Из родительского чата `01a1c3b4-0e9e-73b2-a2cd-dbdb0e56172a` получена команда владельца: «Нет, давай пока остановим оркестраторы — нужно поменять конфигурацию». Прямое сообщение владельца в родительском чате проверено read-only; там же GitHub Actions отложены. Эта команда отменяет все прежние следующие шаги очереди ниже. **Не возобновлять автоматически, не запускать новые runs/repair/Review/QA/интеграции и не менять config.**

**Фактическая остановка процессов:** последний `parallel-ios-ci-b1-sql-acceptance-20261110-01` уже завершился до команды: exec-session53217 завершена **exit0**, stateCOMPLETED/phase done/inflight=null, publication6bef6771fcbcc171438c0653ddecb61736490069. OS PID активного A orchestrator/model/check отсутствовал, поэтому SIGINT не отправлялся уже завершённому CLI. `ps` проверил процессы: остался A check-service **mobilecli daemon PID4918/PPID1/PGID4918**; отправлен штатный `kill -INT 4918`,exit0. Последующий `ps -p4918` вернул только заголовок/exit1 — процесс отсутствует. Пользовательские приложения/CUA runtime и B-процессы A не завершала. Отдельная Git fetch session77846 завершилась exit0; новых Git integration/main mutations после стоп-команды нет.

**Сохранённый результат/исходники:** B1 integration6a83f0e и CIextension6bef677 приняты local/fixture и отправлены в origin/codex/plants-ios. Main остаётся **5d15123e1271f93e7575433d4a09f7f04612e64a**: запланированная публикация B1+CI отменена ДО commit/push main. Отдельный integration checkout тоже остаётся5d15123. Прежний CIrunBLOCKED по missingdiff сохранён; последняя новая independentReviewQA PASS. Последний sourceSHA **bcfb0a8329fec4c7062630fad76de7397f7074dbd6d2ea58b82284bff9799432 /1522files**, helperSHAe2187850e2b0a629b0510ebcd4b887a0169819e98b7c1430afc15a25ed4c5124. CI config SHA **11402e73be3c5133239e0b139312aaff218ffa756ec90d525dd9ab91c784e437** перепроверен и не менялся. Runtime/backend/CI source после последней приёмки не менялись; незавершённые изменения были только handoff/tasks, они сохраняются этим stop-checkpoint в своей ветке без новой model-приёмки. Reset/clean не выполнялись.

**Реально завершённые проверки до стопа:** B1 combined184unit/build/welcome/Simulator,384bind+235cap/6x20/4capraces/336Deno/123automation/frozenTypecheck/ReviewQA PASS; новый CIactualhelper235+384/6x20+4cap/oldrows/UTC/cleanup26.761s,123automation38.744s/336Deno/YAML9Bash/diff/ReviewQA PASS. После стопа — только read-only state/process/config/Git-status и сохранение handoff; новых продуктовых/CI checks нет. Полные18UI/42PNG/Release ранее приняты T162 и не выдаются за новый запуск. CloudCI/live не проверялись.

**Незавершённое, сохранено без запуска:** B передала точный merge-ready **6d689b7** (SQL011/012+agreednullfixtures, без HTTP runtime); он не merged в A. Старое «44dc?» не SHA и не основание для интеграции. DTO-only draft `/tmp/tasks.parallel-ios-monthly-access-dto.json` и B2 integration draft `/tmp/tasks.parallel-ios-b2-sql-integration.json` сохранены вне проекта, не приняты и не запущены. B productionGETcandidate исключён. T036/T163/live остаются открытыми. **T006 открыта и отложена решением владельца**; не искать/запускать GitHub Actions сейчас.

**Точный следующий шаг:** обсуждение и явное согласование новой конфигурации в родительском чате; A ждёт отдельной команды возобновления. После неё сначала сверить сохранённые SHA/чистоту/state и применимые новые инструкции, а не продолжать старую очередь автоматически. Текущий stop-checkpoint commit/push только origin/codex/plants-ios; main не трогать.

## B1+CI окончательно приняты и готовы к ordinary main promotion

Read-only run `parallel-ios-ci-b1-sql-acceptance-20261110-01` — **COMPLETED / Verified and published**, commit **6bef6771fcbcc171438c0653ddecb61736490069** в origin/codex/plants-ios.1Reviewer/1QA PASS; точная дельта6a83f0e→c63b896/полныйbasehelper/обеSHA/whitelist проверены независимо. Старый BLOCKED оставлен историей, его state/answers не исправлялись. [Отчёт](validation/automation/tasks/parallel-ios-ci-b1-sql-acceptance.md). Runtime/contracts/tools SHA до/после **bcfb0a8329fec4c7062630fad76de7397f7074dbd6d2ea58b82284bff9799432 /1522 files**, enginee91dbe4f804502b300d022d0084bd79af9ee6076a77ccbed080e2d064a05a0ae.

**Новые реальные5checks PASS:** YAML9Bash/diff;123automation38.744s OK;336Deno/0fail;один portableCIhelper26.761s последовательно выполнил cap/legacy235pgTAP clean/upgrade+4realcapraces и bind384pgTAP clean/upgrade+6раундов20observedconnections после99actualadmit/finalize, oldrows/UTC/cleanup сохранены. Current helperSHAe2187850e2b0a629b0510ebcd4b887a0169819e98b7c1430afc15a25ed4c5124. Workflow/SQL/iOS/engine неизменны. **184Swift/build/welcome/Simulator** свежие из принятой B1интеграции6a83f0e на том же iOS/backend source; в tinyCIpacket повторно не выполнялись.18UI/Release предыдущего T162 тоже не выдаются за повторные.

**Далее:** ordinary promotion принятого B1+CI из отдельного чистого checkout после ancestor/fingerprint/diff-check; подтвердить refs и отправитьB новыйmainSHA. Product checkbox15/151/136open, T006 cloudCI/T036/T163/live открыты. GitHub cloud не наблюдался; локальная конфигурация не его результат.

**Следующий уже разрешённый bounded пакет B:** точный **6d689b7** (не «44dc?» и не tip). SQL0116df1b76/012b44013e independently accepted, agreednullablefixtures2monthly.limitNULL; productionGETruntime исключён. B combinedsource93a54cf после ordinary merge main5d: clean/upgrade511pgTAP,12UTC,99actual+6x20,cap55+131/4races,336Deno/typecheck/123automation PASS — это пока evidence B, не Aintegration. A read-only сверила file scope и nullablewire. После завершения mainpromotion взять только6d689b7 междуruns; CIsecondcall расширить с--bind до--bind/--installations/--access и дать точный comparative proof заранее. Freshall184Swift/Simulator/portablecap235+access511/Deno123ReviewQA на новом combinedsource. DTO-onlyT036draftв/tmp согласован с6dnullablewire; API/repo/UI не включены, стартует после этой интеграции.

## CI SQL extension: реальный suite PASS, QA потребовала comparative diff

Run `parallel-ios-ci-b1-sql-20261110-01` остановлен **BLOCKED** на QA AC1;1Reviewer PASS/1QA BLOCKED. Все5checks PASS: diff/YAML9Bash,123automation(38.573s),336Deno,actual portable adapter(26.073s) последовательно cap235each/4races и bind384each/6x20/99actual/oldrows/UTC. QA AC2PASS и подтвердила failure/cleanup semantics, но не могла доказать минимальность дельты: task.patch пуст у read-only задачи, а controller не передал явный comparative diff и запретил Git слишком широко. Это ошибка подготовки evidence, не функциональный FAIL и не approval rejection; исходные run/state/answers сохранены.

**Исправление между runs:** [точный delta evidence](validation/automation/parallel-ios-ci-b1-sql-delta-2026-11-10.md) создан actual read-only git diff **6a83f0e → c63b896**: все4changedpaths, полный исходный helper, unified11line diff, SHA before/after. Единственный runtime code delta — последовательный cap+bind в controller-owned CIhelper; остальные manifest/handoff/tasks. Текущий helper точно совпал с c63b896. Новый `tasks.parallel-ios-ci-b1-sql-acceptance.json` явно разрешает read-only Git, read-only/noDeveloper, отдельные Review/QA и повтор всех5actualchecks на своём identity. ConfigCI11402e73 неизменен. Business source/helper/SQL/workflow не менялись при исправлении evidence.

**Проверки подготовки PASS:** manifest VALID(1), полный Reviewer context просмотрен, exact candidate helper SHA совпал; код helper/SQL/CI/iOS unchanged. **Точный следующий шаг:** diff-check → commit/push подготовки → clean run `parallel-ios-ci-b1-sql-acceptance-20261110-01`; после полного PASS сверитьsource и ordinary main promotion B1+CI из отдельного чистого checkout, сообщитьB новыйSHA. Main5d15123, T006/T036/T163/live открыты,15done/136open. DTO draft в/tmp ждёт окончательный Bwire/fixtures; неизвестный monthly.limitnullable, old3 не правило. SQL11/12 не интегрировать без явного merge-readySHA.

## B1 интеграция принята; CI расширяется на весь принятый SQL-пакет

Run `parallel-ios-b1-integration-20261110-01` — **COMPLETED / Verified and published**, commit **6a83f0e940626e00122db7c7d6de73c055690418** в origin/codex/plants-ios. Без Developer;1 high-risk Reviewer/1 QA — PASS. [Отчёт](validation/automation/tasks/parallel-ios-b1-integration.md). Merge43bc566 содержит только разрешённый bc6a879/runtimea367d0b, SQL11/12 исключены. Source fingerprint до/после **bb967bcf33a6a32b911aaaf6146c7039e396626c1e1f2247778dfc699e1744ca /1520 files** совпал; engine403bf4231b65d9203c04b932fbf3e2f20aaaba185fd197b02be7921adee2575a.

**Реально повторены на combined source — PASS:**184 PlantsTests (181XCTest+3SwiftTesting),0fail/skip/expectedFailure, build/welcome/all source methods (`q-5092666f9153905b16f9f2fd`);Simulator (`q-63a92e7a1d59a6dc2e97b6df`), QA просмотрела оба снимка;336Deno/123automation/frozen API+worker typecheck/diff. SQL --bind: clean/upgrade по384pgTAP,12UTC cases,retainedrows;6раундов20 одновременно наблюдаемых owner-lock waiting connections с99 actual admit/finalize перед каждым, exact replay/nonbillable/pointers. Portable CI cap/legacy adapter отдельно235pgTAP clean/upgrade/4realcapraces PASS.18UI/Release не повторялись: iOS source/gates прежние, их T162 evidence сохранено отдельно. ПолныеT036/T163/live/deploy не приняты.

**Новый CI шаг, только ПОСЛЕ завершения integration run:** controller-owned `parallel_ios_ci_sql_gate.py` теперь последовательно вызывает неизменный accepted gate дважды: прежний --accounting/legacyguard/cap, затем --bind. Это закрывает gap: прежняя CI-команда исполняла только235 cap/legacy assertions, теперь должна исполнять также384bind/6x20. PG17/pgTAP проверки, failfast и finally argv restoration сохранены; каждый бизнес-suite создаёт свой privatecluster и cleanup. Workflow/SQL/assertions/iOS не меняются. Новый `tasks.parallel-ios-ci-b1-sql.json` READONLY, без Developer; actual portableSQL + YAML/Bash/diff/336Deno/123automation, независимые Review/QA. Config прежний CIacceptance SHA11402e73be3c5133239e0b139312aaff218ffa756ec90d525dd9ab91c784e437, routing/budgets/publishA неизменны.

**Уточнение B, ещё не новый merge-ready:** в двух старых draft fixtures monthly.limit3 для registration_required/history_unresolved будет исправлено B на NULL; mode.limit3/100 и denied remaining0 независимы. A согласовала nullable monthly.limit, старое3 не обязательное правило. DTO-only draft пока в/tmp, активный integration source ради сообщения не менялся. B SQL11 принята у B, SQL12 ещё вrun07; до полной точной передачи их не брать. Endpoint пока не operational.

**Проверки подготовки PASS:** py_compile нового helper, manifest VALID(1), полный Reviewer context просмотрен; helper SHA256 `e2187850e2b0a629b0510ebcd4b887a0169819e98b7c1430afc15a25ed4c5124`. Фактическое последовательное SQL выполнение ещё впереди. **Точный следующий шаг:** diff-check → commit/push A → clean `parallel-ios-ci-b1-sql-20261110-01`. Только при полном PASS — combined B1+CI ordinary main promotion из отдельного чистого checkout с итоговым source fingerprint, передать B новыйmainSHA. Main пока5d15123. Затем canonical DTO/T036 по окончательно принятому wire/fixtures; cloudCI/T006 ждёт доступ к GitHub.15/151/136open без новых checkbox.

## B разрешена владельцем; объединён только merge-ready SQL005–010

10 ноября прямое сообщение владельца в B подтверждает Developer/Reviewer/QA с передачей кода настроенным провайдерам, commit/push только backend и техническую координацию с A. Предыдущая блокировка разрешением снята; отказы остаются историей. A прочитала разрешение и сообщила B **main5d15123e1271f93e7575433d4a09f7f04612e64a**. B продолжает независимый run07; A её HEAD/config не меняет.

Между A runs объединён **bc6a879**, runtime **a367d0b**: SQL008 reserve141d548,009 finalize42ed071,010 bind a367d0b плюс тесты/gate/reports и отдельный B2 wire proposal. SQL005–007 уже были в main. **SQL11/12 и непроверенный tip4333509 не включены.** Единственный merge conflict — handoff: актуальные факты/15-of151/история A сохранены, B-specific historical sections добавлены с явной отметкой ниже. B ProjectState/старый TaskSummary не затёрли новый A статус. Backend business source A не редактирует.

**Предыдущая приёмка B (не подмена интеграционной):** --bind clean/upgrade по384pgTAP,12UTC,retained rows,6раундов20реальных waiting connections с99 actual admit/finalize перед каждым; cap/legacy55+131pgTAP/4races,336Deno/typecheck/115automation PASS. [Отчёт B](validation/automation/parallel-backend-quota-sql-acceptance-2026-11-09.md). Эти результаты пока не подтверждают новый A fingerprint.

**Wire compatibility:** A прочитала `monthly-access-http.md` и все7 synthetic cases. Additive контракт согласован ДЛЯ НОВОГО canonical transport DTO: обязательный owner_id/captured owner, один shared monthly, nullable unknown/status без выдуманных counts, camelCase mode keys, guest JWT+credential, opaque fractional timestamp strings. Existing `AnalysisAccessState` — локальный forecast с иной формой, не drop-in decoder; T036 потребует DTO/transport/conversion и fail-closed repository. collection-http неизменён. Endpoint/production API пока proposal; full T163/T036/live открыты.

**Новый read-only integration packet:** `tasks.parallel-ios-b1-integration.json`, без Developer; actual PG17 --bind и portable CI SQL cap/legacy adapter,336Deno/frozen API+worker typecheck,123automation,184Swift/build/welcome,Simulator; независимые high-risk Review/QA на окончательном source. UI/Release source/gates неизменны, их18UI/42PNG/Release предыдущего T162 — отдельное evidence, новый run их не заявляет повторными. Собственный ignored config отличается от CI-acceptance только добавлением bind-check; routing/budgets/publish только codex/plants-ios сохранены.

**Проверки подготовки PASS:** manifest VALID(1), полный Reviewer context просмотрен; отдельный ignored config SHA256 `37ce8523a661e1ad5ebcccc5e670c347c90fd5425a443647ea76a0d2cfa7b06d`, JSON-сравнение подтвердило единственную добавленную bind-check definition. **Точный следующий шаг:** diff/merge scope → commit/push merge+handoff+manifest → clean run `parallel-ios-b1-integration-20261110-01`. После полного PASS — source fingerprint/актуальный main/clean отдельный checkout и ordinary main promotion между runs; передать B новый SHA. Product checkbox не закрывать. Cloud CI/T006 требует доступа к GitHub; клиентская подготовка T036 доступна по согласованному proposal, production включение ждёт принятого B2 endpoint.

## CI опубликована в main; точка остановки — доступ к cloud evidence

Обычный fast-forward push из чистого `/private/tmp/narat-ios-integration-20261109-01`: **546880a → 8107152ac5dfcdb99538bae9040a2ee679eb7d96**, exit0. Remote refs main/iOS сверены после push. Принятая конфигурация45f7bec и handoff/tasks8107152 включены. Source fingerprint отдельного checkout **ebb221d176af636d42fd36846b3900c1f77c4b051c2695d90637c39ebb6038fb /1509 files** совпал с local acceptance до/после; clean status/diff-check/ancestor check PASS. Diff относительно прежнего main ограничен workflow, двумя CI helpers/manifests и документацией. Нового iOS runtime/backend/KB/contracts diff нет; исходный пользовательский checkout и B worktree не изменялись. Текущая confirmation меняет только handoff, source SHA сохраняется; она также сохраняется commit/push без force.

**Фактическая точка остановки:** local CI configuration завершена, T006/cloud execution незавершена. Main push соответствует trigger, но remote run/status/logs не наблюдались — не утверждать, что GitHub Actions запустился или прошёл. GitHub plugin available, installed=false; предложение уже показано один раз. Авторизованного browser session нет, gh отсутствует. Других облачных/live результатов нет. Установка/подключение плагина и разрешения аккаунта автоматически не менялись.

**Точный следующий шаг:** после подключения GitHub или входа в браузере найти workflow Validate Narat MVP (CI) для окончательного main SHA, дождаться всех4jobs (automation,Deno,SQL,iOS), проверить raw logs/ENPL PNG/исходные покрытия184unit и18UI/Release и privatePG17 clean/upgrade/races. Исправить cloud-only ошибки отдельным проверяемым этапом; только затем решить T006 checkbox. До этого15done/136open, parents/live открыты. Backend-зависимые задачи A ждут принятого B-контракта. В B автоматическая проверка разрешений отклонила новые CLI/model/push и межчатовую передачу из-за неподтверждённой авторизации; ожидающие запросы находятся в B, обхода через A нет.

## T006: локальная CI-конфигурация принята, cloud CI ещё не проверен

Read-only run `parallel-ios-fixture-ci-acceptance-20261110-01` — **COMPLETED / Verified and published**, commit **45f7bec7378b25e250a3365e1976680ba5141ce1** в origin/codex/plants-ios. Без Developer; 1 независимый Reviewer и 1 QA — PASS, unresolved findings нет. [Отчёт](validation/automation/tasks/parallel-ios-fixture-ci-acceptance.md). Source SHA256 до/после **ebb221d176af636d42fd36846b3900c1f77c4b051c2695d90637c39ebb6038fb**,1509 tracked files; engine fingerprint `69d39f3c0932adce756e00c941074fa304eec423bb8e1c5296bcfb2d0b4c8fe3`.

**Реально выполнено — все PASS:**
- YAML mapping + синтаксис всех 9 Bash bodies, diff-check.
- Frozen typecheck двух существующих entrypoints API/worker.
- Read-only выбор настоящего iPhone17Pro: SDK26.2/runtime26.3, `created=false`, exit0.
- **123 automation**,38.541s, OK; **336 Deno**,0 failed.
- Portable adapter → прежний private PG17 suite: clean/upgrade по **235 pgTAP**, по12 UTC/leap/timezone cases,4 реальные owner-lock retry/distinct-create гонки,1 plant/receipt, прежние public rows byte-equal. Raw logs — check7 в run; бизнес SQL/assertions не менялись.

**Изменённые файлы CI-этапа:** `.github/workflows/validate.yml`, два controller-owned `tools/automation/parallel_ios_ci_{sql_gate,simulator}.py`, два явных CI manifests; текущие handoff/tasks фиксируют результат. Workflow вызывает действительные automation/Deno/SQL и последовательно iOS unit/welcome,18 EN/PL UI,Release через принятые gates; action commits/Deno/Xcode закреплены, один динамически выбранный Simulator, ограниченные logs/JSON/PNG при success/failure. Приложение, iOS gates, backend SQL/TS/KB/contracts не менялись. **184 unit/18UI/42PNG/Release/Simulator** ранее приняты на точном неизменном iOS source в финальном T162 run; этот config-only run их повторно не запускал и не выдаёт за cloud evidence.

**Ограничения:** принята только локальная конфигурация и fixtures. Облачный runner, установка зависимостей и ветка создания CI-device ещё не наблюдались. GitHub plugin повторно подтверждён installed=false; browserloggedout/gh отсутствует. Старый BLOCKED run сохранён; новое config исправляет только summary-protocol аргумент, не ослабляет assertions. B-owned `deno.json check` содержит два отсутствующих index paths; workflow явно проверяет только реальные API/worker, исправление alias остаётся B. Живые Auth/providers/Storage/AI/StoreKit и зависимые родители открыты. T006 [ ],15/151; B approvals не обходятся.

**Точный следующий шаг:** сохранить handoff/tasks и отправить A → сверить origin/main ancestor и чистый отдельный checkout → ordinary main promotion с тем же source fingerprint → подтвердить remote refs. Затем наблюдать actual GitHub Actions и исправить возможные cloud failures; T006 закрывать только по реальному результату. Для наблюдения требуется установленный и подключённый GitHub plugin или вход в браузере. До этого cloud acceptance остаётся незавершённой.

## T006: workflow candidate сохранён; исправлен интерфейс локального check

Run `parallel-ios-fixture-ci-20261110-01` остановлен **BLOCKED**, 2 Developer, без Review/QA/публикации. Candidate меняет только `.github/workflows/validate.yml`: реальные automation/Deno/privatePG17/iOS gates, закреплённые actions, read-only token, serial Simulator, bounded logs/PNG. **Это ещё не принятый workflow.** diff-check PASS; actual Simulator selector дважды вернул exit0/created=false, но engine отметил FAIL: наличие `{check_run_id}` в env-output argv включает обязательный Doctor `summary.json`, которого read-only selector не создаёт. Второй Developer корректно не менял workflow ради ошибки controller-интерфейса; no-progress остановил run. Ошибка в подготовленном controller config; исходный state/check FAIL сохраняются без переписывания. YAML/typecheck/SQL/Deno/automation/Review/QA в этом run ещё не выполнены.

**Исправление между runs:** новый отдельный ignored `parallel-ios-ci-acceptance.config.json` отличается от исходного CIconfig только env-output argv: уникальный literal `/private/tmp/narat-ci-simulator-acceptance-20261110-01.env`, без protocol token. Сам selector, engine, бизнес-gates, routing/budgets/900s и publish target не менялись. Новый `tasks.parallel-ios-fixture-ci-acceptance.json` READ-ONLY/write_files=[]: без Developer, все фактические checks и независимые Review/QA существующего workflow/helpers. Старые manifest/config/run неизменны.

**Проверки подготовки PASS:** manifest VALID(1), полный Reviewer context просмотрен, diff-check; JSON-сравнение подтвердило единственный изменённый config argv. Новый config SHA256 `11402e73be3c5133239e0b139312aaff218ffa756ec90d525dd9ab91c784e437`, ignored подтверждён. **Проверки и границы:** кандидат и подготовка сохраняются отдельным checkpoint commit/push в A; это не main promotion. T006 [ ],15/151. GitHub plugin повторно проверен: installed=false, облачный CI недоступен для наблюдения, повторного предложения нет. **Точный следующий шаг:** validate/context/diff → commit/push checkpoint → новый clean read-only acceptance run; при полном local PASS отдельный handoff/tasks commit и ordinary main promotion из чистого checkout, затем проверка реального GitHub Actions после подключения аккаунта. Live и B approvals не обходятся.

## T006: подготовлена локальная приёмка CI-конфигурации

T162 уже опубликована в main: code277d97f + docs confirmation **546880a**,15/151. Все предыдущие runtime/gates остаются неизменными. Только ПОСЛЕ завершения и публикации этого этапа controller добавил2CI tools: `parallel_ios_ci_sql_gate.py` передаёт явные пути PG17/pgTAP в прежний принятый Bgate без изменения SQL/assertions; `parallel_ios_ci_simulator.py` выбирает действительный iPhone17Pro/runtime по xcrunJSON/SDKmajor, по умолчанию read-only, создание разрешено только explicitflag для ephemeralCI. Проверенные/tmp bytes совпали SHA122e0702/a41ceed0. Новый `tasks.parallel-ios-fixture-ci.json` разрешает Developer менять ТОЛЬКО `.github/workflows/validate.yml`; helpers/gates/config защищены, полная локальная Review/QA охватывает их тоже.

**Реальные подготовительные проверки:** SQL-adapter prototype py_compile + actualPG17 clean/upgrade по235pgTAP/4races/retainedrows PASS, missingbinnegativeexpectedexit2. Selector py_compile + actualread-only xcrun selection PASS: SDK26.2/runtime26.3/Adevice32009F39-32EF-426B-A91E-31B368D6C27E,created=false; envoutputUUIDverified, послеtypeIDguardповторPASS. Creationbranch в облаке ещё не проверялась. YAML/Bash compiler на Psych.safe_load(File.read)+bash -n: currentworkflowmapping/4Bashsteps PASS; malformedif/then negativeexpectedexit1. Первыйprototype safe_load_file не поддерживался локальнымRuby — исправлено до materialization. Frozen API/worker typecheck PASS; попытка устаревших4aliases выявила2несуществующих index paths, они не выдаютсязаPASS.

**CI-контракт:** сохранить mainpush/PR/cancel, стандартный read-only token;336Deno/замороженный typecheck2реальныхentrypoints;privatePG17+officialpgTAP1.3.4 peeledcommit968eb53a33114e83042b3bdb0c664b5b80cf8bdf;macOS26/Xcode26.3 build17C529, реальные unit/18ENPLUI/Release через существующие gates, динамический UUID, без XcodeGen regeneration; boundedtimeout и whitelisted syntheticJSON/log/PNG artifacts. Толькоfixtures, безpaidAPI/secrets/deploy. OfficialActionpins проверены publicgitlsremote: checkout3d3c42e5…/setup-python6d4fd22…/upload-artifactcf430e0…(v7),setup-deno22d081f…(v2branch). [Официальный runner image](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md), [setup-python](https://github.com/actions/setup-python), [DenoAction](https://github.com/denoland/setup-deno).

**Config:** отдельный ignored `parallel-ios-ci.config.json`, SHA256 **07e7ee0864a26d0d4638a607e326ab2b0a77cc3aa5ba170cd8715b3068c8bb1c**. По сравнению с прежнимUI3f добавлены ТОЛЬКО4checkdefinitions: realYAML/Bashsyntax, frozen2entrypointtypecheck, portableprivateSQL и readonlySimulatorprobe. Routing/budgets/agenttimeout/publishorigin/codex/plants-ios не менялись; старые1bf/3f/3d4configs сохранены. Фактические checks нового workflow будут исполнены после Developerpatch, это ещё не приёмка конфигурации.

**Проверки подготовки PASS:** validate VALID(1task), полный context просмотрен, py_compile обоих новыхtools, diff-check; собственныйCIconfigignoredподтверждён. **Ограничения и точный следующий шаг:** commit/push подготовки → clean run `parallel-ios-fixture-ci-20261110-01`. После локальной конфигурационной приёмки/ReviewQA — ordinary promotion в main междуruns, затем наблюдать реальный cloudCI. **T006 остаётся [ ] до облачного результата**; текущая приёмка только конфигурационная. GitHubплагин на последней проверке available/installed=false,предложенодинраз/неподключён;browserloggedout,ghнет, nativePRdiagnostics требует реальноизвестныйPRnumber (его нет), угадыватьнебудем. Bзапрос: исправить stale deno.json check aliases billing-webhook/index.ts/maintenance/index.ts при согласовании реальныхentrypoints; Aнеправитbackendconfig/невыдумываетhandlers. Bmodel/push/messaging approvals ожидаютсявB; обхода нет. Последующие backend-dependent/livescope задачи остаются открытыми.

## Публикация T162 в main подтверждена

Из отдельного чистого `/private/tmp/narat-ios-integration-20261109-01` выполнен ordinary fast-forward push **19e6c83 → 277d97f289b72c66195f5a68e2b081b55f386def**, exit0. `git ls-remote` подтвердил этот же полный SHA у **origin/main** и **origin/codex/plants-ios**. В checkout перед push выполнены clean status, diff-check и ancestor check. Source/contracts/tools fingerprint **d02fa14d4d7b151d50408e2043cb2b6ab6bdfc22cda5f3c6b4bc3b38030f4fe3 / 1505 files** совпал с результатом финальных проверок в A. Нового backend/KB/catalogue/contracts/.github diff нет; B008–012/4333509 не добавлены. Исходный пользовательский main checkout и B worktree не изменялись.

T162 закрыта по полной fixture-приёмке532984c,15/151; ограничения live и открытых родителей перечислены ниже. Текущая запись — только `docs/handoff_status.md`, подтверждение Git-публикации; runtime/проверенные исходники не меняются. Она сохраняется отдельным docs commit/push обеих веток с тем же source fingerprint.

**Следующий этап — T006 CI configuration:** между runs материализовать controller-owned SQL-adapter и read-only Simulator-selector из проверенных/tmp prototypes, собственный CIconfig и manifest с единственным Developer-write `.github/workflows/validate.yml`. YAML/Bash syntax, actual portable PG17, frozen2entrypointtypecheck/336Deno/123automation, независимыеReviewQA; приложение/gates не меняются. Только затем ordinary main promotion. Это локальная приёмка конфигурации; облачный CI ещё нужно наблюдать отдельно, T006 не закрывать до реального результата. GitHubplugin пока не установлен/не подключён, browserloggedout,ghнет; предложен одинплагин, повторное предложение не делать. Deno check alias содержит2несуществующих index paths — требование B, Aего не правит. B approval requests ожидаютсявB и не обходятся.

## T162 завершена; проверенный клиент готов к main promotion

Run `parallel-ios-t162-final-acceptance-20261110-01` — **COMPLETED / Verified and published**, commit **532984c** в origin/codex/plants-ios. Read-only, без Developer; 1 Reviewer / 1 QA высокого риска независимо проверили полный исходный T162 scope. ACK/pointer finding старого BLOCKED audit устранён в `91349a1` и перепроверен. Source во всём финальном run не менялся. **SHA256 до/после совпал:** `d02fa14d4d7b151d50408e2043cb2b6ab6bdfc22cda5f3c6b4bc3b38030f4fe3`,1505 tracked files.

**Свежие реальные checks — все PASS:**
- build/welcome/**184 PlantsTests**,181 XCTest + 3 SwiftTesting, все методы выполнены, 0 failures/skips/expectedFailures — `q-a98d924a1ad8f868463970ec`.
- **18/18 EN/PL UI**, 0 failures/skips/expectedFailures, все методы из source выполнены / **42 PNG** — `q-af2038950eaa889dc4a3539b`. Включены обе реальная ошибка SQLite ACK, Back, restart и восстановление записи; неизменные ввод/operation/server UUID; Free2/Paid4/второй экземпляр того же вида/cap3/409/503/потерянный ответ/отмена и успешный вход.
- actual isolated Release/DEBUG fixture exclusion — `q-7411e32670d0d8c4e8e79b0f`; Simulator — `q-15630839bf29b6a8d269a697`.
- **336 Deno / 0 failed**, API/worker deno-check; **123 automation / OK**, 39.588s; diff-check.
- PostgreSQL17 accounting/legacyguard/cap-regression: clean и seeded-upgrade по **235 pgTAP**, по 12 UTC/leap/timezone boundary cases; 4 наблюдаемые owner-lock гонки retry/distinct-create с одним plant/receipt; все прежние public rows byte-equal. Это регрессия уже принятого B005–007/T161, не весь T163. RawSQL/checklogs: `orchestrator-parallel-ios-t162-final-acceptance-20261110-01/parallel-ios-t162-final-acceptance/check-6-parallel-ios-integration-sql/`.

[Полный отчёт](validation/automation/tasks/parallel-ios-t162-final-acceptance.md). Reviewer/QA подтвердили retired typed writers/legacy bytes/history, preflight доenqueue, pending/savedtruth, явныйsame-operationretry, owner/lease/nativeguards, cardserverUUID и защиту pointer при неизвестном journal. T162 отмечена только после этой полной приёмки. **Текущие задачи:15 выполнено / 136 открыто / 151 всего.** T149/T148/T159/T155/Auth/live и прочие родители не закрыты.

**Файлы текущего завершения:** `specs/001-plants-ios-mvp/tasks.md`, `docs/handoff_status.md`, `docs/parallel/{README,session-ios}.md` — статус/следующий шаг; runtime и проверки уже сохранены в принятых commits card17d70f8/binding9b86251/views0bb8d21/UIdbd3b14/slots0016576/ACK91349a1 и связанных gate/target commits. История и отчёт старого BLOCKED audit сохранены.

**Интеграция:** после полного run повторный fetch origin PASS: main `19e6c83` всё ещё ancestor, diff backend/KB/catalogue/.github/contracts пуст. Separate `/private/tmp/narat-ios-integration-20261109-01` чистый на19e6c83; исходный пользовательский main checkout и B не трогались. CI-прототипы остаются только в `/tmp`, чтобы не изменить проверенный tools/.github fingerprint до promotion. B008–012 / 4333509 не включены.

**Границы:** это локальные real SDK/SQLite/HTTP fixtures и private PostgreSQL, не live Apple/Google/Supabase/Storage/AI/StoreKit, физическая камера, offline token expiry или process kill во время native owner transition. Фото/guestclaim/care/expiry/rootT170 и UI публичного каталога шире T162 остаются отдельно. Прежний welcome/problem/care сохранён.

**Проверки оформления PASS:** diff-check;151uniqueID/15done/136open, изменён только checkboxT162;4новые/изменённые Markdown-ссылки существуют; sourceSHAсовпадаетсfinalrun. **Точный следующий шаг:** docs-only commit/push iOS → между runs checkout этого commit в чистом integration worktree → сверить тотжеSHA по 1505 файлам → ordinary push origin/main. При движении main сначала merge и затронутые проверки. Затем подтвердить публикацию в handoff и перейти к локальной T006 CI implementation. Remote CI пока не проверен: GitHub-плагин не установлен/не подключён, браузер не авторизован, gh отсутствует. Stale deno.json check aliases ссылаются на отсутствующие billing-webhook/index.ts и maintenance/index.ts — требование B; frozen API/worker check PASS. B approvals ожидаются в B, не обходятся.

## ACK/pointer repair принят: 184 unit + 18 UI; начинается новый полный T162 acceptance

Run `parallel-ios-catalogue-ack-ui-repair-20261110-01` — **COMPLETED / Verified and published**, commit **91349a1** в origin/codex/plants-ios.1Developer/1high-riskReviewer/1QA. Четыре файла: `CatalogueSaveView.swift` консервативно блокирует new intent на unavailable/restoreFailed/invalid scope, проверяет реальный journal перед заменой pointer, защищает mismatching flow и записывает replacement pointer только после checkpoint; `CatalogueUIFixtures.swift` — DEBUG ackFailure/real allowsSave:false SQLite, ровно один prepared pending через accepted SDK/model/checkpoint/journal, writable reopening только после2реальных persisted POST; `CatalogueUIFixtureTests.swift` — real ACK failure/restart/body/receipt/oneUUID/recovery; `CatalogueSaveUITests.swift` —2новых EN/PL ACK cases с Back/несколькими restart/disabled change/frozeninput/actual durable card. Helpers/схема/SDK/SQL/gates/config не менялись.

**Реальные gates PASS:** build/welcome/**184 PlantsTests**,181XCTest+3SwiftTesting/0failed/skipped/expectedFailures (`q-317ea1031a97d56434d50273`); **123automation/OK**,37.361s; **18/18 actual UI**,0failed/skipped/expectedFailures,exactsource coverage/**42PNG** (`q-f383df117fa8ddaca2847b80`); actual Release/no DEBUG fixture markers (`q-97a9f67151c1f7f112f90d6d`); Simulator (`q-e6c9d915cb6252ce202d79c0`); diff/independentReviewQA. [Отчёт](validation/automation/tasks/parallel-ios-catalogue-ack-ui-repair.md). Unit отдельно доказал zeroPOST setup, повторные recreation не снимают fault, две ошибки actual SQLite ACK сохраняют прежние input/outbox/pointer, три POST имеют exactbody/operation и один servercommit, последующий writable ACK подтверждает самый первый serverUUID/receipt. Все183/16 прежних tests сохранены. QA просмотрел EN/PL failure/recovery PNG; controller отдельно4новых PNG — readonly/error/disabled change и настоящая recovery card в обоих языках. Live/SQL/Deno этим repair-run не проверялись.

**Остановка старого final audit не стёрта:** `parallel-ios-t162-final-audit-20261110-01` остаётся BLOCKED Reviewer finding. Этот finding исправлен и принят в repair, но полный исходный T162 scope ещё требует свежего read-only acceptance на конечном source. T162 пока [ ],14/151; main19e6c83. Accepted source/contracts/tools fingerprint ДО нового manifest: `c9b7fc40474abca3fc954d448591c5d920853f67fa71d24a87fc500a7be7c4e3`,1504trackedfiles. Между runs fetch origin PASS: main19e6c83 ancestor, backend/KB/catalogue/.github/contracts diff пуст; непроверенный B008–012 не добавлен.

**Новый пакет:** `tasks.parallel-ios-t162-final-acceptance.json`, read-only/write_files=[], explicit former ACKfinding verification + полный T162.183 прежних+1actualACK unit =>184;18UI/42PNG;123automation/336Deno/typecheck; PostgreSQL17clean/upgrade/oldrows/realraces;Release/Simulator; две независимые high-riskReviewQA. Сохраняются все границы live/больших parents и oldwelcome доT170. Собственный integrationconfig SHA256 `3d4f4be122c18b9f7c9bf00c1d527f2b1102546cb88f8e1985720d09d293003d` НЕ менялся, старые1bf/3fтакжеbyte-identical. Это новый manifest/run, не resume старогоBLOCKEDсновымконтрактом.

**Проверки подготовки:** validate VALID(1task), полный context просмотрен, diff-check PASS; config3d4f4be неизменен. **Точный следующий шаг:** commit/push подготовки → clean run `parallel-ios-t162-final-acceptance-20261110-01`. После полного PASS и одинакового final fingerprint — решение о T162 checkbox, ordinary main promotion из отдельного чистого checkout между runs, подтверждение commit/push. При движении main сначала merge/affected gates. T149/Auth/guest/media/care/expiry/StoreKit/live parents остаются открытыми.

**Следующая независимая T006 подготовка (пока /tmp, не реализация проекта):** `/tmp/parallel_ios_ci_sql_gate.py` SHA122e0702696e4cab7ff66716f8addba88741d5240c91f9cf4176b48d5e72d48e — adapter только dependency paths в прежний принятый Bgate; actualprivatePG17 clean/upgrade235each/4races PASS, missing-binnegativeexit2; py_compilePASS. Во время repair исходники проекта не менялись этим прототипом. Официальные GitHubActionrefs и pgTAPv1.3.4 commit сверены publicgitlsremote, заметки `/tmp/parallel-ios-ci-next-notes.txt`; CIworkflow не реализован/remoteCI не проверен. gh отсутствует; GitHubplugin available/installed=false, предложен, НЕ подключён; CUAhiddenActionsстраница404loggedout, login не выполнялся, CUAcompletion_summary выдан. PublicactionlintAPI дополнительно403rate-limit; это не CIresult и не approval rejection. Эти ограничения не останавливают доступную клиентскую работу. Bworkflow/model/push/messaging approvals по-прежнему ожидаются вB, обхода нет.

## Финальный аудит T162 остановлен на настоящем дефекте ACK → смена вида

Run `parallel-ios-t162-final-audit-20261110-01` — **BLOCKED / Reviewer1 FAIL**, read-only task без Developer. Runtime/Git не менялись, HEADfbcb999 clean. Все pre-review gates PASS на fingerprint `40927ea7f74f673f841dff1e77d340f04c82ad7bcea3273b92843a8ac630c633`: **183 Swift**/180XCTest+3SwiftTesting/0skips (`q-aa00b01517fa196146f26325`); **336 Deno**, API/worker deno-check; **123 automation/OK**,36.009s; diff-check; PostgreSQL17 clean/upgrade по**235pgTAP**, по12UTC/leap/timezone boundaries,4реальныеowner-lockraces, old public rows byte-equal. SQL check6 rawlogs внутри исходного run. Повторные final16UI/Release/Simulator и QA НЕ запускались, т.к. Review не пройден. T162 остаётся открытой14/151, main19e6c83 неизменён.

**Finding:** `CatalogueSaveView.shouldLockSelection` блокирует pending/busy, но разблокирует `.unavailable(.storageOrServiceUnavailable)` после ошибки записи SQLite ACK. При этом прошедший `testReadOnlyCheckpointAndACKFailuresNeverPublishSavedAndPreserveDisk` доказывает, что операция остаётся в outbox. `catalogue.change` может удалить единственный resumableFlow pointer, после restart UI теряет доступ к pending, хотя generic flush может отправить его позднее. Это функциональный дефект, не проблема gate/approval. Предыдущие source/UI/slot срезы остаются принятыми в своём scope; полного T162/main promotion нет.

**Новый узкий repair:** `tasks.parallel-ios-catalogue-ack-ui-repair.json`, allowed write только SaveView/DEBUGfixtures/FixtureTests/SaveUITests. Консервативно защищать unknown journal/restoreFailed/mismatching pending flow от нового намерения и потери pointer. Новый DEBUG ackFailure с реальным read-only SQLite после подготовки pending через accepted SDK/model/checkpoint/journal; actual server commit/failedACK/restart/exact retry/writable recovery, без ручного UI success/production hooks. Минимум1 новый realfixture unit =>>=184 и2 новых EN/PL UI =>>=18, все183/16 прежних сохранены;123automation/Release/Simulator/highriskReviewQA. Gate поддерживает дополнительные source methods и требует их все реально выполнить; его не менять. targets уже есть.

**Проверки подготовки:** validate VALID(1task), полный context просмотрен, diff-check PASS; все4 Swift files уже в targets, UIconfig3f707461 неизменен. Новая реализация/184unit/18UI ещё не запускались. **Точный следующий шаг:** commit/push handoff/tasks/repair manifest → clean run `parallel-ios-catalogue-ack-ui-repair-20261110-01` со старым UIconfig SHA3f707461. После accepted repair — новый read-only final acceptance manifest/run с проверкой finding и полных SQL/Deno/183+unit/18UI/Release/123automation/Simulator на конечном fingerprint. Старый BLOCKED audit/его config3d4f4be/state/logs не переписывать и не resume с новым контрактом. После полного PASS — решение о T162 checkbox и main promotion между runs.

**CI отдельно:** для T006 просмотрен workflow: iOS job содержит build-for-testing без actual tests, SQL job отсутствует. Remote CI не проверен: gh отсутствует, web Actions cache miss не доказывает состояние сервиса. Применён skill plugin-management, найден GitHub available/installed=false, предложен только этот плагин; он НЕ установлен/НЕ подключён. Это не блокирует локальный код/финальную T162 работу. [Официальные runner images](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md) подтверждают Xcode26.3 build17C529, совпадает с локальным xcodebuild -version; CI реализация ещё не начата. B approvals остаются в B; обхода/нового B merge нет.

## Последние slot-writers сняты; подготовлен финальный аудит T162

Run `parallel-ios-retire-slot-writers-20261110-01` — **COMPLETED / Verified and published**, commit **0016576** в origin/codex/plants-ios. 1 Developer/1 Reviewer/1 QA. `PlantTypes.swift`: FreeSelection Decodable-only, retired typed next-step encoding отвергается, Membership читает old slot/revision и absent defaults, но не пишет retired keys. `APIModels.swift`: Profile сохраняет legacy read/default false, новые typed writes без free_selection_explicit. `SyncPersistenceTests.swift`:4 новых meaningful tests — old/current/null JSON и все остальные поля, legacy selection/step decode/encode rejection, реальная SQLite/reopen/raw receipts/history/checkpoint revision и точный generic free_care.select payload/operation через реальный engine/HTTP503 fixture. Схема, engine, UI и raw historical receipt serialization не менялись.

**Реальные проверки:** build/welcome/**183 PlantsTests PASS**,180XCTest+3SwiftTesting,0failed/skipped/expectedFailures (`q-c3549bbca0772ad7ed851d99`); diff-check/Simulator (`q-1724c413b73b0ccbeda3770a`)/Review/QA PASS. [Отчёт](validation/automation/tasks/parallel-ios-retire-slot-writers.md). **123automation/OK**,37.085s, exit0 — отдельный controller запуск, т.к. manifest выбрал только Swift checks: `orchestrator-parallel-ios-retire-slot-writers-20261110-01/parallel-ios-retire-slot-writers/supplemental-automation.{stdout,stderr}.log`; не выдаётся за orchestrator check ID. SQL/Deno/16UI/Release в slot-run не выполнялись; их повторяет финальный аудит. Live не проверялся.

**Статический аудит после реализации:** rg по всем production Swift оставляет retired names только в legacy decode/encoding rejection и сохраняемом физическом SQLite revision; активного free_care.select writer/Free-trio UI нет. T162 пока НЕ отмечена: окончательная приёмка полного исходного scope отдельна. Прежние parent/live задачи открыты,14/151. Принятый source/contracts/tools fingerprint ДО audit manifest: `0beb010d3d11ff21c236060f01acd73d48e8dccefb3d76466c415fd9c97c0681`,1502trackedfiles.

**Интеграционная база проверена между runs:** fetch origin PASS, origin/main19e6c83 — ancestor текущего HEAD; diff по backend/KB/catalogue/.github/contracts пуст. Непринятые B008–012/4333509 не включены, исходный main checkout и B не изменялись.

**Новый финальный пакет:** `tasks.parallel-ios-t162-final-audit.json`, read-only/write_files=[] — без Developer, две независимые high-risk Review/QA всего T162. Полный final source0016576,179 прежних+4newunit, typed writers/legacy bytes/history/cap/pending/owner/native/Free/Paid/restart. Свежие обязательные checks: PostgreSQL17 accounting+legacyguard+cap clean/upgrade/real races;336Deno+API/worker typecheck;123automation;183unit/build;16actualENPL UI/PNG;actualRelease fixture exclusion;Simulator. Stale shared t161 --slots equality runner не используется.

**Config:** новый отдельный ignored `parallel-ios-integration.config.json`, SHA256 `3d4f4be122c18b9f7c9bf00c1d527f2b1102546cb88f8e1985720d09d293003d`. К прежнему UIconfig3f707461 добавлена ТОЛЬКО одна unit fixture check definition `parallel-ios-integration-sql` (600s), routing/budgets/agenttimeout/publishorigin/codex/plants-ios неизменны. Старые config1bf347cc и3f707461 byte-identical для аудита прежних runs. Все проверки фиксируются на одном fingerprint, исходники во время run не править.

**Проверки подготовки:** первый validate отклонил смешанные evidence modes в одном AC; критерии разделены на local и fixture без изменения checks. Повторный validate VALID(1task), полный context просмотрен, diff-check PASS; моделей/проверок runtime на подготовке не запускали. **Точный следующий шаг:** commit/push подготовки → clean read-only run `parallel-ios-t162-final-audit-20261110-01`. После полного PASS сверить fingerprint до/после, решить checkbox T162 ТОЛЬКО по полному исходному scope и ordinary promotion в main из отдельного чистого checkout между runs; при движении main интегрировать и повторить затронутые gates. Затем T006 CI доступна независимо (сейчас только build-for-testing, remote CI не проверен); backend-зависимые квоты/guest/expiry/care ждут B. B workflow approvals остаются в B и не обходятся. Live/auth/media/StoreKit/physical camera и полные T149/T148/T159/T155 не объявляются принятыми.

## Catalogue save: 16 реальных UI-сценариев приняты

Run `parallel-ios-catalogue-rendered-ui-20261110-01` — **COMPLETED / Verified and published**, commit **dbd3b14** подтверждён в origin/codex/plants-ios. 1 Developer / 1 high-risk Reviewer / 1 QA. Изменены `CatalogueSaveUITests.swift` (16 настоящих EN/PL методов), `GuestCatalogueView.swift` (явный новый экземпляр условно снимает current-owner resume pointer, сохраняя SQLite/receipt/history), `CatalogueSaveView.swift` (keyboard focus/Done), `PlantsApp.swift` (закрытая проверка DEBUG-флагов). Полный view candidate, включая предыдущие экраны0bb8d21, проверен независимо.

**Реальные проверки PASS:** build/welcome/**179 PlantsTests**, 0 failed/skipped/expectedFailures (`q-72b884fc3e5b0436556332d1`); **123 automation / OK**; actual **16/16 CatalogueSaveUITests**, 0 failed/skipped/expectedFailures (`q-df2f58f6b00420dfe1630b98`), exact source-method coverage и **32 PNG**; isolated Release + fixture exclusion (`q-0e8582da6287b4f7ae54f410`); Simulator smoke (`q-e9cea1953871c5df355964cb`); diff-check/Review/QA. [Отчёт](validation/automation/tasks/parallel-ios-catalogue-rendered-ui.md). QA просмотрел итоговые PNG всех16 и дополнительные saved/lost-response состояния; контроллер отдельно визуально проверил4 PNG: PL cap/PL nativecancel/EN paid card/EN503 — текст/кнопки помещаются, IDs не видны.

**Доказанные fixture-сценарии в обоих языках:** Free2→save→restart same card→явный второй экземпляр ТОГО ЖЕ вида→cap; paid4→save→restart→второй экземпляр того же вида с другим serverUUID→restart; cap3; server409/503 с frozen input/same operation/retry/restart; committed lost response→restart→explicit retry→same durable server card; отмена Apple/Google→restart без потери ввода; успешный вход→permanent owner→save→restart same serverUUID без новой публичной species preference. Переключение locale в pending сохраняет операцию. Реальные SDK/SQLite/mock HTTP ledger, не присвоенные вручную UI success states. SQL/Deno этим Swift-only пакетом не запускались.

**Границы:** local DEBUG fixtures НЕ подтверждают live Apple/Google/Supabase/Storage/AI/StoreKit, offline token expiry или process kill внутри native owner transition. T149/T148/T159 и широкие parents открыты. T162 ещё частична: осталось снять unused typed slot encoders с legacy decode и выполнить финальный аудит/интеграцию; checkbox14/151. Main19e6c83 пока без новых card/binding/views. B candidate не включён. Fingerprint принятого runtime/contracts/tools ДО slot manifest: `932bd0ef11f0983e0e6610e78b20c81db2ad1cc22f9aa90f26d48441838d57fd`,1501trackedfiles.

**Следующий узкий пакет:** `tasks.parallel-ios-retire-slot-writers.json`, write только `PlantTypes.swift`, `APIModels.swift`, `SyncPersistenceTests.swift`. FreeSelection — legacy read only; новые Profile/Membership encoders без retired flags/slots, absent-key defaults без потери прежних значений и остальных полей. Retired typed next-step не сериализуется заново, raw historical receipt/очередь/SQLite revision/history не переписываются. Минимум4 meaningful encoding/durable reopen tests, все179 прежних сохранены, >=183 фактических/no skips; build/123automation/Simulator/independentReviewQA. Source/UI/helpers/SQL/schema не менять.

**Проверки подготовки:** validate VALID(1task), полный context просмотрен, diff-check PASS; runtime этого пакета ещё не менялся. **Точный следующий шаг:** commit/push подготовки → clean run `parallel-ios-retire-slot-writers-20261110-01` с прежним branch config SHA256 `1bf347cc4848ab4d54844c1b69c69c83ac3ed2db98a348135ced1d5c3f77a561` (UIconfig3f707461 также неизменен). После приёмки — полный аудит T162, конечный fingerprint и SQL/Deno/automation/unit/16UI/Release/Simulator integration gates; только затем решение о checkbox и объединении в main из отдельного чистого checkout. После этого доступная независимая работа T006: текущий workflow выполняет build-for-testing без actual iOS tests/SQL; remote CI не проверялся. B approvals ожидаются в B и не обходятся.

## Экраны каталога: исходники приняты, начинается функциональная UI-проверка

Run `parallel-ios-catalogue-views-20261110-01` — **COMPLETED / Verified and published**, commit **0bb8d21** подтверждён в origin/codex/plants-ios. Изменены `PlantsApp.swift`, `GuestCatalogueView.swift`, `CatalogueSaveView.swift`: EN/PL форма, frozen save/retry, current-owner resume, native presenter/continuation, guarded server card и DEBUG factory launch. Первый ответ Reviewer отклонён валидатором из-за опечатки fingerprint; штатный resume дал корректный ответ. Всего 1 Developer / 2 Reviewer-вызова / 1 QA, бюджеты и routing не менялись.

**Реальные проверки:** diff-check, build/welcome/**179 PlantsTests PASS**, 0 failed/skipped/expected failures, 176 XCTest + 3 SwiftTesting (`q-7298430e19f200183f2d0b11`); **123 automation tests / OK**, 36.934s; Simulator smoke `q-2026b7709258ccf04bbaea32`; изолированная actual Release build + DEBUG source guard + отсутствие fixture markers в бинарнике `q-9bbca9ed2e0417add83e8897` — PASS. High-risk Review/QA проверили весь трёхфайловый кандидат. [Отчёт](validation/automation/tasks/parallel-ios-catalogue-views.md). SQL/Deno/live этим Swift-only пакетом не запускались. Fingerprint принятого runtime/contracts/tools ДО следующего manifest: `e0dcebd104c53d762fcba1d2a9e32ea71ec326ee360fb244bc198a5d0aa5032a`, 1500 tracked files.

**Ограничение приёмки:** это source/build/Release candidate; 16 rendered UI tests ещё не реализованы и не пройдены, пользовательский сценарий целиком не принят. T162/T149/Auth/live остаются открытыми, 14/151 checkbox. Main19e6c83 пока без этих экранов/card/binding; B candidate не включён.

**Следующий пакет:** `tasks.parallel-ios-catalogue-rendered-ui.json`, allowed write: существующий `CatalogueSaveUITests.swift` и необходимые исправления трёх app views. Все 16 точных EN/PL методов, реальный DEBUG SDK/SQLite/server ledger, persistent UUID namespace, native cancel/success restart, same operation и server instance UUID, screenshots keepAlways, no skips. Дополнительно Free/Paid в обоих языках должны повторно выбрать ТОТ ЖЕ вид после первого сохранения: новая форма, Paid — другой server UUID, Free2 после третьего растения — cap. Статический finding контроллера: текущий Choose another очищает только public selection, но оставляет current-owner resumableFlow и может вернуть прежнюю saved-карточку; исправить conditional forgetting указателя при явном новом намерении, сохранив receipt/SQLite/history и frozen pending. Весь view candidate независимо проверяется повторно, не только diff тестов.

**Проверки подготовки нового пакета:** validate VALID(1task), полный context просмотрен, diff-check PASS; оба config SHA256 неизменны. **Точный следующий шаг:** commit/push manifest/handoff/tasks → clean run `parallel-ios-catalogue-rendered-ui-20261110-01` с неизменным собственным UIconfig SHA256 `3f7074612dd1162bde3275d2255c0c8f2223c0f1cc3632a1fe35f6c08b264549`. Требуются 179 unit / 123 automation / 16 actual UI screenshots / Simulator / Release / high-risk Review/QA. После приёмки — remaining slot writers/legacy decode audit T162, затем интеграция только принятого кода между runs. B approvals ожидаются в B; обхода нет.

## Полный UI-run01 timeout без патча; реализация разделена на views → UItests

Run `parallel-ios-catalogue-save-ui-20261110-01` — **WAITING / timeout900s**, Developer1, answer.json не появился. Проверены raw completedtool outputs: ни полного diff/preview, ни реализации нет. Git clean; `CatalogueSaveView.swift`/`CatalogueSaveUITests.swift` остаются imports-only skeletons, targets подготовлены доrun. Build/16UI/Release/ReviewQA новогоUI не выполнялись. Старые manifest/state/logs сохранены, runнеresumeсновымконтрактом. Accepted9b86251/179unit остаётсяпрежним.

**Узкий следующий пакет:** `tasks.parallel-ios-catalogue-views.json`, write только3appfiles Root/GuestCatalogue/SaveView. Реализовать реальные ENPL form/save/pending/cap/native/card и DEBUGrootfactory/currentownerresume над179-testacceptedstack. UIKitwindowpresenter/currentSDKscope/frozenop/durablereceipt обязательны; nativeA→B restart находитьownflowдажебезpublicselectionkeyB. Никаких UItest edits в этом packet. RiskHIGH сохранён, complexitymedium отражаетубраннуюXCTest/harnessчасть; routing/budgets/agenttimeout900 не менялись.

**Приёмка этапа ограничена:** compile/sourceReview/all179unit/123automation/baselineSimulator/actualReleasefixtureexclusion. Это candidate implementation, НЕ доказательство рабочего пользовательского сценария. Следующий отдельный packet напишет16реальныхENPLXCUITests и проверит ВЕСЬ viewcandidate со screenshots, owner/input/restart/receipttruth; доэтого UI/T162/main не выдаютсяготовыми. Старый fullUI manifest/gates сохраняютсякакконтракт последующегопакета.

**Проверки подготовки:** validate VALID(1task), полныйcontext просмотрен, diff-check PASS, старыйtask.patch=0bytes. **Точный следующий шаг:** commit/push узкогоmanifest/handoff→clean run `parallel-ios-catalogue-views-20261110-01` с прежнимnewUIconfig3f707461 (старый1bfbyteidentical). После source/build/Releaseприёмки — actual16UI tests/fullcandidateReviewQA, затем remainingSlotencoders/legacydecodeauditT162.14/151checked, main19e6c83; Bapproval ожидаетсявB, егоCandidate не включён.

## UI binding принят; подготовлены настоящие EN/PL save/card/native UI gates

Run `parallel-ios-catalogue-ui-binding-20261110-04` — **COMPLETED / Verified and published**, **9b86251** отправлен в origin/codex/plants-ios.2Developer/1Reviewer/1QA highrisk; первый tests-onlypatch compileFAIL q-5de14e0d0f47e8c4b477f2b2 (throws/SendableXCTestcapture), второй явноtypedMainActor callback сохранилвсеassertions и прошёл. ВЕСЬ4filecandidate с17d70f8 принят: `PlantsAPIClient.swift` en/plheader setter без authinvalidate; `GuestCatalogueView.swift` exactmodel checkpoint→currentownerUUIDpointer, guest/permanent discovery, conditionalforget/rollback вне locks; `CatalogueSaveModel.swift` validateScope store/API/session/flag/originallease без произвольной closure подlock; `CatalogueConnectionTests.swift`9binding+3actualnotification regressions. Старые167 сохранены. Source/API/model послеnotificationfix readonly, последнийrepair толькоtests.

**Реальные gates:** build/welcome/**179 PlantsTests PASS/0failed/0skips**,176sourceXCTest+3SwiftTesting, `q-d3456029b1fdfb01edd9956b/{summary.json,unit-result.stdout.log,source-test-coverage.json}`. Diff/Simulator `q-dece7b6bad6c012d7e73d840`/highriskReview/QA PASS; [отчёт](validation/automation/tasks/parallel-ios-catalogue-binding-checkpoint-test-repair.md). Все3реальные synchronous UserDefaults.didChangeNotification reentry/invalidate/rollback/forget tests PASS. Commit-before-metadata доказан callback actualprefs с чтением ужеcommittedSQLite; SDK A→B/ABA/same-tokenrefresh/Task/modelcancel на actualcheckpoint ObservationwillSet ДОmetadata, callbackвызывается/metadataCallbacks=0/otherownerunchanged. Убраны blockedModelActor fixturehelpers; boundedMainActorwait≤5s ТОЛЬКО для detachedREALSDKcallback безheldstore/authoritylocks по старомуaccepted SDKtest, не productionкод. Deno/SQL этим Swift-onlyrun не запускались. Это localrealSDK/SQLitefixtures, НЕ renderedUI/live. Oldrun01timeout/02interrupt/03BLOCKED сохранены какнепринятые, подробности ниже.

**Accepted source/contracts/tools fingerprint ДО UIprep:** `595f40a669ff66f9b7d27daee7fc536cf3984e0788557037db8b3c72ee2bac2a`,1493trackedfiles. Main19e6c83 содержит прежнийruntime98b2010/158tests; card17d70f8 иbinding9b86251 пока толькоiOS.

**Подготовлен следующий реальный UI packet:** `tasks.parallel-ios-catalogue-save-ui.json`, write Root/GuestCatalogue/newCatalogueSaveView/newCatalogueSaveUITests. Controller создалimports-only app/UI skeletons, XcodeGen PASS:8pbx additions/0deletions, оба app/UITest Sources ДОevidence. Не реализация/не UI16PASS. Новые собственные controllergates `parallel_ios_catalogue_ui_gate.py` (exact16named ENPL cases/source methods/actualpassed/no skips/no expectedfailures/screenshots, failurexcresultattachments) и `parallel_ios_catalogue_release_gate.py` (изолированныйactualReleasebuild/sourceDEBUGguard/binaryfixturemarkers absent).8negativecontrollerfixturetests в `tests/test_parallel_ios_catalogue_gates.py` PASS; полныйautomation **123tests/OK**,36.258s, exit0 (ожидаемые negative FAIL/timeout не ошибкиsuite). Default/sharedconfig не тронут.

**UIконтракт:** Free2/paid4/precap3/server409/503/lostresponse-restart/nativecancel-restart/nativesuccess-card-restart ×ENPL =16realUIcases. Все179oldunit сохраняются. Sameoperation/body/durableACK/serverUUID из acceptedstack, currentowner formguard, ноль syntheticproductsuccess; metadata/bootstrapcurrentownflow выбирает species дажееслиBпосленативногологинаещёнетpublicselectionpref. Native/locale snapshot обновления неunmount activeintent, старыеprivatefields скрываются. RealUIViewControllerwindow presenter, fakeidentity толькоDEBUGfactory. Root fixturemode не создаётproductionSDK/sourceпередfactory, неfallbacklive; releasebranch/factorycompiledout. Никакого debugHUD/clipboard/поддельныхкнопок. Unitledger доказываетexactHTTP/counters, actualUI — displayedstates/restart/readonlyinput/operation/servercardidentity; отдельноотlive.

**Config:** старый branchconfig `parallel-ios.config.json` остаётсяbyte-identical SHA1bf347cc... дляaudit прежнихruns. Новыйотдельный ignored `parallel-ios-ui.config.json`, SHA256 `3f7074612dd1162bde3275d2255c0c8f2223c0f1cc3632a1fe35f6c08b264549`, добавляет ТОЛЬКО2QAchecks, publishorigin/codex/plants-ios/routing/budgets неизменны. UI/Releasechecktimeout1800, agenttimeout900 unchanged. Validate VALID(1task), полныйcontext просмотрен, diff-check PASS, app/UItest Sources membership подтверждён. **Точный следующий шаг:** зафиксироватьподготовку/handoff/tasks/gates/targets commit/push→clean run `parallel-ios-catalogue-save-ui-20261110-01` с NEWUIconfig; собрать179unit/build, actual16UI/screenshots/Release/Simulator, independenthighriskReviewerQA. Затем убратьоставшиесяFreeSelection/slotwriters+legacydecodeauditT162, толькопослеполнойприёмкирешатьcheckbox. Пока14/151, T162/T149/Auth/live/offline-tokenexpiry/processkillduringownertransition открыты. B4333509/SQL011012 approvals ожидаютсявB, непринятыйкоднеобъединён.

## UI binding run03: реальные notifications проходят; два новых fixture-теста требуют замены барьера

Run `parallel-ios-catalogue-ui-binding-20261110-03` — **BLOCKED / Developer budget3 exhausted**, Review/QA не начинались. Developer1 заменил ложный literal-dottedKVO observer настоящим `UserDefaults.didChangeNotification`/actualdefaults/queue:nil, сохранил Source callback-safe fix. Первый build `q-9d52f26a6b7375bd8bde5c08` FAIL:3 callback closures inferredthrows. Developer2 исправил throwing callback/catch; build/welcome PASS, unit `q-a5a9c6a2eaf1a4883ce567ef` FAIL только нового guest-order теста: syncdiskread во время storegate дождался5stimeout и увиделужеcommittedrow. Все3настоящих notification-регрессии PASS (sync Source/model reread, authority/modelcancel rollback/newerflow, forget), это actualiOS proof, не только Macprobe.

Developer3 создал отдельный off-main ModelContainer того жеSQLite и добавил explicit gateReleased assertion. Build/welcome PASS, но `q-6f1180cc3b59aed9c0b33038` снова FAIL: guest nilrow/gatefalse и SDKrace matrix gatefalse во всех5режимах. Отдельный container не устранил блокировку ModelActor executor; 2 новых testmethods/7assertions fail, полныйнабор179 не принят. Новый assertion правильно выявил, что прежняя matrix могла проходить лишь после таймаута — её не выдаём за рабочую race приёмку. Source/API/Model бизнескод не менялся этими двумя repair, только тестовая синхронизация/Sourcecomment. Старые167 и3notification tests сохранены.

**Новый строго tests-only пакет:** `tasks.parallel-ios-catalogue-binding-checkpoint-test-repair.json`, write ТОЛЬКО `CatalogueConnectionTests.swift`, весь4filecandidate readonly для Review. Убрать blockingModelActor fixture pattern/unused helpers, НЕ увеличить timeout/стереть assertions. Guest: actualnotificationнаpublication доказывает реальныйdiskcommit-before-pointer, затем providercancel/recreate/sameflow/op/body. Matrix: actual model checkpoint Observationpublication послеSQLitecommit/доSourcemetadata, реальныеSDK A→B/ABA/same-tokenrefresh или Task/modelcancel; metadataнепишется/otherownerнепереносится, исходныйowner checkpoint допустимо остаётся, т.к.егоcommitбылДОrevocation. Единственный допустимый test-only boundedwait≤5s — DETACHEDrealSDK callback при MainActor Observation, без heldstore/SQLite/authoritylocks, по уже принятому SDK syncinvalidation test. Никаких productionhooks/fakeevents. Все179/no skips/build/Simulator/fullcandidate highriskReviewQA обязательны.

**Точный итог xcresult:**179total/177passed/2failed/0skips, дополнительно считан controller `get test-results summary`; первая sandboxпопытка не могла создать временный TestReport cache, системный read прошёл. Это не approval rejection. **Проверки подготовки:** validate VALID(1task), полныйcontext просмотрен, diff-check PASS. **Точный следующий шаг:** checkpoint commit/push текущих2modifiedfiles/manifest/handoff→fresh run `parallel-ios-catalogue-ui-binding-20261110-04`, oldrun03неresume/непереписывать, routing/budgets/config1bf347cc неизменны. После actual179PASS/ReviewQA — реальныеENPLviews/16UI/Release. Пока accepted17d70f8/167, main19e6c83/158;14/151checkbox. B approval ожидается, его непроверенныйкод не включён.

## Уточнён реальный callback metadata; no-lock fix восстановлен, tests ещё не приняты

Run `parallel-ios-catalogue-ui-binding-20261110-02` — **WAITING/interrupted**, controller отправил SIGINT только собственному PID90297; child group штатно остановлен/state preserved, exit130. Developer1 успел вывести полный repair preview в stdout item18JSON.patch:17214bytes SHA256 `d7ff4411d68b75e27f74bce37008250c1df34913b56569921b9f761a13e8423f`; controller применил его БЕЗ изменения кода через trusted scope/whitespace validator. Source теперь вызывает UserDefaults вне locks, pre/post actualmodel+SDKvalidation, conditionalownpointerrollback, Model.withScope заменён validateScope. Три новых KVO testcandidate тоже восстановлены, но НЕ запускались/НЕ приняты; ни сборки/179tests/ReviewQA нет.

**Важное уточнение controller:** первый Foundation-probe использовал простой ключ flow и доказал synchronous KVO, но production metadata key содержит dots. Дополнительный реальный probe `addObserver(forKeyPath:actualDottedKey)` дал callbacks=0 — literal dotted-key KVO не подтверждает путь Source. Зато ACTUAL `NotificationCenter`/`UserDefaults.didChangeNotification` на ТОМ ЖЕ dotted owner key с object:actualdefaults/queue:nil выдал `DEFAULTS_NOTIFICATION main=true lockHeld=true` ДО `SET_RETURNED`. Следовательно callback reentry/deadlock под старым lock остаётся реальным, а правильный iOS regression должен использовать didChangeNotification, не неработающий dotted KVO. Уточнение не скрыто/не выдано за KVO приёмку. Raw sources/stdout/stderr дополнены в ignored `validation/automation/runs/parallel-ios-kvo-probe-20261110-01/{dotted-kvo-*,notification-*}`; временные случайные suites удалены probes.

**Новый exact-test packet:** `tasks.parallel-ios-catalogue-binding-notification-repair.json`, allowed Source/Model/ConnectionTests. Адаптировать recovered3tests/observer к настоящему synchronous didChangeNotification на actualinjecteddefaults; никаких fake notifications/getters/ключевых схем или manualKVObridges. Сохранить assertions фактического originalmodel/disk/SDK reentry/invalidate/rollback/newerflow/otherowner/forget и все9binding+167old. Минимум179actual/no skips/build/Simulator/highrisk Reviewer/QA на ВСЁМ4filecandidate, APIsetter readonly. Sourcefix уже восстановлен, он не должен возвращать callbacks под locks.

**Проверки подготовки:** validate VALID(1task), полныйcontext просмотрен, diff-check PASS. **Точный следующий шаг:** checkpoint commit/push изменений/handoff/manifest→fresh run `parallel-ios-catalogue-ui-binding-20261110-03` с прежнимconfig1bf347cc. Предыдущие01/02 run не resume, не переписывать. После принятия — actualENPL UI16cases/Release exclusion с новым отдельным branch-only UIconfig, старый config останется неизменным для auditable runs. Main19e6c83, принятая база17d70f8/167tests;14/151. B approval по-прежнему ожидается, её код не включён.

## UI binding candidate восстановлен; обнаружен synchronous UserDefaults KVO deadlock

Run `parallel-ios-catalogue-ui-binding-20261110-01` — **WAITING / timeout900s**, Developer1, answer.json не появился. CLI readonly sandbox filesystem warning сохранён (это не automatic approval rejection). Controller намеревался остановить run после finding ниже, но процесс уже завершился сам: psfound[], SIGINT никому НЕ отправлен. Последние raw diffs immutable stdout item18/model,19/API,20/Connection,22/tests соединены БЕЗ изменений:33161bytes SHA256 `2ee981d59517b5458343843dd5c452f7a6b7431da0740835d8950566018229d1`, trusted scope/apply/whitespace/diff PASS. Первая safetyassert заметила новый item22 до любых изменений, затем выбран последний testdiff (Developer добавил required APIbaseURL), не старыйitem21. История/логи/state не переписаны.

**Непринятый candidate:** `PlantsAPIClient.swift`+11 locale setter без authinvalidate; `GuestCatalogueView.swift`66строк metadata currentowner remember/forget/guestdiscovery; `CatalogueSaveModel.swift`17строк exactwithScope; `CatalogueConnectionTests.swift`469строк/9новыхтестов. Всего548add/15del, 167old+9=176actual ещё НЕ запускались; build/ReviewQA/Simulator этого кандидата нет. Acceptedcard17d70f8/167tests и main19e6c83/158tests отдельно.

**Реальный controller finding:** metadata set/remove выполняются ВНУТРИ sdkEpoch NSLock, remember также model.withScope/authority NSLock. Локальный Foundation KVOprobe с isolatedrandom UserDefaults suite напечатал `KVO_CALLBACK insideSet=true main=true lockHeld=true`, `SET_RETURNED callbacks=1`: callback синхронный, чтение Source SDKepoch/model.state или invalidate SAMEauthority повторно захватит lock и зависнет. Probe использовал tryLock, не намеренный hang; Swift запущен с системным разрешением, источник/реально captured stdout/stderr в ignored `validation/automation/runs/parallel-ios-kvo-probe-20261110-01/`. Первичный вывод наблюдался toolstdout, повтор выполнен только для raw evidence capture. Это Foundation APIprobe, не actualmodel/iOS regression.

**Новый bounded repair:** `tasks.parallel-ios-catalogue-binding-kvo-repair.json`, write только Source/SaveModel/ConnectionTests, APIsetter readonly. Никаких UserDefaults set/remove/rollback/registered callbacks под SDKepoch/authority locks; scopevalidation без произвольной closure, pre/post expectedSDK+originallease checks, conditionalrollback только собственногопointer еслиегоещёнезаменили. Не recursive lock/новая persistence/SDKподмена. Все9candidate и167old+>=3actual KVO model/source reentry/invalidate/remove regressions=>минимум179actual/no skips/build/Simulator/highriskReviewQA на ПОЛНОМ candidate, не только repairdiff.

**Проверки подготовки:** validate VALID(1task), полныйcontext просмотрен, diff-check PASS. **Точный следующий шаг:** checkpoint commit/push кандидата/handoff/manifest → fresh run `parallel-ios-catalogue-ui-binding-20261110-02` с прежнимbranchconfig1bf347cc. Старый run не resume/не выдаватьзаготовый. Затем actualENPLUI16cases/Release exclusion; ихcontrollerdrafts в /tmp прошли8negativefixtureprobes, не продуктовую/UIприёмку. Родители14/151 и live/Auth/T162/T149 открыты; B4333509/SQL011012 permissions ожидаются вB, не обходить. Main19e6c83.

## Guarded server card readback принят; подготовлены UI binding helpers

Run `parallel-ios-catalogue-card-readback-20261110-01` — **COMPLETED / Verified and published**, **17d70f8** отправлен в origin/codex/plants-ios.1Developer/1Reviewer/1QA high-risk, без повторов. `CollectionRepository.swift`+56строк: exactdurablejournal/owner/op/payload/receipt → SAMEoriginallease fullrefresh existingengine без drain → actual SQLite plants entityUUID=data.id=receipt.plantId, minimalcanonical summary. `CatalogueSaveModel.swift`+61: guardedcardState/summary, loadCard/retry/busy, Observablepublication вне lock, durable savedstate отделён от GETdetails failure. Explicitfacade/caller cancellation redacts model, durable receipt остаётся для ownrestore; transportcancel/missing/malformed/readOnly details не создают повторного plant. Никакого fake care/plan из receipt.

**Реальные checks:** build/welcome/**167 PlantsTests PASS/0failed/0skips**,164sourceXCTest+3SwiftTesting (158old+9new), `q-f021edb7012812e096d2c73b/{summary.json,unit-result.stdout.log,source-test-coverage.json}`. Deno336PASS (scope из read-onlySQL), diff-check/Simulator `q-1a20dadd37c165f8278e7b8c`/highriskReview/QA PASS; [отчёт](validation/automation/tasks/parallel-ios-catalogue-card-readback.md). Actual model→repository/API/engine/SQLite: canonical identity/name/species/revisions, failedGET+retry/no create, missing/deleted/malformed, actual diskrestart/receipt, readOnlypublication/checkpoint, A/B/ABA/logout/cancel during suspendedGET, duplicate load1refresh, synchronous Observation reread+invalidate onloading/loaded. SQL не запускался этим Swift packet; live/Auth/renderedUI/caregeneration не принимались. Main19e6c83 пока включает прежний runtime98b2010/158tests; новый cardhelper толькоiOS.

**Следующий узкий пакет:** `tasks.parallel-ios-catalogue-ui-binding.json`,4existing files Connection/SaveModel/APIClient/ConnectionTests, targets не менять. Исправить guest/permanent ownflow discovery после restart: explicit actualmodel checkpoint/replay → только UUID metadata under SAMEstore/API/session/anonymousflag/originallease/currentSDK; before/afterawait validation, no authobserver calls/copies. Guest pointer читается currentowner, explicitconditionalforget только matchingflow, без удаления SQLite/outbox/receipt. Current `resumableFlow` ещё permanent-only, поэтому guestcancelrestart черезэкран пока не принят. Второй статический gap: API X-Client-Locale всегдаpl; маленький en/pl setter меняет только header, НЕupdateContext/authlease/token/operation, invalidlocale no mutation. >=173actualtests (167old+>=6), high-riskReviewQA.

Accepted card runtime/contracts/tools fingerprint ДО bindingprep: `892676f12f2107a867cee19310af09503448feecab04cf2087956af16005bfdb`,1489trackedfiles. **Проверки подготовки:** validate VALID(1task), полныйcontext просмотрен, diff-check PASS; build/173tests ещё не запускались. **Точный следующий шаг:** сохранить handoff/tasks/manifest commit/push→clean run `parallel-ios-catalogue-ui-binding-20261110-01` с прежнимbranchconfig1bf347cc. Затем actualENPLCatalogueSaveView/rootDEBUGfixture wiring/16XCUITests/Releasefixture exclusion; drafts пока /tmp, не runtime/evidence. Все14/151 checkbox неизменны; T162/T149/Auth/live/token-expiryoffline/processkillduringnativeownertransition открыты. B4333509/SQL011012 approvals ожидаются вB, не обходить.

## Подготовлен guarded server card readback

main публикация подтверждена7502bee; docs-only подтверждение**19e6c83** также отправлено в origin/main и iOS. Runtime/contracts/tools fingerprintf7cdd858/1488files неизменен; исходный main checkout и B не менялись. После итоговых gates менялись только документы.

Новый `tools/automation/tasks.parallel-ios-catalogue-card-readback.json`: write только existing `CollectionRepository.swift`, `CatalogueSaveModel.swift`, `CatalogueSaveModelTests.swift`, новые targets не требуются. Под durable saved receipt и ORIGINAL bound lease — canonical full refresh тем же engine без outbox drain, точный owner/serverUUID/entity.id/data.id, минимальные реальные species/name/revisions. Guarded observable card state не выдаёт данные старой сессии после A/B/ABA/cancel; Observation callbacks вне authority lock. Ошибка/отмена/missing details не превращает уже подтверждённое сохранение в pending и не создаёт новый plant; отдельный details retry. Никаких care-success/планов из receipt/input, только фактический canonical row.

**Требуемая приёмка:** сохранить все158old+>=5meaningful actualmodel/repository/API/engine/SQLite tests=>минимум163/no skips/build/Simulator, high-risk независимые Reviewer/QA; before/after authrace, restart, missing/error/retry, duplicate read и synchronous observer regression. Read-only active SQL004 projection прилагается, B не правится. Views/root wiring, guest cancel+restart metadata и EN/PL HTTP locale header остаются следующим UI-пакетом; fixture code не меняется.

**Подготовительные проверки:** validate VALID(1task), полный context просмотрен, diff-check PASS; build/163tests/приёмка ещё не запускались. **Точный следующий шаг:** validate/context→commit/push manifest/handoff→clean run `parallel-ios-catalogue-card-readback-20261110-01` с прежним branch-only config1bf347cc. После helper — реальные EN/PL catalogue save/card/native views,16 UI cases и isolated Release fixture exclusion. Два gate drafts и их count/source negative probes в /tmp — не продуктовые UI/Release результаты. Родители14/151/T162/T149/Auth/live открыты; B011/012 approval ожидается в B, не обходить.

## iOS integration опубликована в main — 10 ноября

**Публикация подтверждена:** из отдельного чистого `/private/tmp/narat-ios-integration-20261109-01` выполнен fast-forward72bcccc→**7502beec57c3bc003f2e7924c3f4a2bf2b2346ed**, fingerprint `f7cdd858b21a4e4926b40ff7c9aa65878ba035bf4e224191f0e6daf56ca4807c`/1488files совпал с проверенным source. Обычный `git push origin HEAD:main` exit0: `72bcccc..7502bee HEAD -> main`. origin/codex/plants-ios также на7502bee; исходный main checkout и B worktree не менялись. Включены только принятые iOS engine→repository/input/model/SDK/native/DEBUGfixture и прежняя B005–007 история; SQL008–012/непринятый B4333509 не включены.

Финальные SQL/Deno/115automation/158Swift/build/welcome/Simulator PASS перечислены ниже, source после них неизменен. Эта запись публикации — только docs и сохраняется отдельным commit/push обеих веток. Live/backend deploy/rendered save UI/Release/Auth completion не объявлены; tasks14/151. **Далее:** подготовить узкий existing-file model/repository card-readback packet (original bound lease, canonical server UUID/data, guarded access, saved остаётся saved при ошибке details), затем EN/PL views/16XCUITests/Release exclusion. B workflow approvals ожидаются в B и не обходятся.

## Повторные интеграционные проверки iOS-пакетов — 10 ноября

Проверен конечный принятый код `1d88434` (runtime98b2010), объединяющий ранее принятые engine ACK22bc1a6 → capacity/outbox/journal/repository/input/model/SDK/native0a9f2ea → DEBUGfixture98b2010. `git fetch origin` подтвердил main=`72bcccc`, он уже ancestor iOS; `HEAD..origin/main` пуст. Diff к main по `supabase`, `.github`, KB/catalogue/contracts пуст: новых B SQL008–012/непринятых данных нет. История B005–007 из прежнего merge сохранена. Рабочее дерево чистое, модели оркестратора не активны.

**Реальные gates на этом же источнике — PASS:**
- `parallel_backend_quota_gate.py --accounting --legacy-guard --cap-regression`: clean и seeded-upgrade — по55anchor+49ledger+131cap/care pgTAP, по12 boundary/leap/timezone случаев;4 реальных owner-lock retry/distinct-create гонки, по одному plant/receipt, все preexisting public rows byte-equal. Это private PG17 fixtures; старый shared `t161 --slots` equality runner не заявляется пройденным.
- Deno**336 PASS/0failed**, deno-check exit0; automation**115 tests/OK**,40.558s. Ожидаемые negative-fixture сообщения FAIL/timeout в stdout не являются ошибкой suites (exit0/OK).
- Xcode build/welcome/**158 PlantsTests PASS/0failed/0skipped**,155sourceXCTest+3SwiftTesting; `parallel-integration-ios-20261110-01/{summary.json,unit-result.stdout.log,source-test-coverage.json}`. Simulator `parallel-integration-sim-20261110-01` welcome/care-navigation PASS.

Логи `validation/automation/runs/parallel-integration-20261110-01/{sql,deno-tests,deno-check,automation,ios,simulator}.log`. Runtime/contracts/tools SHA256 **f7cdd858b21a4e4926b40ff7c9aa65878ba035bf4e224191f0e6daf56ca4807c**,1488tracked files, before/after совпали. Source при проверках не изменён; далее меняются только handoff/tasks docs. Это local/fixture integration, не backend deploy, live providers/StoreKit, rendered catalogue save UI или полный T162/T149/Auth. Tasks14checked/137open неизменны.

**Точный следующий шаг:** сохранить эту проверенную сводку commit/push iOS → отдельный чистый integration checkout fast-forward на этот commit, сверить тот же fingerprint → обычный `git push origin HEAD:main`, без force; зафиксировать результат публикации. Затем узкий guarded server-instance card readback на исходном model lease, после него реальные EN/PL views/16XCUITests/Release fixture exclusion. B permissions ожидаются в её чате; её HEAD4333509 не включён.

## DEBUG catalogue UI fixture принят; интеграция iOS в main

Run `parallel-ios-catalogue-ui-fixtures-20261110-02` — **COMPLETED / Verified and published**, **98b2010** отправлен в origin/codex/plants-ios; checkpointe4d3aa8 опубликован. 1Developer/1Reviewer/1QA, canonical repair без дополнительных попыток. Принят ВЕСЬ DEBUG-кандидат, а не только delta: `CatalogueUIFixtures.swift` и `CatalogueUIFixtureTests.swift`. Explicit namespace UUID factory, isolated actual SDK/custom URLSession/URLProtocol/scoped fake-session storage, existing connection/native exchange/model/repository/engine/SQLite. Durable mock server ledger сохраняет точное body/operation/receipt/server UUID/inventory до lost response; replay после recreate при cap3 возвращает одну квитанцию без второго insert. Unknown URLs блокируются. Никаких app root/view launch branches ещё нет.

**Реальные checks:** build/welcome/**158 PlantsTests PASS, 0 failed/0 skipped**,155 sourceXCTest+3SwiftTesting (150old+8new); unit `q-6f816ce784b653cfee85a6e9/{summary.json,unit-result.stdout.log,source-test-coverage.json}`. Deno**336 PASS/0failed** (автоматический scopecheck из read-only SQL paths), diff-check/Simulator `q-742b4f4532d417f9747f60d4`/независимые Review/QA PASS; [отчёт](validation/automation/tasks/parallel-ios-catalogue-fixture-recovery.md). SQL не запускался этим run; SQL002/004 только читались. Проверены Free2→save/readback/exactreplay, paid4→fifth, precap3/zeroPOST, precheck2/server409/503, lostresponse/recreate/cap3/exactretry/durableACK, nativecancel/success+checkpointbeforeprovider/no guestqueue transfer, namespace isolation/persistent anonymousSDK/RPC ENPL/refresh/logout/unknownURL rejection. Fixture sync и receipt приведены к active SQL: display_name=canonicalpersonal_name, нет care_enabled, current/view_plant/care_profile_unavailable/null paid_action без выдуманного ухода. Payload/input bytes при этом сохраняются исходными; сервер применяет SQL trim/namefallback.

**Ограничения:** это local fixture/disk/Simulator, не rendered save UI, live Auth/SQL/AI/StoreKit и не Release acceptance. App definitions закрыты `#if DEBUG`, Release build проверяется будущим отдельным gate при UI wiring. Исходный fixture run01 BLOCKED по двум header-space apply errors сохраняется, recovery выше не скрыт. Guest flow discovery/cancel+restart через экран, token-expiry offline чтение и kill во время native owner transition ещё не проверены; родители14/151/T162/T149 открыты.

**Финальный исходный fingerprint до интеграции:** `f7cdd858b21a4e4926b40ff7c9aa65878ba035bf4e224191f0e6daf56ca4807c`,1488tracked runtime/contracts/tools files. Orchestrator завершён, source clean; fetch origin выполнен. Следующий шаг: зафиксировать этот handoff/tasks commit/push → сверить main ancestry/включить только origin/main при необходимости → повторить SQL anchors+ledger+legacyguard+cap regression, Deno/typecheck/115automation, Swift158/build/welcome/Simulator на конечном fingerprint → обычный main push из отдельного чистого `/private/tmp/narat-ios-integration-20261109-01`. Исходный main checkout и активный B worktree не менять. B011/012 approval по-прежнему ожидаются, её непроверенный HEAD4333509 не объединять. После main публикации — guarded server card readback, затем реальные EN/PL views/16 XCUITests/Release fixture exclusion. Scratch drafts/gate probes в /tmp не объявлены реализованными проверками продукта.

## DEBUG fixture candidate: diff header восстановлен; canonical repair и приёмка впереди

Run `parallel-ios-catalogue-ui-fixtures-20261110-01` — **BLOCKED / no progress** после2 Developer apply failures: один leading SPACE перед вторым diff header оба раза. Runtime до восстановления не менялся, проверки не запускались. Controller взял полный call2 patch42050bytes SHA256 `90d4518395e76fe7fb6878d57c4ec250cd3715761b7bc9dcb54399d7d842daf6`, убрал ТОЛЬКО один header SPACE, added-code lines идентичны; normalized SHA `5e1feac48ae36880a6d8eda2aa813ce10003a8e776462026cff2352eef8f2012`. Trusted scope/whitespace/apply и diff-check PASS. Исходные ответы/state/logs не изменены. Call2 самостоятельно исправил test enqueue return `.operationId`; controller код не редактировал.

**Непринятые файлы:** `CatalogueUIFixtures.swift`495added — DEBUG factory, scoped actual SDK storage/SQLite/URLProtocol, persistent server ledger; `CatalogueUIFixtureTests.swift`270added/8tests. Новый manifest `tasks.parallel-ios-catalogue-fixture-recovery.json` сохраняет allowedwrite2files/routing/budgets; fullcandidate Review/QA, all150old+8candidate=158actual/no skips/build/Simulator. Сборки/158PASS ещё нет.

**Выявлено controller статически:** GETsync data содержит выдуманный `care_enabled:false`, а display_name=Fern вместо SQL personal_name; receipt complete_conditions/none надо сверить с actual catalogue SQL. Repair должен привести fixture к read-only SQL002/004, усилить assertions и исправить необходимые compile defects, без новых views/продуктовой логики. Это отдельно от прежнего header-only recovery; исправление кода поручается Developer нового run.

**Точный следующий шаг:** validate/context/diff → checkpoint commit/push кандидата, handoff и manifest → fresh run `parallel-ios-catalogue-ui-fixtures-20261110-02`, тот же branch config1bf347cc. После приёмки — между runs объединить принятый iOS runtime в main с проверками конечного fingerprint; затем guarded card readback и EN/PL views/16 UI cases/Release exclusion. Parent14/151, live/Auth/T162/T149 открыты; B011/012 permissions ожидаются в B, не объединять её непринятые файлы. Native0a9f2ea/150actual отдельно принят.

## Native catalogue continuation принят; подготовка DEBUG UI fixture

Run `parallel-ios-catalogue-native-auth-20261110-02` — **COMPLETED / Verified and published**, **0a9f2ea** отправлен в origin/codex/plants-ios, восстановленный checkpoint78e4d81 также опубликован. 1Developer/1Reviewer/1QA high-risk, без исправлений исходного восстановленного diff. ВЕСЬ кандидат с68d3e46 принят: реальный local checkpoint/replay до credentials, SAME SDK/NativeAuthService/SupabaseAuthExchange, before-exchange epoch validation, intended signedIn-only continuation из выбранного ввода, immutable new-owner model/cache, без переноса чужих/guest очередей и receipts. Cancel после committed exchange сохраняет SDK truth и локальный new-owner ввод, не отправляет create до явного retry; native busy и owner-scoped flow UUID pointer. Default API/trailing closures сохранены.

**Реальные checks:** build/welcome/**150 PlantsTests PASS, 0 failed/0 skipped**: 147 source XCTest methods +3 SwiftTesting, все137 прежних+13 новых. Unit `q-6098ed2bcc0fe913f7784cbe/{summary.json,unit-result.stdout.log,source-test-coverage.json}`. Diff/Simulator smoke `q-cd2a18b38ac9d3a616417efe`/high-risk Reviewer/QA PASS; [отчёт](validation/automation/tasks/parallel-ios-catalogue-native-recovery.md). Fake identity provider, но actual pinned SDK/exchange/URLProtocol/real SQLite: checkpoint before provider/cancel, readonly preparation/provider0, cached-checkpoint replay, actual native success and sameUUID generation, provider/exchange failures/invalidSDK, provider/exchange owner/ABA races, committed exchange/caller cancel+explicitretry, withdrawn intent/busy/foreignop/server409. Не live Apple/Google/Auth, не rendered catalogue save UI; process kill во время owner transition и offline read-only после token expiry не проверены. Deno/SQL этим Swift-only run не запускались. Fingerprint ДО следующего target prep: `a254f61c4e7166e91dc940ee85dfa58faf23f660ef8c64b4c474cdee09625434`,1484tracked files. Старый native run01 WAITING timeout сохранён.

**Следующий ограниченный пакет:** `tasks.parallel-ios-catalogue-ui-fixtures.json`: explicit DEBUG-only factory, один actual Supabase SDK+real connection/model/repository/engine/namespace SQLite, fake identity и scoped fake SDK storage, ни live URLs/keys/keychain. Durable mock server ledger записывает exact operation/body/receipt/inventory ДО потери ответа; recreation сохраняет тот же server UUID/одну квитанцию, pending retry bypass new cap. Free/paid/precap/server409/503/lostresponse/nativecancel/success, canonical sync/readback; >=156actualtests (150old+>=6), Review/QA. Только factory+unit tests, никакого root/view wiring в этом пакете. Controller создал imports-only app/unit skeletons `CatalogueUIFixtures.swift`/`CatalogueUIFixtureTests.swift` и включает их XcodeGen в Sources ДО evidence. Реализации/156PASS ещё нет.

**Проверки подготовки:** XcodeGen PASS, pbxproj ровно8 additions/0deletions, оба app/unit Sources подтверждены; validate VALID(1task), полный context просмотрен, diff-check PASS. **Точный следующий шаг:** сохранить handoff/tasks/manifest/targetprep commit/push; clean run `parallel-ios-catalogue-ui-fixtures-20261110-01`, прежний branch config1bf347cc. Затем guarded server card readback и реальные EN/PL views/16UI cases/Release fixture exclusion. Guest flow metadata discovery для cancel+restart ещё требует UI-среза; текущая SQLite строка сохраняется, explicit flow restore работает. Parent checkbox14/151, native/provider live/fullAuth/T162/T149 открыты. B011/012 workflow approval всё ещё ожидается в B; непринятый HEAD4333509 не объединялся. Main72bcccc.

## Native candidate восстановлен после CLI timeout; приёмки ещё нет

Run `parallel-ios-catalogue-native-auth-20261110-01` — **WAITING**, Developer1 timeout900s до answer.json. Полный diff уже находился в неизменённом stdout item_24; controller применил его БЕЗ изменений через trusted scope/whitespace validator: 46699 bytes, SHA256 `31745e6581afb7b6875b9ba670b4c62995d33d144d3f5c182714d74a9fd37bbf`. Четыре файла: `GuestCatalogueView.swift`, `CatalogueSaveModel.swift`, `NativeAuthService.swift`, `CatalogueConnectionTests.swift`, 695 additions/25 deletions. Кандидат содержит checkpoint-before-provider, same-SDK exchange guard, explicit selected-input continuation/new-owner checkpoint, cancellation-after-commit без auto-create, owner-scoped flow pointer и 13 native fixture tests. Код НЕ принят, старая проверенная база — 68d3e46/137tests.

**Реально выполнено:** trusted apply scope/whitespace PASS, diff-check/manifest validate и context — подготовительные проверки. Сборка/150tests/Review/QA восстановленного кандидата ещё не выполнялись. Исходный run/logs/state не переписывались. Новых live Apple/Google/Auth или rendered UI проверок нет; родительские checkbox 14/151 неизменны.

**Следующий шаг:** checkpoint commit/push кандидата, handoff и `tasks.parallel-ios-catalogue-native-recovery.json`; fresh run `parallel-ios-catalogue-native-auth-20261110-02`, тот же branch-only config1bf347cc и бюджеты. Разрешён только необходимый compile/correctness repair четырёх файлов; все 150 tests и полный candidate с 68d3e46 проверяют независимые high-risk Reviewer/QA. После принятия — DEBUG-only persistent UI fixture, затем реальные EN/PL views/XCUITest/Release exclusion. Guest restart discovery пока не реализован, сохранённая строка восстанавливается по explicit flow; UI metadata отдельно. B разрешения ожидаются в её чате, непринятые SQL011/012 не объединяются. Main72bcccc.

## SDK session/source model factory принят; далее native provider continuation

Run `parallel-ios-catalogue-sdk-session-20261110-02` — **COMPLETED / Verified and published**, **68d3e46** отправлен в origin/codex/plants-ios; checkpoint7b05c1d опубликован.1Developer/1Reviewer/1QA highrisk. Весь SDKcandidate принят после monotonic historyfix: seedизSDKдоobserver, синхронныеcallbacksфиксируютлюбойnonnilSDKsession (anonymous/permanent/expired), signedOut/nil/error историюнеочищают; automaticguestsignup толькоtrulynever-sessionconnection, наrefreshcleanup/retry ownerнеподменяется. CurrentvalidSDK recovery работает; explicitAccountReset/coldRecoveryUI — отдельный будущийscope, resetflagsнепридумывались. Один SDKclient+existingstore/api/engine/repo, sharedanonymousstartup, rawSDKsyncinvalidation/epoch и serializedcurrentbinding, actualisAnonymous/token/expiry, guardedmake/ownflowrestore безsend/newIDs. OldSourceModelнеперепривязываетAPIстарымtoken.

**Реальные checks:** build/welcome/**137 PlantsTests PASS/0failed/0skips**,134sourceXCTest+3SwiftTesting; all124old+13SDKfixture tests. Unit `q-3089294c03dd7ac9de7dfd43/{summary.json,source-test-coverage.json,unit-result.stdout.log}`. Diff/Simulator smoke/highrisk Reviewer/QA PASS; [отчёт](validation/automation/tasks/parallel-ios-catalogue-sdk-auth-history-repair.md). Новый realSDK regression покрывает8вариантов двухcleanupкодов/anonymous-permanent/до-во-firstsessionOwner +retries≥2, никакихsignup/измененийSQLite; productioninitialsession regression сохранён. SameactualSDK+URLProtocol/isolatedAuthStorage/realSQLite, не liveAuth/provider UI. Тестсинхроннойинвалидации специальноограниченно блокируетMainActor semaphore≤5s, SDKsignOut идётdetached — asyncobserverнеуспевает, guardedmodelужеredacted; productionникакихblockingwaits. Deno/SQLэтим Swift-only run не запускались. Runtime/contracts/tools fingerprint передnativeprep `34cc5bd284b3e54a4c3075513d0b8c6897f5408e41d69f7f01dd48a715fd4eb7`,1482trackedfiles. Старый SDKrun01 BLOCKEDи135/136 PASSсreviewFAIL сохранены, не выданызаacceptance.

**Следующий bounded native packet:** `tasks.parallel-ios-catalogue-native-auth.json`,4existingfiles Connection/SaveModel/NativeAuthService/ConnectionTests, targetprepне требуется. Realconfiguration.makeService(client:SAMEclient); fakeIDENTITYprovider толькоtests сREALSupabaseAuthExchange. Actualimmutablecheckpoint/replay вprepare closure ДОcredentials; optionaldefault-preserving beforeExchangecontextvalidation (параметрДОпоследнегоrequiredprepare, чтобыстарыеtrailingclosuresнеизменились). Послеexchange толькоactualSDKpermanent/exactresult.session/intendedflow/expectedSDKevents; unrelatedaccountchange abort, genericobserverничегонепереносит. Explicitchoseninput→newownermodel sameflow/op/payload, ни guestqueue/receipt/photo claims. Cancelaftercommittedexchange сохраняетSDKtruth+localinput, НЕautoCreate; metadataowner+flowUUIDpointer UserDefaults толькобезpayload/credentials допустимдляUIresume, payloadSQLite. >=143actualtests(137+>=6), highriskReviewQA. Nativeview/liveAppleGoogle/Auth не объявляютсяготовыми fixture-тестами.

**Ограничения/следующий шаг:** validate/context/diff→commit/push handoff/taskpartial/manifest→clean run `parallel-ios-catalogue-native-auth-20261110-01` с прежним branchconfig1bf347cc. Послеnativehelper — DEBUG-only UIfixture(s) и реальныеEN/PL save/cap/error/login-cancel/success/restart/cardXCUITests. Tokenexpiry offline read-only/cache-recovery и процессkillвмоментSDKownertransition — отдельные непроверенныегейты; actionmodelтребуетвалиднуюSDKсессию, fullT023/T025/T046/T049/Auth/T149/T162не100%. Main72bcccc;14/151. B011/012model/publish/messagingapproval по-прежнемуожидаютответавB, Aэто не обходит и Bcandidatesнеобъединяет.

## SDK candidate: initial refresh исправлен; persistent auth history ещё требует repair

Подготовка6542f37 опубликована. Run `parallel-ios-catalogue-sdk-session-20261110-01` — **BLOCKED / retrybudget exhausted**,3Developer/2Reviewer, QA не начиналась. Непринятый candidate: GuestCatalogueView.swift287строкдиффа (один actualSDKclient+existingresources, eventepoch/synchronousAPIinvalidation, serializedcurrentbinding, sharedanonymousstartup, guardedSDKsnapshot/model factory/ownrestore), CatalogueConnectionTests.swift655строк12candidate realSDK+URLProtocol/isolatedAuthStorage/SQLite scenarios. Existingviewrenderingнеизменён, nativeproviderещёнет. Targets testSources подготовлены заранее4строкиpbx.

**Реальные попытки:** build1 `q-bcee0abb39c1a4043aaf61bf` FAIL test `api.baseURL` actorisolated; Developer2 добавил await вtest, build/welcome/**135actualtests PASS/0skips** (`q-7ee06e51f607656d5aa3c2ae`). Reviewer1 FAIL/P1: defaultproductioninitialobserver refresh может удалитьсохранённуюсессию+поглотитьошибку, затем Rootсоздастдругогоanonymousowner. Developer3 сохранил hadSessionBeforeObservation доobserver и добавил realSDK production-order test для обоих cleanupкодов/моментовстарта. Build/welcome/**136actualtests PASS/0skips** (`q-b9d61f9303b8ac5c1cd0404f`), diffchecks PASS; Reviewer2 подтвердил этотfix, но FAIL/P1 повторныйruntimeслучай ниже. Это не принятый SDK/не SimulatorQA; старые124 accepted8ba18e1 отдельно.

**Оставшийся точный finding:** если SDKизначально пуст, ownerпоявилсяпозднее, terminalrefresh `refresh_token_not_found`/`session_expired` удалилsession, firstsessionOwnerотказал, RETRY уже видит исходный false/текущийnil/новыйстабильныйepoch и вызываетsignInAnonymously. Нужен monotonic connection-lifetime факт previously-established session, seeded доobserverизrealSDK и обновляемыйсинхроннымSDKcallback (anonymous/permanent), не терятьприnil/signout/error. Это metadata/Auth recovery guard, не новыеquota/ownerdefaults/AccountUI. СуществующийвалидныйSDKsignin по-прежнемуработает, свежийnever-sessionstartup по-прежнемуодинsignup.

**Новый bounded packet:** `tasks.parallel-ios-catalogue-sdk-recovery.json`, write только existingConnectionfile+егоtest, review ВЕСЬ candidate, minimum137actualtests (136previous+>=1realSDK runtime cleanup/repeatedcalls); обаcleanupкода, сессияпослеsourceinit, cleanupдо/впервомвызове, >=2retries, ZEROsignup/plantcommands/data mutation. Ни manual fake observer, ни weakeningtests. Validate/context/diff → checkpoint commit/push непринятогокода/handoff/manifest → fresh run `parallel-ios-catalogue-sdk-session-20261110-02` с прежним config1bf347cc. Oldrun/limitsнепереписывать. SDK/native/views/live/fullT162/T149 open,14/151; main72bcccc; BworkflowразрешенияожидаютсявB, candidatesнеобъединялись.

## Owner-fixed UI model принят; подготовлен SDK session пакет

Run `parallel-ios-catalogue-save-model-20261110-02` — **COMPLETED / Verified and published**, **8ba18e1** отправлен в origin/codex/plants-ios; recovered checkpoint9c159e6 опубликован.1Developer/1Reviewer/1QA highrisk, без новыхrepairs. Приёмка ВЕГО modelcandidate (Repository contextualhelper10строк/новаямодель/новыетесты), а не только observerdelta. Model исходнаяSDKsession/owner/lease immutable, APIнеперепривязываетстарымтокеном; guarded state/input/envelope/checkpoint redaction после A/B/ABA/refresh/logout/cancel; actual localcheckpoint→registeredrepositorysave и sameownerflowrestore безrequests/UUIDregen. Observe publication теперь validate→mutation БЕЗauthoritylock→validate, три настоящих modelрегрессии synchronouscallback reread+invalidate на busy/checkpoint/saved-or-pending, journal/disk сохранены.

**Реальные checks:** build/welcome PASS; **124 PlantsTests PASS/0failed/0skips**,121sourceXCTest+3SwiftTesting (109old+12originalcandidate+3observerregression). Unit `q-4e2b344947d7549c08bf6290/{summary.json,source-test-coverage.json,unit-result.stdout.log}`; diff-check/Simulator smoke/highrisk Reviewer/QA PASS, [отчёт](validation/automation/tasks/parallel-ios-catalogue-model-observation-repair.md). Mocktransport/realSQLite/localSimulator, не renderedUI/nativeprovider/live. Deno/SQLэтим Swift-only run не запускались. Accepted8ba runtime/contracts/tools fingerprint **30180a8a0e04d18dd1bf2c724d2e6ed4c3818813822312c6bcf261acdfce49c5**,1479trackedfiles: после XcodeGen prep ниже пересчитан с pbxproj изHEAD8ba (gitstatus подтверждает единственныйtrackedchange pbxproj). Prep-tree fingerprint221bc073648c49fbd84ba0220a17b3d5b15b383e1d02584e415c04e1aa2cb5ca — это ДРУГОЙ, ещё непроверенный targetsnapshot, не evidence принятогоruntime.

**Следующий маленький SDK session packet:** `tasks.parallel-ios-catalogue-sdk-session.json`. Existing CatalogueConnection: один actualSupabaseClient+localstore/api/engine/repo, realSDKowner/token/expiry/isAnonymous, sharedpendinganonymousstartup, rawSDKevent synchronousauthorityinvalidation+epoch→currentSDK binding и original-epoch model factory/restore. Generic eventsнеотправляютcommands и не переносятownerdata. Реальные SDK fixtures через customURLSession/URLProtocol+isolatedAuthLocalStorage и SQLite, >=130actualtests(124old+>=6new), highriskReviewQA. Nativeprovidercontinuation/actualviews/debugUIfixture отдельно. Источники pinnedSDK прочитаны локально; SourceAuth listener Sendable/remove sync/auto-on-deinit, SDKcurrentSession sync mayexpired/.session refreshasync. Никаких livecalls.

**Target preparation:** controllerсоздал `ios/PlantsTests/CatalogueConnectionTests.swift` толькоimports; XcodeGen добавил4строки/0deleted вpbxproj, unitSourcesmembership подтверждён ДО evidence. Нет новой реализации/130PASS; защищённые tests/project/config/gates авторитcontroller. Validate/context/diff→commit/push preparation/handoff/taskpartial→clean run `parallel-ios-catalogue-sdk-session-20261110-01` с прежним config1bf347cc. До явной передачи accepted/разрешённых B SHA ихнеобъединять, ихworkflowразрешениянеподменять запускомизA. Main72bcccc,14/151; fullT162/T149/Auth/live открыты.

## UI model candidate восстановлен; найден Observation reentrancy перед приёмкой

Подготовкаd07f39e опубликована. Run `parallel-ios-catalogue-save-model-20261110-01` — **WAITING/interrupted**, Developer1 вернул полный44826-char patch, но leading SPACE перед вторым diff --git превратил header в context и trustedapply отклонил его. Автоматический Developer2 штатно остановлен SIGINT controllerPID27848; state/ответы/история сохранены. Controller убрал ТОЛЬКО один leadingheaderSPACE, addedcodelines идентичны: originalSHA `dae2e3b0daa7fa5942d7fea2da5f7f23c6a508b9023aea14d2a8ed2f2654fbb8`, normalizedSHA `b50e7332d674f593c66e553219889e3117c1025f5e37ca98a00ed5931a7dd5ae`; trusted scope/apply/whitespace PASS. Начальная проверка гипотезы blankseparator ничего не изменила (assertcount0), затем проверен фактический singleheaderSPACE. Runtime candidate НЕ принят.

**Кандидат:** CollectionRepository.swift10строк internal original-contextsave helper; CatalogueSaveModel.swift248строк @MainActor/@Observable immutableSDKowner/lease, guarded state/input/envelope/checkpoint, typed guest/pending/saved/cap/unavailable/cancel, sameownerflowrestore; CatalogueSaveModelTests.swift635строк12candidate scenarios. App/unit targets подготовлены ДО этого. Build/121tests/ReviewQA этим run НЕ запускались, old109 acceptedf53227b отдельно.

**Реальный дополнительный root finding:** @Observable phase/checkpoint mutates ВНУТРИ nonrecursive SyncSessionAuthority lock. Foundation/Observation probe `/tmp/narat-observation-lock-probe.swift` подтвердил synchronouscallback при heldlock (`OBSERVATION_CALLBACK_SYNCHRONOUS_LOCK_HELD`), callback re-read guardedmodel.state/input/checkpoint или SDK invalidate повторно захватиттотжеlock. Первая sandboxпопытка Swiftmacro не стартовала; системный Swift с разрешением запустил probePASS. Это macOS APIprobe, НЕ actualmodel/Simulator regression. Evidence `validation/automation/runs/parallel-ios-observation-probe-20261110-01/{probe.swift,stdout.log}` игнорируетсяGit. До UI нужен реальный regression и исправление публикации (validatecontext отдельно, observablemutation безauthoritylock, guardedgetter сохраняетownerredaction).

**Новый narrow repair:** `tasks.parallel-ios-catalogue-model-observation-repair.json`; write только model+егоtests, fullcandidate independentacceptance, минимум122actualtests (109old+12candidate+>=1synchronous actualmodelobserver). Callback reread state/input/checkpoint и invalidate тойжеauthority должен вернуться безdeadlock, не дать staleHTTP/cache/ACK; не заменять lockrecursive и не ослаблять ownership/tests. Validate/context/diff → checkpoint commit/push непринятогокандидата/handoff/manifest → clean run `parallel-ios-catalogue-save-model-20261110-02` с прежним branchconfig1bf347cc. Старыйrunнеresume. Actualviews/nativeAuth/live/T162/parents открыты,14/151; main72bcccc.

**Дальнейшая очередь уточнена:** сначала SDK session/resources/model factory+realSDK HTTPfixtures, затем отдельный nativeprovider currentinputcontinuation, затем renderedENPLviews/UIgates. B011/012 independent workflow по-прежнему ждёт разрешений в еёчате; B candidates/HEAD не объединялись и не изменялись.

## Catalogue input checkpoint принят; UI model target подготовлен — 10 ноября

Run `parallel-ios-catalogue-input-checkpoint-20261110-02` — **COMPLETED / Verified and published**, **f53227b** отправлен в origin/codex/plants-ios, checkpoint7ca6963 тоже опубликован.1Developer/1Reviewer/1QA highrisk: единственное test-only исправление plantId:nil, независимые роли просмотрели ПОЛНЫЙ текущий input/checkpoint candidate, а не только repairdiff. CatalogueInput builder хранит exact speciesSlug/name и deterministic frozen envelope; immutable owner+flow CatalogueInputCheckpointRecord — новая6ятаблица в existingLocalStore, boundoriginallease/authority и short synchronousinputlock, no await underlock. Cache не даёт guest праваcreate, не serverdraft/TTL/proof/fallback и не переносит outbox/receipts междуowners. Старый run01BLOCKED и триcompileошибки сохранены ниже, не объявлены успешными.

**Реальные checks:** Xcode build/welcome PASS; **109 PlantsTests PASS/0failed/0skips**,106XCTest+3SwiftTesting,99old+10new. Unit `q-f82da2ed5051f5210667d134/{summary.json,source-test-coverage.json,unit-result.stdout.log}`. Diff/Simulator smoke/highrisk Reviewer/QA PASS; [отчёт](validation/automation/tasks/parallel-ios-catalogue-input-compile-repair.md). Проверены builder→accepted actualsave path, exact optionalUnicodebytes, originalflow/op/payload/time черезdiskrestart, guest localcache/zeroHTTP и signInRequired, A/B/ABA/unbound/foreignauthority/cancel, actualreadonlySQLite/no phantom/retry, real5→6table upgrade+allseededoldtables unchanged, malformedstoredinput/latequeueconflict failclosed, simultaneous differentauthorities/firstimmutablecheckpoint wins. Deno/SQLэтим Swift-only run не запускались; это fixtures/realSQLite/localSimulator, не nativeAuth/renderedUI/live. Source/contracts/tools fingerprint перед UIprep `6c829cadbd5603e98687a86d8a72bb7bf53fd3ca6bc5cf521b403229a565304e`,1475trackedfiles.

**Подготовка UI model:** controller создал только imports в `ios/Plants/Features/Catalogue/CatalogueSaveModel.swift` и `ios/PlantsTests/CatalogueSaveModelTests.swift`. XcodeGen включил оба в настоящие app/unitSources ДО будущегоevidence; итогpbxproj8additions/0deletions, безcleanup. Это target preparation, не модель и не115tests. Manifest `tasks.parallel-ios-catalogue-save-model.json`: небольшой @MainActor/@Observable owner-fixed model, original boundlease на lifetime, durable input/signInRequired/pending/saved/cap/unavailable, same-owner explicitflow restore безsend/новыхUUID, staleowner dataredaction. Repository internal contextualsave overload сохраняет originallease старой модели черезABA (public API behavior unchanged); modelнеперепривязываетAPIкстаромуtoken. >=115actualtests (109+>=6), highrisk Review/QA. Views/Supabase/nativeprovider/factory/debugUIfixtures идут отдельно; bare inputбезlegacyquestionnaire.

**B фактически:** read-only проверен её clean worktree4333509: B1accepted a367d0b/сводкаbc6a879, SQL011/012 — controller candidates с локальнымиPG/Deno/automation checks, НЕ independent acceptance/merge-ready. Auto-review запретил B новые model/workflow calls (нет найденного явного trustedразрешения на code→configuredproviders/automaticpublish) и отдельно межчатовую передачу данных; её asyncразрешения ждутответа. В A это не обходится запуском B workflow; чужойHEAD/config/код не менялись и candidates не объединяются. Полученный app wait snapshot был устаревшим, потому текущаяточка сверена напрямую чтением B handoff, безсообщений/изменений. Aпродолжает свою разрешённую iOS очередь; main72bcccc. ПолныйT163/T036/API/live всёещёоткрыт.

**Точный следующий шаг:** validate/context/targetmembership/diff → commit/push targetprep/manifest/handoff/taskpartial → clean run `parallel-ios-catalogue-save-model-20261110-01` с прежним config1bf347cc. После принятой модели — actual sameSupabaseClient/nativeAuth binding+views и отдельные EN/PL Free/paid/cap/error/login-cancel/restart UI gates. T162/T149/прочиеparents не закрыты,14/151. Интегрировать только принятые и разрешённые B SHA междуruns; её permission requests не отвечать за пользователя.

## Input checkpoint candidate: run01 исчерпал compile repairs; новая узкая приёмка

Подготовка3c50c02 опубликована. Run `parallel-ios-catalogue-input-checkpoint-20261109-01` — **BLOCKED / Retry budget exhausted: developer**,3Developer calls; independent Review/QA не начинались. Полный кандидат сейчас НЕ принят: CollectionRepository.swift23строки добавляет CatalogueInput speciesSlug/name→frozen canonical envelope; LocalStore.swift157строк добавляет immutable owner+flow шестуютаблицу/checkpoint/read/original-bound-session guards и короткий staticinputlock, queue/receipt conflictguards; CollectionRepositoryTests.swift548строк10новыхactual scenarios (включая реальную5→6схему/всестарыетаблицы,readonlySQLite,concurrentdifferentauthorities).

**Точные выполненные checks:** каждый diff-check PASS. Build1 `q-d88401448a197ad92633cc90` FAIL: Swift6 sending body risks causing data races в helper nestedclosures; Developer2 заменил innerwithLock на lock/deferunlock, build2 `q-be33b21684996fe7a3beafd0` FAIL темжедиагностиком. Developer3 убрал generic helper и inline обе atomicdiskоперации под прежними locks; production Swift скомпилирован, build3 `q-df245aed1aa10e641a270066` FAIL уже в новом тесте строка2153: enqueueCommand missing plantId. Никаких109unitPASS/welcome/Simulator/Review/QA этим run НЕТ. Старые99 accepted save193a704 отдельно; это не rollback принятого кода/не смена routing/budget. Все исходные answers/patches/state/logs сохранены, controller коднеправил.

**Новый bounded repair:** `tasks.parallel-ios-catalogue-input-repair.json`, write ONLY CollectionRepositoryTests.swift, единственное добавление `plantId:nil` в этот вызов; приёмка охватывает ВЕСЬ input/checkpoint candidate, minimum109actualtests/no skips и highriskReviewer/QA. Старые tests/productionнеослаблять. Validate/context/diff → checkpoint commit/push НЕПРИНЯТОГОкандидата/handoff/manifest → чистый новый run `parallel-ios-catalogue-input-checkpoint-20261110-02` с прежним branchconfig1bf347cc; oldrun неresume. UI/realAuth/live/T162/parents открыты,14/151; main72bcccc. Backendmerge-ready010/B2SHA не передан; activeBHEADнеизменялся.

## Repository catalogue save/resume принят; UI/input checkpoint далее

Run `parallel-ios-catalogue-save-20261109-01` — **COMPLETED / Verified and published**, **193a704** отправлен в origin/codex/plants-ios,1Developer/1Reviewer/1QA highrisk без repairs. CollectionRepository.swift65строк: public CatalogueSaveResult/saveCatalogueCreate, original bound lease через journal→new-only capacity→atomic enqueue→samecontext drain→final durable journal. Existing confirmation без GET/POST/requeue, pending без нового cap/preflight, late pending/ACK выигрывает falsecap; saved только exact typed confirmation, не count чужих commits. SyncEngine.swift7строк: context-only internal overload derivesowner plus guard; accepted engine/store/wire не переделаны. CollectionRepositoryTests.swift531строка:10actual HTTPfixture→repository→engine→realSQLite/reopen scenarios.

**Реальные checks:** build/welcome PASS; **99 PlantsTests PASS/0failed/0skips**,96XCTest+3SwiftTesting,89old+10new. Unit `q-951b83294307a2d667a393ae/{summary.json,source-test-coverage.json,unit-result.stdout.log}`. Diff-check/Simulator smoke/Reviewer/QA PASS, [отчёт](validation/automation/tasks/parallel-ios-catalogue-save.md). Проверены Free2/3/paid4, guest/malformed/unbound/session mismatch, committed response lost→restart→sameHTTPbody/operation/payload/serverUUID/oneconfirmation при ужеfullcollection, cap409/auth/503/malformed200 pending, failedpreflight olddisk, ABA/cancel GETиPOST, active drain/countfalsepositive, late sameop pending/ACK, actual readonly diskACK failure сохраняетqueue. Deno/SQL этим Swift-only run не запускались. Fingerprint перед input preparation `cee69eb7c30444cf834be23a0168d4c095667a9eacff81382104b25426ebc80d`,1473trackedfiles. Это mocktransport/realSQLite/localSimulator, не UI/nativeprovider/live/fullT162/T149.

**Следующий минимальный input packet:** `tasks.parallel-ios-catalogue-input-checkpoint.json`; bare selectedspecies+optionalpersonalname, existing admittedvalidator/sortedfrozenpayload сcallerUUID. Old CareConditionsInput содержит несовместимые SQLкоды/retiredseason/camera — в новый input не включается. Маленький immutable owner+flow catalogue checkpoint в existingLocalStore/новая6ятаблица: перед nativeprovider локально сохранить выбранный input; это НЕ server guestdraft, proof,7dayTTL или guestclaimfallback. Exact replay only, no implicit ownercopy/queue/receipt; boundanonymous вправе cacheinput, createпо-прежнемуsignInRequired. >=105actualtests (99old+>=6new), реальная5→6table SQLite migration/snapshotсохранность, readonlyfailure/retry, A/B/ABA/cancel и builder→реальныйsaveHTTP. Write только LocalStore/CollectionRepository/CollectionRepositoryTests, новыхSwiftfiles/targetprepне требуется. UI/authconnection/login/cancel/card/FreepaidcaperrorENPL gates после этого.

**Подготовка/следующий шаг:** validate/context/diff → commit/push handoff/taskpartial/manifest → clean run `parallel-ios-catalogue-input-checkpoint-20261109-01` с прежним config1bf347cc. Перед run проверить передачу B: A сообщила accepted193a704 и запросила конкретный merge-ready010/B2SHA; до разрешённой передачи Bнеобъединять. Main72bcccc. T162/UI/live/parents открыты,14/151; sharedconfig/activeBHEAD не менялись.

## Атомарный catalogue journal принят; следующий repository save/resume

Run `parallel-ios-catalogue-journal-20261109-01` — **COMPLETED / Verified and published**, **5997c0d** отправлен в origin/codex/plants-ios.1Developer/1Reviewer/1QA highrisk, без repairs. LocalStore.swift98строк: atomic catalogueCreateJournal checkOnly/enqueue(canCreate), pending/confirmed/absent/limit state на existingтаблицах. Exact UTF8 identity, owner+operation receipt, global outbox collision guards; pending/receipt выигрывают ДО advisorycap, нет новых queue из confirmation, watermark не меняется. PlantsAPIClient.swift19строк: existing validator internal visibility, lease хранит authority identity; withBoundValid проверяет original bound canonical session/authority под тем же lock, explicit-session transport compatibility не даёт journal access; legacy withValid сохранён. CollectionRepositoryTests.swift498строк:10actual disk scenarios, включая concurrent4stores/одна команда, readOnly Cocoa513/no phantom/writable retry, все состояния при A/B/ABA/cancel/unbound/differentauthority, exactpending/receipt replay/conflicts.

**Реальные gates:** build/welcome PASS; **89 PlantsTests PASS/0failed/0skips**,86source XCTest+3SwiftTesting, все79старых+10новых. Unit `q-4f963006def86c2b55814528/{summary.json,unit-result.stdout.log,source-test-coverage.json}`. Diff-check/Simulator smoke/Reviewer/QA PASS. [Отчёт](validation/automation/tasks/parallel-ios-catalogue-journal.md). Deno/SQL этим Swift-only run не запускались. Mocktransport/realSQLite/localSimulator — не live/Auth/UI-save/продуктовая приёмка. Runtime/contracts/tools fingerprint перед подготовкой save `a2c954a07e70c095946a4204564add3729d78c4bf0a4c0eec451bde0dabe5f85`,1472trackedfiles.

**Подготовлен composition packet:** `tasks.parallel-ios-catalogue-save.json` write только CollectionRepository/SyncEngine/CollectionRepositoryTests. Исходный bound lease через все await; initial journal BEFORE new-create capacity; exact pending skips cap, confirmed returns original receipt без requests, new требует successful canonical refresh. Atomic journal rechecks late pending/receipt после await прежде falsecap. Same-context existingengine drain; commit count не доказательство сохранения нужной операции, final durable journal decides saved/pending. Stable UUID/payload caller-supplied, typed persisted server409/503/lost-response/restart, malformed/failed preflight и отмена failclosed. >=95actual tests (89old+>=6meaningfulnew), highrisk Review/QA. Input builder/UI/login/card отдельный следующий пакет.

**Следующий шаг:** validate/context/diff → commit/push подготовки/handoff → clean run `parallel-ios-catalogue-save-20261109-01` с прежним branch config1bf347cc. T162/save/UI/live/parents открыты,14/151; main72bcccc, B010/B2неmerge-ready. Не менять active B HEAD/shared config/исторические logs.

## Outbox identity и typed errors приняты; следующий атомарный catalogue journal

Run `parallel-ios-outbox-identity-errors-20261109-01` — **COMPLETED / Verified and published**, commit **1eb80cc** отправлен в origin/codex/plants-ios. Developer1 добавил guard owner/plant/command/UTF8payload в generic enqueue (чужие snapshot не выдаются), computed OutboxEntrySnapshot.lastAPIError и Codable JSON для реального APIErrorResponse в existing lastError. Schema/dispatch/ACK поведение сохранены. Изменены LocalStore.swift16строк, SyncEngine.swift8, CollectionRepositoryTests.swift276;7новых meaningful tests, включая Unicode canonical equivalence с различными bytes.

**Проверки/repair:** первый прогон build/welcome PASS,79 actualtests:78PASS/1FAIL — тест ожидал concrete URLError String, а engine работает с Error existential. Developer2 исправил ТОЛЬКО одну строку ожидания `as any Error`, production/assertions не ослаблялись. Второй реальный прогон **79 PASS/0failed/0skips** (76XCTest+3SwiftTesting), `q-5e978d2fab7934a4fb3e7109/{summary.json,source-test-coverage.json,unit-result.stdout.log}`. Diff/build/welcome/Simulator smoke PASS, independent high-risk Reviewer1/QA1 PASS по всему пакету. [Отчёт](validation/automation/tasks/parallel-ios-outbox-identity-errors.md). Deno/SQL этим Swift-only run не запускались;336Deno capacity и прежние интеграционные gates отдельно. Fixture HTTP409/503+transport/realSQLite/reopen, не live/UI-save. Fingerprint перед следующей подготовкой `f9625e76557976a9d130f50c83f8f90ef8c894e89af23503c5be72439bb76e4e`,1471trackedfiles.

**Подготовлен маленький journal packet:** `tasks.parallel-ios-catalogue-journal.json`; original bound canonical lease, coherent check-only lookup и atomic conditional enqueue на existing store. Existing exact pending/receipt проверяются ДО advisorycap и выигрывают falsecap после lost-response last-slot; conflict failclosed, receipt не создаёт новый queue/plant/checkpoint. Нужна отдельная защита never-bound explicitSession transport compatibility, она не доказывает bound auth; малый helper в existingauthority допустим. Existing validator reuse/visibility only, минимум85 actual tests (79+6), actual read-only SQLite failure/cancel/ABA/replay. Write только LocalStore/PlantsAPIClient/CollectionRepositoryTests, schema не меняется; repository orchestration/input/UI следующим пакетом.

**Следующий шаг:** validate/context/diff → commit/push подготовки/handoff → clean run `parallel-ios-catalogue-journal-20261109-01` с прежним config1bf347cc. T162/journal-save/UI/live и прочие parents ещё открыты,14/151; main72bcccc. B00942ed071 принят;010Reviewer нашёл reservation+succeeded≠consumed-before-settlement, BDeveloper2 исправляет,010/B2 не merge-ready. Активный B HEAD/рабочие файлы не менялись.

## Capacity/preflight принят; подготовлены outbox identity/typed errors

Run `parallel-ios-catalogue-capacity-20261109-02` — **COMPLETED / Verified and published**, **2efd83a** отправлен в origin/codex/plants-ios; checkpoint f76e091 тоже опубликован. Read-only независимые Reviewer1/QA1 приняли ВЕСЬ восстановленный кандидат четырёх Swift-файлов, не пустой diff. Read-only facade получает canonical full snapshot под исходным lease, считает все live plants, Free<3 и strict paid/trial/grace expiry; guest/unbound/stale/failure не превращаются в пустую доступную коллекцию. Controller context-import recovery и fractional-expiry correction описаны ниже; старый run01 остаётся WAITING, не переименован в completed.

**Реальные проверки:** Xcode build/welcome PASS; **72 PlantsTests PASS/0failed/0skips**, все69 XCTest methods+3SwiftTesting включены/выполнены, включая8новых repository→API→engine→реальный SQLite. Unit `q-d31f861995bb8c178a73d30d/{summary.json,source-test-coverage.json,unit-result.stdout.log}`. Deno **336 PASS** (fixtures); diff-check PASS. Simulator smoke `q-f68844242841863d8e284c57` welcome/care-navigation PASS; Reviewer/QA PASS. [Отчёт](validation/automation/tasks/parallel-ios-catalogue-capacity-recovery.md). Runtime/contracts/tools fingerprint перед следующей подготовкой `6e0393794badbd15a77d80ad5401e24512db1dfc6e1aa25c0a9e71bdcc5f1d7c`,1470trackedfiles. Это mock transport/disk/local UI, не live/cap/save UI.

**Следующий узкий пакет:** `tasks.parallel-ios-outbox-identity-errors.json`, write только LocalStore/SyncEngine/CollectionRepositoryTests. Исправить global operation lookup: exact owner/plant/command/payload replay, чужой/изменённый command fail-closed без выдачи чужого snapshot/изменений. Реальный APIErrorResponse сохранять JSON в existing lastError; computed typed projection после disk restart, legacy strings совместимы, без substring mapping. Минимум77 actual tests (72old+5meaningful), high-risk Reviewer/QA; input/new journal/save/UI позже. Parent T162 и прочие checkbox не закрыты,14/151. Main остаётся72bcccc; B42ed071 finalize принят отдельно,010/B2 ещё не merge-ready. B/main/shared config не менялись.

**Подготовка/следующий шаг:** validate/context/diff → commit/push этого handoff/task partial/manifest → чистый run `parallel-ios-outbox-identity-errors-20261109-01` со своим config1bf347cc; дождаться Developer/checks/Reviewer/QA/publish. После этого contextual journal и save/resume composition; UI/login/card отдельный gate.

## Capacity candidate восстановлен; точная expiry исправлена до приёмки

Run `parallel-ios-catalogue-capacity-20261109-01` — WAITING/interrupted, не принят. Developer1 вернул полный24551-char patch, но context тестового import Foundation отсутствовал в skeleton; автоматический второй вызов остановлен controller SIGINT, оригинальные answer/state/logs сохранены. Controller добавил только этот import и применил неизменённый diff через trusted scope/whitespace validator. Кандидат: CollectionRepository.swift read-only preflight/capacity, LocalStore.swift coherent snapshot, SyncEngine.swift same-lease full refresh, CollectionRepositoryTests.swift7 API→engine→disk tests.

Controller отдельно воспроизвёл Foundation точную границу: `.000003Z` при Double(micros)>DateUnix*1e6 ошибочно future на0.25us. Исправлено сравнение advisory expiry через SQLTimestamp.date>однократно захваченную clock Date; добавлен восьмой реальный repository/disk test before/equal/equivalent offset/after для valid_until/trial_end_at. Это явная controller-коррекция, не приписывается Developer. Подготовлен read-only `tasks.parallel-ios-catalogue-capacity-recovery.json`: весь текущий кандидат, минимум72 actual tests, zero skips, build/welcome/Simulator и независимые Reviewer/QA. Пока реально выполнены только Foundation probe и diff-check PASS; Swift gates ещё НЕ запускались. T162/UI/save/родительские checkbox14/151 остаются открытыми, live нет.

**Следующий шаг:** validate/context → checkpoint commit/push непринятого кандидата/manifest/handoff → новый чистый run `parallel-ios-catalogue-capacity-20261109-02` со своим прежним config1bf347cc. Старый run не resume. Дождаться реальных checks/Review/QA; далее journal/input/enqueue owner+payload guards и отдельный save/resume.

## Repository run остановлен без patch; новый capacity-only пакет

Подготовка28ac700 успешно отправлена в origin/codex/plants-ios; run `parallel-ios-catalogue-repository-20261109-01` — **WAITING**,1Developer, timeout900s, answer.json/полный patch отсутствуют, task.patch пуст. Runtime не изменён, оба новые Swift файла остаются только imports, Xcode target подготовлен8строками. Build/unit/Review/QA нового repository не запускались. Это НЕ реализация capacity/save и не новые70tests. Старые state/logs/manifest сохранены; старый run не resume.

**Уменьшение scope:** новый `tools/automation/tasks.parallel-ios-catalogue-capacity.json` реализует только функциональный read-only capacity/preflight facade на existing canonical engine/disk: explicit bound native session/SDK guest flag, original lease, Free count<3/paid eligibility по точному SQL, никакого POST/enqueue/status/create.6 focused scenarios/минимум70 actualtests вместе со старыми64. Risk medium/complexity low по этому read/advisory scope, штатный Sol route/раздельные Reviewer/QA; config/routing/budgets не переопределялись. Затем отдельный journal/input/enqueue guard/typed errors → отдельная композиция save/resume; старый широкий AC не выдаётся за готовность.

**Проверки подготовки:** validate VALID(1task), полный context/scope просмотрен, task.patch=0bytes, diff-check PASS. **Следующий шаг:** commit/push подготовки/handoff → чистый `python3 tools/automation/orchestrator.py run --config docs/validation/automation/runs/parallel-ios.config.json --manifest tools/automation/tasks.parallel-ios-catalogue-capacity.json --run-id parallel-ios-catalogue-capacity-20261109-01`. Дождаться реального кода/tests/Reviewer/QA. Main72bcccc и accepted engine22bc1a6 сохранены; новые родители/checkbox не закрыты. B141reserve accepted ограниченно,009/010/B2 после timeout разнесены в run05,663e0d9 — подготовка, не новая операционная квота; B файлы/HEAD не трогались.

## Engine durable ACK принят; подготовлен catalogue repository core

`parallel-ios-create-receipt-engine-20261109-01` — **COMPLETED / Verified and published**, commit `22bc1a6b99f801a0a2b551f3093058aca1263464` отправлен в origin/codex/plants-ios (base main72bcccc).1Developer/1Reviewer/1QA highrisk, без repairs. Typed captured-token result теперь доходит до `acknowledgeCatalogueCreate`; canonical create не удаляется generic ACK без receipt. Outbox reads/writes используют fresh contexts, network/send failure отделён от disk ACK failure, concurrent same-owner drain не дублирует dispatch, exact HTTP200 required for canonical confirmation, current public receipt/legacy API сохранены.

**Изменены:** PlantsAPIClient.swift (23строки diff), SyncEngine.swift (27), LocalStore.swift (11), CollectionWireTests.swift (503), task report `validation/automation/tasks/parallel-ios-create-receipt-engine.md`. **Реальные gates:** Xcode build/welcome PASS; **64 PlantsTests PASS/0failed/0skips** (61XCTest+3SwiftTesting), все55прежних+9новых; `q-c8b8b98c1d0f691443d6061f/{summary.json,unit-result.stdout.log,source-test-coverage.json}`. Simulator smoke `q-4bd216ab59b769b21cbba840` PASS, diff/Reviewer/QA PASS. Проверены fixture committed-then-lost response/restart/same HTTPbody/op/payload/server UUID/one confirmation, malformed200/202/cap409/auth503, staleA/B/ABA/cancel, actual Cocoa513 ACK/failure bookkeeping+retry, duplicate flush, generic ACK guard. Deno/SQL в этом Swift-only run не запускались; предыдущие merged checks остаются отдельно. Это client fixtures/disk/Simulator, не UI/live. Принятый SHA передан B.

Accepted engine runtime/contracts/tools checksum до следующей подготовки: `916b84d80a4a3743b4ef8b394f790dbdcdb856c965443274fecc14dc9c2067c9`,1465 tracked files; main остаётся на72bcccc (его проверенный runtime63025c67), новый engine пока опубликован только iOS. B141reserve ограниченно принят,009/B2 ещё в работе; sourcecandidate d5e6 не объединялся.

**Подготовка следующего narrow пакета:** `tasks.parallel-ios-catalogue-repository.json`; controller создал два новых Swift-файла только с imports и XcodeGen добавил их в реальные app/test Sources ДО evidence. Это target preparation, не реализация/не passing tests. В этом git worktree отсутствовали старые пустые каталоги: первый regenerate убрал120emptygroupстрок; controller восстановил только их пустые directory paths и повторил XcodeGen, окончательный pbxproj diff ровно **8 additions/0deletions** для двух новых файлов, без посторонней чистки. Новые runtime/test paths `ios/Plants/Data/Repositories/CollectionRepository.swift`, `ios/PlantsTests/CollectionRepositoryTests.swift`.

Repository core: explicit bound native session/SDK guest flag, canonical payload, fresh count/authoritative entitlement cap (Free<3/paid unlimited), frozen operation/payload/resume, typed error after disk restart, same lease through preflight/enqueue/drain/ABA guards. Existing pending/receipt проверяются до нового cap и атомарно после preflight; иначе lost response на последнем месте ошибочно блокировался бы. Найден baseline enqueue gap: global operation reuse возвращает старый snapshot без owner/payload guard — новый пакет должен fail-closed, не возвращать A запись вB. Grace-until alone не paid, monthly quotas/first-purchase anchor не использовать. UI/login/card/guest claim и полные parents позже.

**Подготовка checks:** validate VALID(1 task), полный context/criteria/scope сохранены и просмотрены, diff-check PASS; pbxproj target membership подтверждён. **Следующий шаг:** commit/push target preparation/manifest/handoff → чистый `python3 tools/automation/orchestrator.py run --config docs/validation/automation/runs/parallel-ios.config.json --manifest tools/automation/tasks.parallel-ios-catalogue-repository.json --run-id parallel-ios-catalogue-repository-20261109-01`; controller запускает реальные unit>=70/build/Simulator и независимые Reviewer/QA. Старые64tests/legacy/retired writers сохраняются. Tasks 14/151 и T162/T046/T149/T025/T026/T163/T164 открыты; комнаты/live не активированы.

## Подготовлен engine→durable receipt ACK после интеграции main

Интеграционный runtime947d602 опубликован в main, docs-подтверждение72bcccc также успешно fast-forward/push в origin/main и iOS. B переданы SHA/точные расширенные SQL gates/fingerprint, подхват только между её runs. Source/runtime/contracts/tools fingerprint63025c67 остаётся тем же до следующей подготовки.

**Следующий узкий manifest:** `tools/automation/tasks.parallel-ios-create-receipt-engine.json`; accepted store 09e9b3a не переделывается. Write scope только PlantsAPIClient/SyncEngine/LocalStore/CollectionWireTests. Captured-token transport возвращает существующий typed receipt, existing engine вызывает atomic acknowledgeCatalogueCreate; canonical create не проходит generic delete без receipt. Раздельно проверить network/invalid200/cap/auth и disk ACK failure, failed-save retry metadata/fresh context, lost-response/restart/ABA/cancel. Receipt watermark не advance sync checkpoint. Minimum60 actual tests (старые55+meaningful новые), build/welcome/Simulator и high-risk Reviewer/QA; repository/cap UI остаются следующим срезом. Новых Swift-файлов/target regeneration не нужно.

**Факт подготовки:** validate VALID(1 task), полный Developer context просмотрен, diff-check PASS; runtime ещё не изменён. Общий default config/engine automation/SQL/B файлы не меняются, тот же branch-only config SHA256 `1bf347cc4848ab4d54844c1b69c69c83ac3ed2db98a348135ced1d5c3f77a561`. Live/remote CI не принимались этим этапом (локальный gh CLI отсутствует); это не блокирует разрешённую клиентскую fixture-работу. Parent checkbox14/151/T162/T149/T163/T164/T036 открыты, комнаты исключены.

**Точный следующий шаг:** validate/context → commit/push manifest/handoff в codex/plants-ios → чистый запуск `python3 tools/automation/orchestrator.py run --config docs/validation/automation/runs/parallel-ios.config.json --manifest tools/automation/tasks.parallel-ios-create-receipt-engine.json --run-id parallel-ios-create-receipt-engine-20261109-01`; дождаться реального результата/всех gates/Reviewer/QA/publication, затем repository catalogue save/cap и UI.

## Интеграция опубликована в main — 9 ноября 2026

**Факт публикации:** A+B merge `7c0a41e`, затем docs-only merge origin/main6a9584d → **947d6021cb3bf33b42022b95a4908c90ee80c534**. Ветка origin/codex/plants-ios успешно отправлена до этого SHA. Из отдельного чистого `/private/tmp/narat-ios-integration-20261109-01` выполнен fast-forward6a9584d→947d602 и обычный `git push origin HEAD:main`: exit0, `6a9584d..947d602 HEAD -> main`. Исходный main checkout и активный B worktree не менялись. Это кодовая интеграция принятых A1/A2/receipt-store и B005/006/007, НЕ backend deploy.

**Итоговый проверенный runtime:** SHA256 `63025c67bcf86dec2b30d6a4da4b53192aa0313a00bc1c698ad80b3a972a4ae8` по1464 tracked runtime/contracts/tools files совпал до/после тестов и в чистом integration checkout. SQL clean/upgrade по55anchor+49ledger+131cap/care, по12UTC cases,4owner-lock races, old rows byte-equal; Deno336/typecheck, automation115, Swift55/no skips/build/welcome/Simulator PASS. Логи/режимы точны в предыдущем разделе. После code gates менялись только handoff/task partial status/allocation registry; runtime не менялся. Рекорд публикации сохраняется отдельным docs-коммитом; родительские checkbox по-прежнему14/151.

**Ограничения и точный следующий шаг:** ledger+guard не заменяют текущий admission; reserve008/settlement009/accessB2/T036/live и полныйT163/T164 открыты. A durable receipt store ещё не подключён к SyncEngine: подготовить `tools/automation/tasks.parallel-ios-create-receipt-engine.json` для captured-token typed receipt→`acknowledgeCatalogueCreate` в существующем engine и APIClient→engine→disk lost-response/retry/restart/A-B/cap/invalid200 tests. Validate/context и commit/push подготовки, затем чистый run `parallel-ios-create-receipt-engine-20261109-01` со своим --config; до полного принятия не объявлять UI save готовым. B получает опубликованный интеграционный SHA и подхватывает его обычным merge только между своими runs. Shared config/старый t161 runner и T172–T174 не менялись.

## Интеграция A + принятого B prerequisite — повторные gates PASS

На чистом A worktree между runs после ec47bb1 начат обычный merge конкретного `a04794c` (B явно подтвердила готовность этого ограниченного среза). Он содержит только принятые005 anchors21ee7a7,006 ledger e6b1f7c,007 state guard a04794c, их fixtures/gate/контракт/отчёты и историю подготовки. Reserve008/settlement009/API B2 отсутствуют в этом merge. Никакого deploy/перехода к monthly-клиенту или закрытия T163/T164/T036.

Единственный конфликт — handoff: вручную сохранена вся история A, новые секции/дополнение B, исходные task reports и оба Task Summary; текущий Project State согласован по принятым SHA, не выбран слепо ours/theirs. Обновляется частичный статус T163, checkbox по-прежнему14/151. Swift/default config/общий t161 runner/backend working diff B не изменялись.

**Повторные проверки объединённого runtime — PASS:** запущена расширенная команда `python3 tools/automation/parallel_backend_quota_gate.py --accounting --legacy-guard --cap-regression` (включает всю anchors/guard/cap-проверку B и дополнительно49 ledger pgTAP). Clean и seeded-upgrade: по **55 anchor+49 ledger+131 cap/care pgTAP**, по12 UTC boundary/leap/timezone cases; **4 реальные owner-lock гонки**, все preexisting public rows byte-equal, unknown legacy anchor остаётся NULL до verified import. Только изолированные временные PG17 fixtures. Old shared t161 --slots equality по newtablekeys не запускался повторно/не заявляется PASS; пройдены все прежние131pgTAP и races новым trusted gate.

Deno **336 PASS/0failed** и deno-check PASS; automation **115 tests/OK**,40.284s; Xcode build/welcome и **55 PlantsTests PASS/0failed/0skips**,52 source XCTest+3 Swift Testing; Simulator smoke PASS. Logs `docs/validation/automation/runs/parallel-integration-20261109-01/{sql,deno-tests,deno-check,automation,ios,simulator}.log`; unit evidence `parallel-integration-ios-20261109-01/{summary.json,unit-result.stdout.log,source-test-coverage.json}`, UI evidence `parallel-integration-sim-20261109-01/`. Runtime/contracts/tools fingerprint **63025c67bcf86dec2b30d6a4da4b53192aa0313a00bc1c698ad80b3a972a4ae8**,1464 tracked files: before/after JSON совпали; проверки не изменили source. Это final local/fixture checks данного ограниченного merge, не live/backend deploy/UI-save/полныйT163. Включено docs-only движение origin/main6a9584d: сохранена история запуска родительского чата и allocation.status=sessions_started/thread/worktree IDs. Runtime не изменён, source fingerprint63025c67 совпадает; повторные code gates без новых изменений не запускались. Локальный A+B merge commit7c0a41e; следующая публикация включает оба обычных merge.

**Точный следующий шаг:** сохранить разрешённый docs-only merge/push origin/codex/plants-ios → создать отдельный чистый temporary integration checkout от origin/main, fast-forward на проверенный iOS HEAD и обычный push HEAD:main; исходный main worktree с чужой работой не менять. При новом движении main — интегрировать и проверить затронутое. После подтверждённого main push передать B SHA, записать публикацию и подготовить engine typed receipt→durable ACK.

## Durable create receipt store принят — 9 ноября 2026

Run `parallel-ios-create-receipt-store-20261109-01`: **COMPLETED / Verified and published**, commit `09e9b3abd0988017f1bef3197052df19fe419f58` успешно отправлен в origin/codex/plants-ios. Один Developer/high, независимые high-risk Reviewer/QA PASS, без repairs. Это ограниченный store prerequisite, ещё не пользовательское сохранение.

**Файлы/реализация:** `LocalStore.swift` — новая owner+operation SwiftData `CatalogueCreateConfirmationRecord`, Sendable snapshot, owner-scoped read `catalogueCreateConfirmation(ownerId:operationId:)`, internal atomic `acknowledgeCatalogueCreate(_:receipt:context:authority:)`; insert authoritative existing DTO/original payload + delete только исходной queued команды в одном isolated-context save, session authority/ownership/payload/replay/conflict guards. Receipt watermark не меняет sync checkpoint, не создаёт локальное растение. `CollectionWireTests.swift` — шесть новых disk tests, schema registration и реальное открытие старой четырёхтабличной схемы. Task report `docs/validation/automation/tasks/parallel-ios-create-receipt-store.md`, manifest/handoff.

**Проверки:** Xcode build/welcome PASS; **55 PlantsTests PASS /0failed/0skips**, все52 source XCTest+3 Swift Testing, в том числе все49 прежних. Evidence `q-ba1fce6661517b6321841623/{unit-result.stdout.log,source-test-coverage.json,summary.json}`. Проверены exact replay, every receipt/payload conflict, same UUID owner namespaces и очередьB при replayA, stale ABA/cancel, actual Cocoa513 atomic rollback+retry с тем же payload, independent disk reopen, legacy schema/cache/Date checkpoint без перезаписи, checkpoint/cache/outboxA/B сохранены. Simulator smoke PASS (`q-887e2233b841808aec52da5c`), diff-check PASS, Reviewer/QA PASS. Deno в этом Swift-only run не запускался; последний336 PASS был на принятом A2. Fixtures/temporary disk/Simulator, не live/backend/UI-save.

**Оставшаяся зависимость:** SyncEngine/transport пока НЕ вызывают новый durable ACK — текущий A2 generic create drain всё ещё выбрасывает receipt. Следующий клиентский manifest должен вернуть typed receipt из captured-token transport, вызвать atomic store ACK и проверить APIClient→engine→disk lost response/retry/restart/A-B/cap/error. Только затем repository/cap/login/cancel/save/card и реальные local UI gates. Полные T162/T046/T149 остаются открыты, checkbox 14/151.

**Координация/точный следующий шаг:** B явно разрешила интегрировать конкретный `a04794c` как завершённый ограниченный anchors005+ledger006+guard007 (21ee7a7/e6b1f7c/a04794c). Reserve008/settlement009/B2 API/полныйT163 не входят; deploy не выполняется. После commit/push этого handoff на чистом дереве между runs: fetch origin → merge a04794c, вручную объединить обе истории handoff/Project State → повторить `python3 tools/automation/parallel_backend_quota_gate.py --anchors --legacy-guard --cap-regression` (clean/upgrade55anchor+131T161,4races,preexisting rows), Deno/typecheck/automation и iOS55/Simulator на итоговом runtime → commit/push iOS → обычная интеграция main из отдельного чистого checkout по README. Старый t161 --slots equality FAIL на новых таблицах не выдаётся за PASS; общий runner/config не менять в этом шаге. Затем передать B интеграционный SHA и продолжить engine ACK. B активный run/HEAD не меняется.

## A2 engine/disk принят; следующий durable create receipt store

Run `parallel-ios-sync-store-20261109-04`: **COMPLETED / Verified and published**, commit `643622bafcd527bb1f34995d94c58d46ddc9dfef` отправлен в origin/codex/plants-ios. Независимые high-risk Reviewer/QA приняли ВЕСЬ A2-кандидат (`2e1cc75` + explicit null encoder `96dbd3d` + failed-save repair), не только последний diff. В run-04 один Developer/Reviewer/QA; предыдущие timeout/failed candidates включены в историю, экономия не заявлена.

**Результат:** существующий SyncEngine использует canonical A1 при явно привязанной сессии (`await api.bindSyncSession(NativeAuthSession?)`), сохраняет raw since/until/cursor/next_since через завершённый disk checkpoint/restart, staged pages/profile/entitlement/tombstones и owner/session generation. Legacy Date/DTO compatibility сохранена отдельной веткой без fallback из canonical ошибок. LocalStore пишет/читает sync через изолированные контексты, после actual SQLite failed save не видит незафиксированный checkpoint; следующий запрос использует прежний точный since. Entitlement nil кодируется явными null, пустой changes не теряет profile/rights. Outbox/session A/B/ABA/cancel проверены. Ручной уход/expiry/UI/Auth wiring этим срезом не принимались.

**Файлы:** `ios/Plants/Data/{Remote/APIModels.swift,Remote/PlantsAPIClient.swift,Sync/SyncEngine.swift,Local/LocalStore.swift}`, `ios/PlantsTests/CollectionWireTests.swift`, task report `docs/validation/automation/tasks/parallel-ios-sync-store-rollback-repair.md`, manifests/handoff. Последний repair30 строк store +97/17 итоговый Git diff с усиленным тестом: actual Cocoa513, оба full/incremental failed save, все snapshots/queues/owners и следующий network request с old exact since; assertions не ослаблены.

**Реальные проверки финального runtime:** Deno336 fixtures PASS; Xcode build-for-testing/welcome PASS; **49 PlantsTests PASS/0failed/0skips**, все46 source XCTest+3 Swift Testing. Evidence `q-a9ea00e562b552f8147b8075/{unit-result.stdout.log,source-test-coverage.json,summary.json}`. Simulator smoke PASS (`q-19292d95427f4b0c10523a37`, welcome→care accessibility/screenshots). Diff PASS, high-risk Reviewer/QA PASS, publish подтверждён state. Это local/mock transport/temporary SQLite и Simulator, не live backend/Auth/Storage/AI/StoreKit или UI-save. Промежуточный page cursor на диск отдельно не публикуется: после незавершённого окна сохраняется прежний checkpoint, окно запрашивается заново. SHA принятого A2 с этими ограничениями передан B.

**Ограничение следующего save:** A2 декодирует typed create receipt при outbox drain, но пока удаляет команду без durable связи operation→server plant ID. Подготовлен `tasks.parallel-ios-create-receipt-store.json`: только owner-scoped SwiftData confirmation+атомарный ACK на существующем LocalStore, exact replay/conflicts/readonly disk/session tests. Engine/transport hook — следующий зависимый маленький manifest; repository/cap/login/cancel/save/card и UI gates идут после него. Receipt watermark не становится sync checkpoint, никакого локального фиктивного plant success.

**Статусы/следующий шаг:** T162/T025/T026/T149 остаются открыты; tasks 14/151. Validate VALID(1 task), Developer context просмотрен, diff-check PASS; commit/push handoff/manifest → чистый run `python3 tools/automation/orchestrator.py run --config docs/validation/automation/runs/parallel-ios.config.json --manifest tools/automation/tasks.parallel-ios-create-receipt-store.json --run-id parallel-ios-create-receipt-store-20261109-01`; все gates/Review/QA до приёмки. Main/файлы B/default config не менялись; B bundle удерживается до forward guard и merge-ready SHA (номер migration может измениться при их новом split).

## A2: encoder исправлен, выявлен memory checkpoint после failed save

Подготовка `7a387df` отправлена в origin/codex/plants-ios. Run `parallel-ios-sync-store-20261109-03`: Developer1 добавил 12 строк explicit encode(to:) SyncWireEntitlementDTO, сохраняющий обязательные nullable даты. Build/welcome/Deno336/diff PASS. Реальные **49 tests:48 PASS/1FAIL/0skips** (xcresulttool), прежние четыре дополнительные ошибки null исчезли. Оставшийся `testCanonicalSaveFailureRollsBackWindowAndProjection` наблюдает после Cocoa513 save failure новый watermarkRaw09:00:00.999999 вместо прежнего08:00:00.000001 в том же LocalStore; независимый disk state не объявляется потерянным. Это data-loss risk следующего delta. Evidence `q-b4f4c0d02694c7e447028ad4/{unit.stdout.log,summary.json,unit.xcresult}`. Developer2 корректно вернул BLOCKED: LocalStore вне encoder-only write scope. Попытка controller SIGINT пришла после завершения процесса (no such process), исходный run естественно завершился BLOCKED; ничего не перезаписывалось. Review/QA/Simulator smoke не запускались.

**Следующий узкий manifest:** `tools/automation/tasks.parallel-ios-sync-store-rollback.json`, разрешены LocalStore и только meaningful доп. regression в CollectionWireTests; старые49 tests/readonly-save сценарий не ослаблять, encoder оставить. Исправить состояние того же store после failed save, сохранив old cache/checkpoint/profile/entitlement/outbox и session authority; проверить read-after-success и next since, включая independent disk reopen. Предложение для исследования — isolated staging ModelContext и fresh reads, а не скрытие дефекта fallback. Полная high-risk приёмка охватывает весь A2-кандидат.

**Точный следующий шаг:** validate/context/diff → checkpoint commit/push текущего encoder+manifest/handoff (не acceptance) → чистый запуск `python3 tools/automation/orchestrator.py run --config docs/validation/automation/runs/parallel-ios.config.json --manifest tools/automation/tasks.parallel-ios-sync-store-rollback.json --run-id parallel-ios-sync-store-20261109-04`. A2/T162 не приняты, tasks 14/151, live/UI/repository отдельно. B сообщила ledger e6b1f7c принят на fixtures, но весь quota bundle удержан до guard008; merge/main не выполнять до передачи merge-ready SHA.

## A2: disk tests выявили потерю обязательных null-ключей

Checkpoint `2e1cc75` успешно опубликован в origin/codex/plants-ios. Recovery run `parallel-ios-sync-store-20261109-02` — **BLOCKED** (read-only). Diff-check/Deno PASS (336 fixtures); Xcode build и welcome PASS. Реально выполнены все 49 unit tests: **44 passed / 5 failed / 0 skipped**. Пять новых disk/session tests падают на чтении persisted entitlement: `keyNotFound(grace_until)`. Причина: после добавления Codable synthesized encoder опускает nil valid_until/grace_until/trial_end_at; строгий decoder требует эти nullable ключи. Это реальный дефект persistence, не основание ослабить canonical decode. Read-only save failure действительно наблюдалась как Cocoa513, но весь rollback-сценарий пока не PASS из-за того же decode. Evidence `q-1daade1347850cfea08f5845/{unit.stdout.log,summary.json,unit.xcresult}`; summary дополнительно прочитан xcresulttool вне sandbox (первая sandbox-попытка не смогла записать TestReport cache). Simulator smoke/Reviewer/QA не начинались.

**Узкий repair:** `tools/automation/tasks.parallel-ios-sync-store-repair.json` разрешает только explicit encode(to:) в SyncWireEntitlementDTO (APIModels.swift), все обязательные даты сохранять null при отсутствии, strict decode не менять, тесты не менять. Существующие пять падающих disk-сценариев — meaningful regression. Приёмка остаётся по ВСЕМУ A2, minimum49 tests/no skips, полный high-risk Review/QA.

**Точный следующий шаг:** validate/context/diff → commit/push подготовки → чистый запуск `python3 tools/automation/orchestrator.py run --config docs/validation/automation/runs/parallel-ios.config.json --manifest tools/automation/tasks.parallel-ios-sync-store-repair.json --run-id parallel-ios-sync-store-20261109-03`. Дождаться всех gates/Review/QA/publish; A2/T162 не приняты. Tasks 14/151, live/UI/repository отдельно.

## A2: timeout после полного diff, кандидат восстановлен для приёмки

Подготовка A2 `cfcf7a3` отправлена в origin/codex/plants-ios; run `parallel-ios-sync-store-20261109-01` стартовал на чистом дереве. Первый Developer (Sol/high по сохранённому config) **WAITING / timeout900s**, `answer.json` отсутствует, checks/Review/QA исходного run не начинались. В отличие от прежнего timeout без patch, здесь Developer успел выполнить Python/difflib и вывести три последовательных полных diff в read-only stdout. Последний успешный `item_19`: **54746 bytes**, SHA256 `44ce747af63b0406be696531a4e2681fa34b7902363ac316c3bff4dbf44fbd90`. Именно он побайтово сопоставлен с восстановленным кандидатом; прежние iterations/state/logs не переписаны. Первая проверка ошибочно ожидала один diff в журнале; затем все три проверены, выбран последний, совпадение SHA/bytes и reverse-check подтверждены. Содержимое не менялось.

**Кандидат НЕ принят:** controller применил точный raw diff через `git apply --recount` после успешного check; обратный apply-check/diff-check PASS. Изменены `APIModels.swift` (Codable projections), `PlantsAPIClient.swift` (bound session/generation/immutable token transport), `SyncEngine.swift` (canonical staging/window, legacy compatibility), `LocalStore.swift` (raw checkpoint/entity time, atomic save/rollback, profile/entitlement/owner guard), `CollectionWireTests.swift` (6 новых meaningful disk/session tests). В diff 888 insertions/52 deletions по минимальному Git diff. Новый `SyncSessionAuthority` синхронно сериализует bind и короткий участок disk publication; принятие этого решения по concurrency/risk — задача независимого Reviewer. Встроенный catalogue outbox path декодирует receipt, durable сохранение результата для repository/UI остаётся следующим отдельным срезом. Runtime/legacy integrity ещё не подтверждены тестами.

**Подготовка recovery проверена:** validate VALID (1 task), Reviewer context просмотрен; diff-check PASS. **Новая приёмка:** `tools/automation/tasks.parallel-ios-sync-store-recovery.json`, READ ONLY полный текущий кандидат (пустой diff не ограничивает review), minimum49 tests без skips, Xcode build/welcome/Simulator, Deno и high-risk Reviewer/QA. Config/routing/budgets прежние, SHA256 config `1bf347cc4848ab4d54844c1b69c69c83ac3ed2db98a348135ced1d5c3f77a561`. No resume старого run с изменённым контрактом.

**B:** срез anchor `21ee7a7` НЕ merge-ready: дополнительный тест B обнаружил flip anonymous true→false для legacy permanent с NULL anchor; ожидается отдельная forward-защита. Ledger/admission ещё в работе. Collection wire неизменён. Старый quota_anchor_at — дата first purchase, не registration anchor; T036 ждёт отдельный authoritative access RPC/API, никаких клиентских reinterpretation. Файлы B/main не менялись.

**Точный следующий шаг:** validate/context recovery и diff → checkpoint commit/push НЕПРИНЯТОГО A2 → чистый запуск `python3 tools/automation/orchestrator.py run --config docs/validation/automation/runs/parallel-ios.config.json --manifest tools/automation/tasks.parallel-ios-sync-store-recovery.json --run-id parallel-ios-sync-store-20261109-02`; дождаться реальных gates и high-risk приёмки. При compiler/runtime дефекте — отдельный узкий repair по фактической ошибке. T162/T025/T026/T149 открыты; live/UI/save не подтверждены.

## A1 transport принят; A2 engine/disk подготовлен — 9 ноября 2026

Run `parallel-ios-sync-transport-20261109-03`: **COMPLETED / Verified and published**, commit `7cb5893` успешно отправлен в origin/codex/plants-ios, base `7989632`; полный восстановленный кандидат из checkpoint `6f188dd` принят независимыми Reviewer/QA, не только 2-строчное исправление компиляции. Один Developer/Reviewer/QA в run-03; общий расход включает неуспешные run-01/02 и прерванный третий вызов, экономия не заявляется.

**Результат и файлы:** `APIModels.swift` (отдельные SyncWire DTO/profile/entitlement/JSON/tombstones, raw timestamp strings + integer microsecond comparisons), `PlantsAPIClient.swift` (отдельный fetchSyncWirePage с explicit NativeAuthSession owner/token, exact query/strict pagination/error propagation), `CollectionWireTests.swift` (8 новых тестов), task report `docs/validation/automation/tasks/parallel-ios-sync-transport-compile-repair.md`, этот handoff. Принятые receipt и legacy public fetch/DTO сохранены, engine/store/UI ещё не подключены. Typed receipt не принимался заново.

**Фактические проверки:** полный Deno **336 passed / 0 failed** (fixtures); Xcode build-for-testing и EN welcome PASS; PlantsTests **43 passed / 0 failed / 0 skipped**, из них все 40 source XCTest-методов подтверждены log (плюс 3 Swift Testing). Evidence: `docs/validation/automation/runs/q-cbb51fbf61d934f9ea62bb0d/{unit-result.stdout.log,source-test-coverage.json,summary.json}`. Simulator smoke PASS (`q-78e89c1d2f3ba94ef9ef4f6d`, welcome→care screenshot/accessibility; controller просмотрел care-method.png), diff-check PASS, Reviewer/QA PASS по всему transport-контракту. Это local Simulator/mock transport, не live Auth/Supabase/Storage/AI/StoreKit, не UI-save/checkpoint/restart.

**A2:** обновлён `tasks.parallel-ios-sync-store.json`: внешний принятый SHA A1, точные checkpoint строки/legacy Date compatibility, единая LocalStore transaction для всех страниц/profile/entitlement/checkpoint, rollback, tombstones, cancellation/session A→B→A и outbox isolation. Старые fixtures не превращаются в production fallback; canonical bound session path обязан использовать A1 на том же SyncEngine. Новые tests остаются в уже включённом CollectionWireTests. Config/routing/budgets прежние; main/default config/backend не менялись. B передан принятый A1 SHA с ограничением: engine/disk ещё не готов, полный T164 ждёт T162/T163.

**Статусы/следующий шаг:** product checkbox прежние 14/151; T162/T025/T026/T149 открыты. A2 validate/context/diff → commit/push handoff/manifest → чистый запуск `python3 tools/automation/orchestrator.py run --config docs/validation/automation/runs/parallel-ios.config.json --manifest tools/automation/tasks.parallel-ios-sync-store.json --run-id parallel-ios-sync-store-20261109-01`; наблюдать до реальных checks/Review/QA/push. B после timeout разбила SQL на anchor→ledger→admission (подготовка 739862b), runtime для merge ещё не передан.

## A1: recovery остановлен на compile, подготовлен узкий repair

Checkpoint `6f188dd` успешно отправлен в origin/codex/plants-ios. Run `parallel-ios-sync-transport-20261109-02`: **BLOCKED** (read-only задача не может исправлять исходники). Diff-check PASS, полный Deno **336 passed / 0 failed** (fixtures). Реальный Xcode build-for-testing дошёл до тестов и обнаружил `CollectionWireTests.swift:470:84: type of expression is ambiguous without a type annotation`: tuple array в `invalidDates.flatMap` требует явного типа closure. Production Swift-файлы скомпилированы, но build в целом FAIL; unit/welcome/Simulator smoke/Review/QA не выполнялись. Evidence: `docs/validation/automation/runs/q-d98e3a1596b71f0f7c3beb6d/{summary.json,ios-build.stdout.log}`. Новый transport ещё НЕ принят.

**Следующий пакет:** `tools/automation/tasks.parallel-ios-sync-transport-repair.json` разрешает Developer менять только test file для этой аннотации, без переписывания production/receipt; acceptance охватывает весь checkpoint-кандидат и 43 фактически выполненных tests. Config/routing/budgets прежние, новый run ID, старые state/evidence сохранены. Handoff/tasks: T162/T025/T026/T149 открыты, локальные fixtures ≠ live/UI/disk.

**Точный следующий шаг:** validate/context/diff → commit/push manifest/handoff → чистый запуск `python3 tools/automation/orchestrator.py run --config docs/validation/automation/runs/parallel-ios.config.json --manifest tools/automation/tasks.parallel-ios-sync-transport-repair.json --run-id parallel-ios-sync-transport-20261109-03`; дождаться исправления, всех gates и независимой приёмки, затем A2.

## A1: кандидат восстановлен после двух невалидных diff — 9 ноября 2026

Подготовка `f4a67ad` успешно отправлена в origin/codex/plants-ios; исходный run `parallel-ios-sync-transport-20261109-01` запущен на чистом дереве. Developer1 вернул кандидат, но git apply отклонил zero-trailing-context hunks; Developer2 вернул полный улучшенный кандидат с одним лишним пробелом перед вторым `diff --git`. Ни один patch исходного run не применился. Третий вызов штатно прерван controller SIGINT (exit130, WAITING); исходные answer/state/logs сохранены, resume не выполняется.

**Восстановление:** из run-01 `call-2-developer/answer.json` удалён ровно один пробел перед заголовком diff для PlantsAPIClient; списки всех добавленных строк до/после побайтово совпадают. `git apply --recount --check --whitespace=error-all` и применение нормализованного diff — PASS; `git diff --check` PASS. Кандидат добавляет 296 строк APIModels, 36 PlantsAPIClient, 371 CollectionWireTests: canonical SyncWire DTO, lossless string timestamps + integer microsecond comparisons, explicit NativeAuthSession owner/token, отдельный fetchSyncWirePage; прежние DTO/receipt/engine/store не менялись. Восемь новых fixture-тестов ещё НЕ выполнялись. Это checkpoint НЕПРИНЯТОГО runtime-кандидата, не готовый срез.

**Подготовлена независимая приёмка:** `tools/automation/tasks.parallel-ios-sync-transport-recovery.json`, read-only полный просмотр трёх файлов/target membership, проверки минимум 43 tests без skips, build/welcome/Simulator, отдельные Reviewer/QA. Используется неизменённый branch config SHA256 `1bf347cc4848ab4d54844c1b69c69c83ac3ed2db98a348135ced1d5c3f77a561`; прежние runs не переписываются. Recovery validate — VALID (1 task); Reviewer context просмотрен, полный кандидат явно обязателен; diff-check PASS.

**Обмен B:** B подтвердила отдельный worktree/ветку codex/plants-backend от 4bbd35a, подготовка `365840a` (ещё не принятый runtime), T163 ledger→admission. collection-http/Swift/Simulator B не меняет. Владелец через B подтвердил: legacy без достоверной даты permanent registration — явная monthly-ошибка до verified Auth import; starter markers/расход не сбрасывать. Подготовка B не объединялась.

**Точный следующий шаг:** validate/context recovery → checkpoint commit/push (не acceptance) → чистое дерево → `python3 tools/automation/orchestrator.py run --config docs/validation/automation/runs/parallel-ios.config.json --manifest tools/automation/tasks.parallel-ios-sync-transport-recovery.json --run-id parallel-ios-sync-transport-20261109-02`. Если checks/Review/QA проходят, записать принятый SHA и запустить A2; иначе исправить фактический дефект новым узким пакетом. T162/T025/T026/T149 остаются открыты, live/UI/save/disk A2 не проверены.

## A: подготовка узких T162 transport/store — 9 ноября 2026

Прочитаны задание A, README, allocation (59 ID), AGENTS, актуальные handoff/Project State/tasks и wire/Swift-предпосылки. Worktree был чистым detached HEAD `4bbd35a`; без reset создана `codex/plants-ios`. Проверка процессов: старого активного CLI-контроллера нет. B обнаружена как активная отдельная Worktree-сессия; A передала уведомление/запрос подтверждения, до ответа нет merge/main-публикации.

**Изменены:** `tools/automation/tasks.parallel-ios-sync-{transport,store}.json`, новый controller-owned `tools/automation/parallel_ios_sync_gate.py`, этот handoff. A1 пишет только два remote-файла и уже включённый CollectionWireTests; A2 отдельно запускается после принятого SHA A1, пишет existing engine/store/remote/tests. Принятый typed receipt `e8a12fe` не повторяется. Между manifests нет вымышленных depends_on; внешние prerequisites указаны в constraints/files. Общий config не изменён. Игнорируемая копия `docs/validation/automation/runs/parallel-ios.config.json`: publish enabled → origin/codex/plants-ios, routing/budgets сохранены; ios-tests использует wrapper существующего ios_gate с проверкой фактического исполнения всех source XCTest-методов и минимум 36 total без skips. SHA256 config: `1bf347cc4848ab4d54844c1b69c69c83ac3ed2db98a348135ced1d5c3f77a561`.

**Проверки подготовки:** оба `validate` — VALID (по 1 задаче), оба Developer `context` просмотрены полностью; py_compile/diff-check PASS. Coverage helper: stale 35-test evidence и отсутствующий метод/skip отвергаются, полный synthetic log принят (только fixture self-check). Установлены закреплённые npm MCP-зависимости через `npm ci --ignore-scripts` (audit сообщил 3 moderate; версии не менялись). UI-agent setup `parallel-ios-agent-20261109-01` — PASS, установленная версия 0.0.36 подтверждена без замены. `python3 -m unittest discover -s tools/automation/tests -q` — 115 tests / OK, 39.686s (fixtures/subprocess/temp Git). Xcode/build/unit/Simulator app-smoke на новом коде пока не выполнялись. Product checkbox прежние: 14/151; T162/T025/T026/T149 и live/UI остаются открыты. Секреты/локальные configs/артефакты не staged.

**Точный следующий шаг:** commit/push подготовки в свою ветку → на чистом дереве запустить `python3 tools/automation/orchestrator.py run --config docs/validation/automation/runs/parallel-ios.config.json --manifest tools/automation/tasks.parallel-ios-sync-transport.json --run-id parallel-ios-sync-transport-20261109-01`. Наблюдать checks/Reviewer/QA/publication до фактического результата; A2 с новым ID только после принятого A1. Live Auth/Supabase/AI/StoreKit не проверены, комнаты T172–T174 исключены.

## История сессии B из принятого a04794c

Ниже сохранены обе B-подготовки/остановки и результаты, включая формулировки до приёмки guard. Актуальный статус: guard007 принят в a04794c, затем B явно разрешила A интегрировать этот ограниченный SHA; полный T163 всё ещё открыт. Точные исходные отчёты anchors/ledger/guard сохранены в validation/automation/tasks.

## B / T163 — два принятых SQL-среза, legacy guard и run03

**Опубликовано:** `21ee7a7` —005 immutable anchors/UTC-window и54 pgTAP;
`e6b1f7c` —006 shared usage/legacy reconciliation и49 pgTAP. Run02:
anchors1 Developer/1 Reviewer/1 QA; ledger2 Developer (fixture published-release
conflict исправлен)/1 Reviewer/1 QA. В обоих clean/upgrade старые public rows
сохранены; по12 UTC window cases; для ledger по54+49 pgTAP,336 Deno fixtures,
115 automation fixtures, deno-check/diff PASS. State/отчёты —
`docs/validation/automation/runs/orchestrator-parallel-backend-quota-sql-20261109-02/`.
Третий combined admission/finalize вызов: **900s timeout без answer/patch**,
WAITING,007 не создан. Run02 завершён, не resume с новым config.

**Дополнительный аудит контроллера:** до verified-import тестового setup legacy
permanent с registered_at=NULL допускает anonymous=true→false и получает clock
anchor. Отрицательный реальный PG upgrade test: FAIL1/55,
`/tmp/narat-b163-anchor-review/proof.log`. Владелец подтвердил fail-closed неизвестной
даты, поэтому этот обход обязателен к исправлению. A уведомлена: SHA21ee7/e6b1
пока не merge-ready bundle. Оба среза опубликованы, но это не готовая T163.

**Подготовлено, ещё не независимо принято:** следующая свободная007 стала
`supabase/migrations/202611090007_registration_state_guard.sql` (BEFORE permanent→guest,
независимо от NULL anchor); принятые005/006 не переписывались. В
`registration_anchors.test.sql` добавлен55-й case **до** тестового импорта.
`parallel_backend_quota_gate.py --anchors --legacy-guard` теперь загружает все
forward migrations и отдельно проверяет unknown-owner B; --reserve — отдельная
ограниченная приёмка reserve, с99 историческими consumed-fixtures и20 реальными
waiters. Она **не заменяет** итоговый default gate: после009 тот всё ещё делает
99 настоящих admit/finalize и6 раундов по20 соединений, terminal/failure/replay.
Контракт monthly-access.md обновлён:007 guard →008 reserve →009 settlement/bind.

Новый manifest `tasks.parallel-backend-quota-sql-finalization.json`: guard candidate
→reserve-only →settlement; внешние принятые SHA — constraints, depends_on только
внутри manifest. Routing/retry/budgets сохранены; config hash
`59ed00ee3315c8db379677e7aa0ef1558cc7b9be590b64f626d9cf3f043e31ff`, publish только
origin/codex/plants-backend; общий default config не менялся. Новые checks:
`parallel-backend-quota-legacy-guard` argv `python3 tools/automation/parallel_backend_quota_gate.py --anchors --legacy-guard`;
`parallel-backend-quota-reserve` argv `python3 tools/automation/parallel_backend_quota_gate.py --reserve`;
оба unit/fixture/300s. Полный gate прежнего ID теперь требует settlement009.
Validate3/context/diff PASS; guard в реальном проекте clean/upgrade55 pgTAP+12 UTC
и trusted unknown-state probe PASS, `/tmp/narat-b163-guard-project.log`.

**Координация:** A передала accepted transport7cb5893 (43 Swift) и engine/disk643622b
(49 Swift),336 Deno/build/Simulator/ReviewQA; это её fixtures, B их не запускала.
Durable receipt/repository/UI/save/live и полный T162 у A открыты. Старое sync
quota_anchor_at сохранено как historical purchase field, A не трактует его как
registration. Не менять активный HEAD ради merge.

**Ограничения/следующий шаг:** commit/push подготовки, чистое дерево → новый
`parallel-backend-quota-sql-20261109-03` с явным branch --config. После guard/reserve/
settlement и full20-connection gate — отдельный B2 SQL snapshot/production access
adapter/ENPL fixtures/ошибки. Фото job/worker сейчас injection-only (deployed worker
лишь readiness), поэтому нельзя отвечать фиктивным202 в неработающую очередь;
настоящий pipeline — boundedT153/T031–034. Auth/Supabase/Storage/provider/StoreKit
live не проверялись; B не запускала Swift/Simulator. Все parent checkbox открыты,
клиент T036 и live evidence обязательны. Владелец прямо подтвердил блокировку
unknown legacy даты до verified Auth import; повторного вопроса не требуется.

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

### Дополнение B к подготовке guard

Recovery negative control `--baseline --anchors` повторён: ожидаемый exit1 на старом Free1/calendar, `/tmp/narat-b163-baseline-v2.log`; это не продуктовый PASS.


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

## Снимок запуска сессий из main6a9584d (история)

Сохранён исходный снимок родительского чата. Упоминание ожидаемого решения/неподтверждённых CLI ниже относится только ко времени запуска; затем владелец подтвердил fail-closed legacy registration, A/B приняли перечисленные выше prerequisites. Повторного вопроса нет.

## Запущены два Worktree-чата — 9 ноября 2026

По прямой команде владельца «давай запустим сессии» через Codex create_thread созданы и фактически начали работу два чата проекта Plants, оба от опубликованного `4bbd35a`. Модель/effort не переопределялись: использованы настройки пользователя. Каждому переданы его задание, границы файлов, отдельная ветка/publish config и требование перейти от подготовки к реальному оркестратору.

| Чат | Идентификатор (host local) | Worktree | Первый пакет |
| --- | --- | --- | --- |
| Plants A — iOS и интеграция | `01a1c14d-187a-7d91-ac6d-62ae00ec6104` | `/Users/ruslansabirov/.codex/worktrees/d09a/Plants` | T162 canonical sync transport, затем engine/disk |
| Plants B — сервер и данные | `01a1c14d-2b1b-7673-83c4-c95f6fe7f7c1` | `/Users/ruslansabirov/.codex/worktrees/ffee/Plants` | T163 registration quota contract/gate, затем SQL/API |

**Реально проверено:** list_projects подтвердил Plants как Git repository; оба create_thread успешны, list_threads показал два отдельных cwd и статус active. wait_threads вернул для обоих inProgress, без error, с первыми commentary о подготовке T162/T163 и выполненными первыми tool calls. `git worktree list --porcelain` подтвердил оба checkout на `4bbd35a`; на момент снимка ещё detached HEAD, создание собственных `codex/plants-ios`/`codex/plants-backend` поручено самим чатам до run. Наличие веток/config, запуск дочерних CLI, сборка/SQL/UI/Review/QA и продуктовая приёмка в этом снимке не подтверждены. Здесь новые runtime tests/live интеграции не запускались.

**Обновлённый снимок после публикации:** A active/inProgress, готовит отдельные transport/store manifests. B active/inProgress, запросил у владельца правило legacy-миграции: отдельная дата перехода guest→постоянный аккаунт в старой БД отсутствует; предложены явная блокировка месячных анализов до подтверждения даты из Auth либо использование profiles.created_at. Решение владельца ещё не получено; основной чат не отвечает за него. Вопрос находится в чате B; это ограничение следующего quota-среза, не неудача создания сессии. Новых runtime PASS по обоим чатам пока нет.

**Изменены:** `docs/parallel/allocation.json` (status sessions_started, thread/host/worktree metadata, распределение 137 ID без изменений), этот handoff. Checkbox 14/151 сохранены. Подготовка в README/заданиях остаётся историей предыдущего этапа; актуальный факт запуска — этот раздел и registry allocation.

**Точный следующий шаг:** продолжение в двух созданных чатах. A создаёт свою ветку/config, готовит и запускает новый узкий sync transport manifest; B — свою ветку/config, quota transition contract и реальный PostgreSQL clean/upgrade/concurrency gate перед SQL run. Simulator только A; оба lane controllers публикуют только свои ветки. Итоговые пакеты объединяет A между runs по README. Родительский чат не запускает третий runtime-контроллер и не меняет их рабочие деревья. Проверка реестра — PASS: два уникальных thread/worktree, allocation всех 137 ID и checkbox 14/151 неизменны. `git diff --check` — PASS; staged whitespace — PASS. Запуск/реестр опубликованы коммитом `8397539` в `origin/main`, push exit 0 (`4bbd35a..8397539`); подтверждение сохраняется этим handoff-коммитом.

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

## История B из merge-ready bc6a879 (состояния на 9 ноября)

Эти B-specific записи сохранены вручную. Исторические числа/следующие шаги не заменяют актуальный статус выше и Project State; SQL11/12 сюда не входят.

## B — SQL005–010 принят; следующий B2 authoritative API

**Принято и опубликовано:** reserve141d548, finalize42ed071, bind a367d0b.
Run05 COMPLETED; finalize Developer/Reviewer/QA1/1/1, bind3/2/1. Reviewer нашёл
преждевременное списание reserved+succeeded до nonbillable finalize: исправлено,
только quota_state consumed подтверждает расход, до settlement указатель блокирует.
113 binding regressions приняты. Истории timeout/rejected patch сохранены.

**Реально выполненные проверки:** `python3 tools/automation/parallel_backend_quota_gate.py --bind`
PASS clean/seeded-upgrade по384 pgTAP (55anchor+49ledger+78reserve+89finalize+113bind),
12UTC cases, preexisting public rows byte-equal. Шесть раундов по20 настоящих
PostgreSQL соединений, одновременно ожидающих owner lock; перед каждым99 actual
admit+finalize на synthetic jobs, last-slot/replay/technical failure/exactly once PASS.
Отдельный `--anchors --legacy-guard --cap-regression`: clean/upgrade55+131pgTAP,
4 реальные T161 races PASS. Deno336, automation115, deno-check/diff-check PASS.
Старый shared t161 --slots FAIL table-key equality из-за новых таблиц: не изменён
и не выдан за PASS. [Подробный отчёт](validation/automation/parallel-backend-quota-sql-acceptance-2026-11-09.md).

**Файлы завершённого среза:** новые009/010 SQL, registration_admission/bind pgTAP,
controller gate/manifest, task reports. Сейчас добавлены B1 сводка и B2 proposal
`contracts/monthly-access-http.md`, canonical expected fixtures/monthly-access.json,
уточнён monthly-access.md. Это предложение нового API, не работающий endpoint.

**Ограничения:** fixtures не live Auth/Supabase/Storage/provider/StoreKit. Swift/
Simulator B не запускала; full T163/T036/guest transfer/T153 открыты, checkbox не
менялись. Владелец подтвердил: неизвестную legacy дату блокировать до verified Auth
import, не угадывать по покупке/созданию guest. Production job/worker пока injection-only,
нельзя объявлять фиктивный202. Collection wire неизменён.

**Точный следующий шаг:** отдельный bounded `tasks.parallel-backend-quota-api.json`:
сначала credential register/bind RPC и authoritative SQL snapshot, затем реальные
production HTTP adapters/ENPL/transport fixture gates; новый run ID и явный branch
config, publish только origin/codex/plants-backend. B1 merge-ready a367d0b передаётся
A только как SQL prerequisite, без deploy/полного T163. A сообщила repository save/
resume193a704 (99Swift), это evidence A. Последняя согласованная main72bcccc уже
подхвачена B; новые integration SHA — только между B runs. Подготовку/сводку сохранить
обычным commit/push до запуска B2.


## B — run03: guard принят; reserve-кандидат восстановлен, run04 следующий

**Принято/опубликовано:** `a04794c` (guard007, 1 Developer/1 Reviewer/1 QA).
Команда `python3 tools/automation/parallel_backend_quota_gate.py --anchors --legacy-guard --cap-regression`:
clean/upgrade по55 anchor +131 T161 pgTAP,12UTC cases, четыре реальные owner-lock
гонки, все preexisting public rows сохранены;336Deno/115automation/typecheck/diff
PASS. Точный отчёт: `docs/validation/automation/tasks/parallel-backend-t163-legacy-state-guard.md`.
Ограниченный accepted пакет005/006/007 разрешён A для интеграции, без deploy и
без закрытия T163/T164/T036. Ранее найденный permanent legacy NULL-anchor flip закрыт.

**Точка остановки run03:** reserve вернул патч только008+test, но fingerprint
имел74 символа вместо ожидаемых64 (дублирование подстроки). Provider правильно
отклонил ответ: WAITING/cli_error, settlement PENDING. Исходные answer/state/metrics
не менялись и не выданы за принятие. Raw answer SHA256
`de0ac185a94bff6a88cace5b273c460bed3089d11c625cb6852d3398d829a897`.
Путь: ignored `docs/validation/automation/runs/orchestrator-parallel-backend-quota-sql-20261109-03/parallel-backend-t163-reserve/call-1-developer/answer.json`.

**Восстановлен кандидат, ещё не принят независимо:** scope/git apply --numstat/
--check подтвердили только `202611090008_quota_reservation.sql` и
`registration_reservation.test.sql`. Контроллер исправил синтаксис PL/pgSQL BEGIN;
и ошибочное ожидание теста B: его fixture уже содержит два расхода; теперь
проверяется **admitted=true и remaining=0**, отказ не может дать ложный PASS.
В controller gate добавлена печать failing TAP diagnostics до удаления temp DB.
Другие функции/миграции005–007 не переписывались.

Реальный `python3 tools/automation/parallel_backend_quota_gate.py --reserve`:
**PASS** clean/upgrade по78 reserve +55 anchor +49 ledger pgTAP,12UTC cases,
четыре раунда по20 одновременно наблюдаемым PostgreSQL соединениям (distinct/same
job), один reserve и replay без нового ledger. Лог `/tmp/narat-b163-reserve-recovery-v4.log`.
Это reserve-only с99 историческими consumed fixtures, **не settlement и не полная
T163**. До исправлений честные FAIL сохранены в `/tmp/narat-b163-reserve-recovery{,-v2,-v3}.log`.
Deno для008 ещё впереди в независимом run04; предыдущие результаты не подменяют его.

**Интеграция между runs:** после завершения run03 выполнен обычный FF merge
`72bcccc` из опубликованной A main; untracked reserve-кандидаты сохранены.
A проверила итоговый `947d602`/docs72bcccc:55Swift/0skip/build/welcome/Simulator,
336Deno/typecheck,115automation и clean/upgrade55+49+131pgTAP/12UTC/4races,
fingerprint63025c67bcf86dec2b30d6a4da4b53192aa0313a00bc1c698ad80b3a972a4ae8 стабилен.
Это evidence A; B Swift/Simulator не запускала и Swift вручную не редактировала.
UI/Auth wiring/durable ACK/repository/save и полныеT162/T163/T164/T036/live открыты.

**Следующий шаг:** candidate checkpoint commit/push, затем новый
`parallel-backend-quota-sql-20261109-04` с
`tools/automation/tasks.parallel-backend-quota-reserve-recovery.json` (2tasks):
независимые Developer/Reviewer/QA для конкретного008 →settlement009. Validate2,
developer context и diff-check PASS; новый config не нужен, прежний branch config
SHA256 `59ed00ee3315c8db379677e7aa0ef1558cc7b9be590b64f626d9cf3f043e31ff`, publish
только origin/codex/plants-backend. Run03 не resume; исходный malformed ответ не
исправлять. После009 — полный99actual admit/finalize +6x20 gate и отдельный B2 API.
Auth/Supabase/Storage/provider/StoreKit live не запускались; продовые job/worker
adapters пока не подключены. Продуктовые checkbox B не закрывала.

## История throughput-аудита из25a5830 (до разрешения пилота)

Ниже сохранены факты родительской ветки; её прежний запрет старта заменён только разрешением ОДНОГО пилота выше.

## Engine/config ускорены; A/B остаются остановленными — 10 ноября 2026

По прямой команде владельца реализованы изменения общего engine/config, выполнены
только локальные проверки. Ветка **codex/development-throughput-audit**; main и
рабочие деревья/config A/B не менялись. GitHub Actions/T006 по-прежнему отложены,
новые runs/repair/Review/QA/model smoke и автоматическое возобновление не запускались.

**Реализовано:**
- Developer route по complexity, Sol medium для low/medium и high для high;
  сложное finding включает high effort repair с новой сессией. Высокий risk по-прежнему
  требует отдельные Astra Review/QA и все прежние scope/criteria gates.
- discovery20→6 (явные пути не обрезаются); read_chars16000 — инструкция для rg и
  чтения диапазонов, без принудительного усечения stdout/потери исходников.
- usage.input_tokens больше не вызывает ротацию. Порог64000 работает только при
  явно помеченном current_context measurement; текущие adapters его не дают.
  reuse_within_task/3turns/эвристика24000 сохранены; смена effort создаёт fresh session.
- После Developer timeout сохраняется replan_required; unchanged resume того же run
  не вызывает модель. Для продолжения — пересмотренный manifest/указанная устранённая
  причина и новый run. Timeout900 и бюджеты3/3/3 не увеличены и не уменьшены.
- Read-only candidates без Developer, включая восстановление после прерывания.
  candidate_base требует полный SHA предка HEAD, непустой реальный comparative diff
  и все changed paths в files (удаления тоже поддержаны). Без base — явно snapshot
  audit, не доказательство минимальности. Патч сохранён полностью, criteria не урезаются.
- Preflight до quota/model: наличие inputs/evidence/сохранённых check logs;
  настоящие Xcode fileRefs/Sources ожидаемого target, новые Swift после patch до build.
  Неизвестные layouts не считаются готовыми. Candidate/evidence/preflight включены
  в quality_contract; смена общего config требует нового run-id.

**Файлы:** tools/automation/orchestrator.config.json,
orchestration/{context,engine,preflight}.py,
tests/test_orchestration_{context,engine,preflight}.py, ORCHESTRATOR.md;
docs/parallel/README.md, throughput-audit-2026-11-10.md и этот handoff.

**Фактически запущено:**
- targeted `python3 -m unittest discover -s tools/automation/tests -p 'test_orchestration_*.py' -q`:
 106 tests/40.480s/OK на промежуточном срезе;
- финальный `python3 -m unittest discover -s tools/automation/tests -q`:
 **147 tests/48.177s/OK**, exit0. Модельные providers — scripted fixtures/fake CLI,
 Git commit/push внутри тестов — временные репозитории и local bare origin.
 Ожидаемые negative fixture FAIL/SKIP сообщения не являются падением suite.
 Проверены high-risk split gates, effort escalation, delta reuse при ambiguous counters,
 measured/turn/estimated rotation, timeout resume guard, committed candidate diff/
 скрытые paths/deletions, missing inputs/logs, read-only interruption, Sources/wrong
 target/одинаковые basename/cyclic groups/new file. Лог /tmp/narat-throughput-full-tests.log;
- `orchestrator.py validate --manifest tools/automation/tasks.example.json`: VALID1,
 без моделей; прямой read-only preflight настоящего pbxproj: все34Swift в нужных Sources PASS;
- JSON compare с HEAD: timeout/retry/sessions/roles/required_checks/scope_checks/checks/
 publish/acceptance unchanged; diff-check/local Markdown links/handoff markers PASS.
 Все151 checkbox совпадают с HEAD (15done/136open), продуктовые ID не закрывались.
 Staged whitespace проверяется перед commit; A/B wait_threads snapshot подтверждает idle.

**Ограничения:** live CLI/provider/SQL/iOS unit/UI/build/Simulator/Auth/Storage/AI/StoreKit
не запускались; ускорение и равенство качества на живой очереди пока не измерены.
Preflight проверяет включение исходника, не доказывает выполнение тестового метода;
прежние продуктовые gates нужны. Xcode checker поддерживает текущие явные PBX groups;
новые synchronized layouts требуют отдельной поддержки. Ограничение read_chars —
инструкция, а не жёсткий лимит вывода инструментов модели. Старые state/logs не правились.

**Точный следующий шаг:** сохранить и отправить этот пакет в origin текущей ветки.
Перед будущим запуском A принимает пакет, B получает ту же версию, оба переносят context/
preflight в свои ignored configs с сохранением собственных checks и publish.branch;
только новый run-id и по отдельной команде владельца на возобновление. Сейчас обе
очереди остаются на паузе. Прошлые pause checkpoints: A2aafbdd/Ba1e78c3.


## Пауза A/B и аудит скорости — 10 ноября 2026

Владелец отменил предложенное переключение очередей и прямо поручил остановить
оба оркестратора перед изменением конфигурации. Команда остановки передана в
Plants A и Plants B; оба управляющих чата её получили. A сообщила, что текущий
CLI-run уже завершён; B останавливает активный access HTTP run. Остановка подтверждена: повторный process inventory не обнаружил orchestrator,
model CLI, ios_gate/doctor/parallel checks, xcodebuild/xctest или Deno test процессов.
A run ci-b1-sql-acceptance — COMPLETED/done; B access-http run08 — WAITING/qa,
«Interrupted; child group stopped; resume explicitly». Полной HTTP-приёмки B нет. Автоматическое
возобновление запрещено до новой команды владельца; конфигурация не изменена.
GitHub Actions/дальнейшая CI-работа отложены, T006 остаётся открытой и не блокирует
MVP; локальные проверки сохраняются.

**Сделано:** аудит сохранённых state двух worktree: 42 A/7 B runs, 100/33 модельных
вызова, около361/135 модельных минут; Developer около82% суммарного модельного
времени. Восемь900s timeout — около120мин. Точные ограничения измерений и
предложения: [отчёт](validation/automation/throughput-audit-2026-11-10.md).
Счётчики CLI не позволяют пересчитать это в проценты подписочного лимита.

**Изменены:** новый отчёт throughput-audit-2026-11-10.md и JSON-агрегат,
docs/parallel/README.md (пауза), tasks.md (T006 отложена
без изменения checkbox), этот handoff. Это отдельная ветка
codex/development-throughput-audit от опубликованной main5d15123; текущие изменения
A/B сюда не переносились. Новый снимок не заменяет их локальные task reports.
**Проверки:** чтение state/metrics, live wait_threads snapshots, process inventory;
Markdown local links/JSON parse/diff-check — PASS; все151 checkbox совпадают с
HEAD (15done/136open). Новые product
suites, model calls и живые Auth/AI/Storage/StoreKit не запускались.

**Ограничения:** предложения ещё не применены; отчёт сохраняется отдельным
коммитом в origin/codex/development-throughput-audit, без публикации в main. **Точный следующий шаг:** сохранить pause checkpoints в A/B; затем согласовать
изменения конфигурации. До этого не запускать новые manifests/runs.

## История B checkpoint6d689b7 (до остановки, только evidence B)

Ниже сохранены B-specific секции; текущий приоритет — один A пилот, не указанная здесь старая очередь.

## B2 — SQL012 b44013e и согласованный nullable wire готовы для передачи A

SQL005–012 независимо приняты; обычный merge A main5d15123 сохранён93a54cf и
опубликован backend. Итоговые combined gates511pgTAP/99actual+6x20/cap4races,
Deno336/automation123/typecheck PASS (см. ниже), Swift B не запускала.
После run исправлены **только2draftfixture monthly.limit3→NULL** для
registration_required/history_unresolved; mode.limit3/100 сохранён. A явно
согласовала nullable DTO/коррекцию в сообщении10ноября. Обновлён статус HTTP
контракта: SQL005–012 принят, GET на независимой приёмке, installation HTTP далее,
live deploy отсутствует. Сами fixtures — ожидаемые метаданные, не fallback.

Файлы этого wire checkpoint: contracts/fixtures/monthly-access.json,
monthly-access-http.md и handoff. JSON/7canonicalexamples проверены локально,
unknown соответствует принятым SQL12 pgTAP. В рабочем дереве отдельно подготовлен
HTTP GET кандидат, **в wire checkpoint runtime GET не включается**; его39mocktransport
и336Deno PASS ещё не являются независимой приёмкой. Следующий шаг — отдельный
GET preparation commit и run08 с явным branchconfig, затем installation HTTP.
FullT163/T036/live/worker открыты, checkbox B не меняла.

## B — объединена опубликованная main5d15123 между runs

Обычный merge после завершения run07. Единственный конфликт — handoff: сохранены
новые B секции/оба task reports, новая история A/T162/CI; Project State согласован
по текущим фактам (15/151, accepted B SQL012, HTTP/T036/live open), не выбрана
вслепую сторона. Swift/CI приняты из опубликованного A SHA, вручную B не правились.
Итоговые B checks объединённого source PASS: SQL511pgTAP clean/upgrade+12UTC+99actual/6x20,
cap55+131pgTAP/4races, Deno336/0failed, deno-check, automation123/OK (38.609s),
diff-check. Логи `/tmp/narat-b2-main-merge-{sql,cap,deno,types,automation}.log`.
Только local fixtures; Swift/Simulator не запускались B. Далее обычный merge commit/
push backend, затем HTTP GET candidate. Согласование
A: unknown monthly.limit=NULL, mode.limit3/100; два draft fixtures исправить далее.

## B2 SQL11/12 приняты независимо — 10 ноября 2026

Run `parallel-backend-quota-api-sql-20261110-07` COMPLETED, оба среза опубликованы
в origin/codex/plants-backend. SQL11 принят6df1b76 (Developer/Reviewer/QA1/1/1,
без правок); SQL12: Developer оставил реализацию, добавил36 meaningful pgTAP
assertions (55→91), Review/QA PASS1/1. Оба run phase done, exit0.
Файлы011/012 и новые registration_installations/access tests, auto task reports.

**Реальные проверки:** credential gate clean/upgrade420pgTAP; финальный
`--bind --installations --access` clean/upgrade **511pgTAP** (55+49+78+89+113+36+91),
12UTC cases, все прежние public rows byte-equal. Перед каждым из6раундов20реальных
одновременно ожидающих соединений —99actual admit+finalize; replay/lastslot/failure/
terminalOnce PASS. Отдельный cap regression55+131pgTAP clean/upgrade+4realraces PASS.
Deno336/0failed, automation115/OK, deno-check/diff-check PASS в каждом срезе.
Reports `validation/automation/tasks/parallel-backend-t163-{installation-api-sql,access-snapshot-sql}.md`;
raw evidence в ignored run07/check dirs. Только fixtures, не live/deploy/Swift.

User разрешил external model workflow и координацию A; прежние rejection сняты
новым явным разрешением, исходная история сохранена. A согласовала additive wire,
включая **monthly.limit=NULL при unknown**, mode.limit3/100. Обнаружены два старых
draft fixture limit3: исправить после run, не принимать их как бизнес-правило.
Unknown legacy date fail-closed по подтверждению владельца. Parent T163/T036/API/
worker/live ещё открыты, checkbox B не меняла.

**Следующий шаг:** сохранить этот завершённый SQL этап → обычный merge конкретной
опубликованной A main `5d15123e1271f93e7575433d4a09f7f04612e64a` только между runs,
объединить handoff по фактам, не запускать Swift/Simulator в B. Затем поправить2fixture
null, подготовить production GET/strict DTO/protected transport gate и отдельный
bounded HTTP manifest/run08; следующим срезом register/bind HTTP, затем deno check
alias на реально существующие entrypoints. A сообщает T162 accepted local/fixture,
184unit/18actualUI/42PNG/Release/Simulator/SQL235/Deno336/automation123; это evidence
A, не тесты B. После merge сохранить факты и повторить затронутые B checks.

## B2 — разрешение получено, начинается независимый run07 (2026-11-10)

Владелец явно разрешил Developer/Reviewer/QA с передачей кода настроенным провайдерам,
commit/push только origin/codex/plants-backend и передачу технических отчётов в A.
Предыдущие approval rejection сохранены как история; блокировка разрешением снята.
A передан merge-ready **только bc6a879/runtime a367d0b (SQL005–010)**; tip4333509 с
SQL11/12 остаётся кандидатом. Запрошено подтверждение additive access wire; collection
wire не меняется. Последняя известная main72bcccc уже в B, активный HEAD не обновлять.

Дерево перед подготовкой чистое, config SHA256
`7b9b9b38d11cdc0227599a9b0b301c25472040280803cbc24394fd40c234e904` совпал.
Новый run `parallel-backend-quota-api-sql-20261110-07`, manifest
`tools/automation/tasks.parallel-backend-quota-api.json`, явный branch --config.
После сохранения handoff: validate/context → запуск011, затем012; старые runs не resume.
Фактические локальные checks кандидата475pgTAP/Deno336/automation115 описаны ниже;
новый run ещё не acceptance. После принятых SQL — HTTP production adapters и
строгие transport fixtures, затем A/T036/live; продуктовые checkbox остаются открытыми.

## B2 — SQL11/12 локально проверены; независимый workflow заблокирован approval

**Фактическая точка:** B1 принятый runtime a367d0b/сводка bc6a879, кандидат011 и
подготовка5c0d32d опубликованы. Теперь добавлен controller кандидат012 snapshot и
registration_access.test.sql. **SQL11/12 не приняты независимыми Developer/Reviewer/QA**.
Новые CLI/model calls не запускались, run06 state/answer нет: auto-review отклонил
запуск из-за отсутствия явного доверенного разрешения на передачу кода настроенным
модельным провайдерам и автоматическую публикацию. Отправка отчёта в A отдельно
отклонена из-за отсутствия явного разрешения на межчатовую передачу внутренних
сведений. Два async запроса разрешения ожидают ответа; обхода/повторной попытки нет.

**Сделано локально:**011 credential register/bind + private нормализация принятых010
starter правил;012 authoritative shared snapshot, unknown date/counts NULL,
current unresolved history blocks, nonoverlap old residue не блокирует, delayed
canonical reserve использует ledger window. GET не создаёт jobs/reserves/списание.
User подтвердил блокировку неизвестной legacy даты до verified Auth import.
Файлы: новые011/012 SQL, registration_installations/access pgTAP, controller gate,
bounded tasks.parallel-backend-quota-api.json и [отчёт](validation/automation/parallel-backend-quota-api-candidates-2026-11-09.md).

**Проверки фактического финального кандидата:** `python3 tools/automation/parallel_backend_quota_gate.py --bind --installations --access`
PASS clean/upgrade по475pgTAP (384 прежних+36installation+55snapshot),12UTC cases,
preexisting rows byte-equal. Шесть раундов по20 реально наблюдаемых ожидающих
соединений; перед каждым99actual admit+finalize, replay/last-slot/failure/exactlyonce.
`--anchors --legacy-guard --cap-regression` PASS55+131pgTAP clean/upgrade и4realraces.
Deno336/0failed, deno-check PASS; automation115/OK (37.811s), validate2/оба developer
context/diff-check PASS. Только synthetic/private localPG fixtures, не live.
Начальные SQL fixture FAIL: неверные monthly trial product/state; исправлены на
yearly/active/offer_kind trial, продуктовые constraints не ослаблялись. Логи всех
попыток сохранены; точные пути в отчёте. Старый shared t161 runner неизменён.

**Точный следующий шаг после явного разрешения:** новый
`parallel-backend-quota-api-sql-20261109-07`, manifest tools/automation/tasks.parallel-backend-quota-api.json,
явный config docs/validation/automation/runs/parallel-backend.config.json,
SHA256 `7b9b9b38d11cdc0227599a9b0b301c25472040280803cbc24394fd40c234e904`.
Routing/retry/budgets неизменны, publish только origin/codex/plants-backend.
Независимо проверить весь011, затем012; только после acceptance — production
HTTP access/installations + strict DTO/ENPL/real-client transport fixtures и
согласование wire с A. Пока TS forecast старый, adapters injection-only; fullT163,
T036, worker/job pipeline/live открыты, checkbox не менялись. Swift B не трогала.
Кандидатный checkpoint публикуется только в backend-ветку; A не передан как
merge-ready/accepted. Не resume старые runs и не использовать default main config.

## B2 — подготовлены credential SQL11 и bounded API SQL manifest

Controller материализовал кандидат011: private starter merge из принятого010,
register active guest/permanent owner + hash, atomic credential proof/bind. Изменены
новые011/registration_installations.test.sql, controller quota gate (`--installations`,
`--access` fail-closed при отсутствующем файле), новый tasks.parallel-backend-quota-api.json:
2 узких задачи011 credential RPC →012 authoritative snapshot. Это кандидат, не acceptance.

Реальный precheck `python3 tools/automation/parallel_backend_quota_gate.py --bind --installations`
PASS clean/upgrade по420pgTAP (384 прежних+36 новых),12UTC, preexisting rows retained,
99actual admit/finalize перед каждым6x20real-connection round. Лог `/tmp/narat-b2-installations-candidate.log`.
Validate2/developer context/diff-check PASS. Новые Deno/Review/QA выполнятся в run06;
012 ещё отсутствует, его gate не запускался/не объявлен PASS.

Branch config SHA256 `7b9b9b38d11cdc0227599a9b0b301c25472040280803cbc24394fd40c234e904`;
добавлены только два B gate checks, routing/retry/budgets неизменны, publish только
origin/codex/plants-backend. Новый run `parallel-backend-quota-api-sql-20261109-06`,
явный --config; старые runs не resume. До запуска сохранить preparation commit/push.
Следом реальный run06; после SQL12 — отдельные HTTP adapters+protected transport gate,
согласование additive wire с A. Неизвестная legacy дата блокируется по ответу владельца.

Передача отчёта в A автоматически отклонена: review не нашёл явного разрешения
пользователя на межчатовую отправку внутренних данных. Отчёт сохранён локально, не
обходили запрет. Async разрешение запрошено; это не блокирует локальную разработку.
B1 bc6a879 опубликован; fullT163/T036/live/worker остаются открыты, Swift B не трогала.

## B — SQL005–010 принят; следующий B2 authoritative API

**Принято и опубликовано:** reserve141d548, finalize42ed071, bind a367d0b.
Run05 COMPLETED; finalize Developer/Reviewer/QA1/1/1, bind3/2/1. Reviewer нашёл
преждевременное списание reserved+succeeded до nonbillable finalize: исправлено,
только quota_state consumed подтверждает расход, до settlement указатель блокирует.
113 binding regressions приняты. Истории timeout/rejected patch сохранены.

**Реально выполненные проверки:** `python3 tools/automation/parallel_backend_quota_gate.py --bind`
PASS clean/seeded-upgrade по384 pgTAP (55anchor+49ledger+78reserve+89finalize+113bind),
12UTC cases, preexisting public rows byte-equal. Шесть раундов по20 настоящих
PostgreSQL соединений, одновременно ожидающих owner lock; перед каждым99 actual
admit+finalize на synthetic jobs, last-slot/replay/technical failure/exactly once PASS.
Отдельный `--anchors --legacy-guard --cap-regression`: clean/upgrade55+131pgTAP,
4 реальные T161 races PASS. Deno336, automation115, deno-check/diff-check PASS.
Старый shared t161 --slots FAIL table-key equality из-за новых таблиц: не изменён
и не выдан за PASS. [Подробный отчёт](validation/automation/parallel-backend-quota-sql-acceptance-2026-11-09.md).

**Файлы завершённого среза:** новые009/010 SQL, registration_admission/bind pgTAP,
controller gate/manifest, task reports. Сейчас добавлены B1 сводка и B2 proposal
`contracts/monthly-access-http.md`, canonical expected fixtures/monthly-access.json,
уточнён monthly-access.md. Это предложение нового API, не работающий endpoint.

**Ограничения:** fixtures не live Auth/Supabase/Storage/provider/StoreKit. Swift/
Simulator B не запускала; full T163/T036/guest transfer/T153 открыты, checkbox не
менялись. Владелец подтвердил: неизвестную legacy дату блокировать до verified Auth
import, не угадывать по покупке/созданию guest. Production job/worker пока injection-only,
нельзя объявлять фиктивный202. Collection wire неизменён.

**Точный следующий шаг:** отдельный bounded `tasks.parallel-backend-quota-api.json`:
сначала credential register/bind RPC и authoritative SQL snapshot, затем реальные
production HTTP adapters/ENPL/transport fixture gates; новый run ID и явный branch
config, publish только origin/codex/plants-backend. B1 merge-ready a367d0b передаётся
A только как SQL prerequisite, без deploy/полного T163. A сообщила repository save/
resume193a704 (99Swift), это evidence A. Последняя согласованная main72bcccc уже
подхвачена B; новые integration SHA — только между B runs. Подготовку/сводку сохранить
обычным commit/push до запуска B2.


## B — run03: guard принят; reserve-кандидат восстановлен, run04 следующий

**Принято/опубликовано:** `a04794c` (guard007, 1 Developer/1 Reviewer/1 QA).
Команда `python3 tools/automation/parallel_backend_quota_gate.py --anchors --legacy-guard --cap-regression`:
clean/upgrade по55 anchor +131 T161 pgTAP,12UTC cases, четыре реальные owner-lock
гонки, все preexisting public rows сохранены;336Deno/115automation/typecheck/diff
PASS. Точный отчёт: `docs/validation/automation/tasks/parallel-backend-t163-legacy-state-guard.md`.
Ограниченный accepted пакет005/006/007 разрешён A для интеграции, без deploy и
без закрытия T163/T164/T036. Ранее найденный permanent legacy NULL-anchor flip закрыт.

**Точка остановки run03:** reserve вернул патч только008+test, но fingerprint
имел74 символа вместо ожидаемых64 (дублирование подстроки). Provider правильно
отклонил ответ: WAITING/cli_error, settlement PENDING. Исходные answer/state/metrics
не менялись и не выданы за принятие. Raw answer SHA256
`de0ac185a94bff6a88cace5b273c460bed3089d11c625cb6852d3398d829a897`.
Путь: ignored `docs/validation/automation/runs/orchestrator-parallel-backend-quota-sql-20261109-03/parallel-backend-t163-reserve/call-1-developer/answer.json`.

**Восстановлен кандидат, ещё не принят независимо:** scope/git apply --numstat/
--check подтвердили только `202611090008_quota_reservation.sql` и
`registration_reservation.test.sql`. Контроллер исправил синтаксис PL/pgSQL BEGIN;
и ошибочное ожидание теста B: его fixture уже содержит два расхода; теперь
проверяется **admitted=true и remaining=0**, отказ не может дать ложный PASS.
В controller gate добавлена печать failing TAP diagnostics до удаления temp DB.
Другие функции/миграции005–007 не переписывались.

Реальный `python3 tools/automation/parallel_backend_quota_gate.py --reserve`:
**PASS** clean/upgrade по78 reserve +55 anchor +49 ledger pgTAP,12UTC cases,
четыре раунда по20 одновременно наблюдаемым PostgreSQL соединениям (distinct/same
job), один reserve и replay без нового ledger. Лог `/tmp/narat-b163-reserve-recovery-v4.log`.
Это reserve-only с99 историческими consumed fixtures, **не settlement и не полная
T163**. До исправлений честные FAIL сохранены в `/tmp/narat-b163-reserve-recovery{,-v2,-v3}.log`.
Deno для008 ещё впереди в независимом run04; предыдущие результаты не подменяют его.

**Интеграция между runs:** после завершения run03 выполнен обычный FF merge
`72bcccc` из опубликованной A main; untracked reserve-кандидаты сохранены.
A проверила итоговый `947d602`/docs72bcccc:55Swift/0skip/build/welcome/Simulator,
336Deno/typecheck,115automation и clean/upgrade55+49+131pgTAP/12UTC/4races,
fingerprint63025c67bcf86dec2b30d6a4da4b53192aa0313a00bc1c698ad80b3a972a4ae8 стабилен.
Это evidence A; B Swift/Simulator не запускала и Swift вручную не редактировала.
UI/Auth wiring/durable ACK/repository/save и полныеT162/T163/T164/T036/live открыты.

**Следующий шаг:** candidate checkpoint commit/push, затем новый
`parallel-backend-quota-sql-20261109-04` с
`tools/automation/tasks.parallel-backend-quota-reserve-recovery.json` (2tasks):
независимые Developer/Reviewer/QA для конкретного008 →settlement009. Validate2,
developer context и diff-check PASS; новый config не нужен, прежний branch config
SHA256 `59ed00ee3315c8db379677e7aa0ef1558cc7b9be590b64f626d9cf3f043e31ff`, publish
только origin/codex/plants-backend. Run03 не resume; исходный malformed ответ не
исправлять. После009 — полный99actual admit/finalize +6x20 gate и отдельный B2 API.
Auth/Supabase/Storage/provider/StoreKit live не запускались; продовые job/worker
adapters пока не подключены. Продуктовые checkbox B не закрывала.

## История обновления 8b2c637

## Подготовка и отчётность очередей — 11 ноября 2026

`prepare` за одну команду проверяет manifest, ветку публикации, входы и Xcode Sources
готовых к старту задач. Она выводит выбранные проверки и начальные роли. Branch config
используется повторно. Новые входы сохраняются локальным коммитом, который отправляется
вместе с принятым пакетом. Проверки пакета выполняются внутри очереди.

`summary` читает сохранённый state и показывает результат, причину остановки,
время, повторы, тайм-ауты, коммит и логи проверок. Engine записывает длительность
каждого вызова очереди и добавляет замеры моделей и проверок в отчёт и Task Summary
при публикации. При остановке controller использует готовую сводку и дописывает следующий шаг.

Изменены `tools/automation/orchestrator.py`, `orchestration/{engine,metrics,reporting}.py`,
`tests/test_orchestration_engine.py`, `ORCHESTRATOR.md`, `docs/parallel/{README,session-ios,session-backend}.md`
и этот handoff. Политика обязательных проверок берётся из текущего config и manifest.

Проверки. `python3 -m unittest discover -s tools/automation/tests -q` — **148 тестов PASS**
за 45.712 с. В тестах используются фиктивные модели и локальный Git. `prepare` на
`tasks.example.json` с конфигурацией текущей ветки — PASS, 0.119 с. `summary` на
сохранённом пилоте B — PASS, SHA-256 исходного state совпал до и после. `git diff --check`
и сверка checkbox — PASS, 15 из 151. Живые очереди и продуктовые интеграции для этого
этапа не запускались. Экономию общего времени предстоит измерить на следующем пакете.

Следующий шаг перед запуском A/B — перенести опубликованный коммит в обе ветки,
использовать `prepare`, а после запуска взять время и статус из `summary`.


## Один пилот A/B выполнен; оба снова остановлены — 10 ноября 2026

По прямой команде владельца engine25a5830 перенесён обычными merge в A/B, context6/
read16000/preflight добавлены в собственные configs без смены providers/checks/budgets/
publish branches. В каждой сессии запущен **ровно один** следующий product task,
оба **COMPLETED / exit0**. Не было второго run, external repair, CI-работы,
main promotion, deploy/live. Подробные замеры/границы сравнения:
[пилот](validation/automation/throughput-pilot-2026-11-10.md),
[JSON](validation/automation/throughput-pilot-2026-11-10.json).

**A:** accepted e04103f, T036 DTO/realAPIClient transport в трёх Swift-файлах,
без repository/UI/billing и полного T036. Подготовка441.566s, runtime935.649s;
Developer Sol medium630.584s, Astra high Review81.336s/QA101.714s,
checks114.201s. Diff/build/welcome/191unit (184+7,0skip/expectedfailure)/Simulator
и независимые Review/QA PASS. **B:** accepted88a8ea8, read-only snapshot GET access,
исходникa151427 не менялся; prep322.843s, runtime249.722s, Dev0,
Astra high Review93.515s/QA74.125s, checks74.120s. HTTP39/Deno336/automation147/
typecheck/diff/SQL511 clean+upgrade/12UTC/99actual+6x20/cap55+131+4races PASS.
У обеих repeats/repair/re-review/timeout0. B final docs123c123; A final docsf343f83. Оба чата idle, деревья чистые.
Полное время turns A1902.765s/B1030.900s; после runtime до final report push
A488.842s/B350.923s. Подготовка и отчётность отделены от runtime.

**Что изменилось здесь:** два сводных артефакта пилота (.md/.json), README двух
сессий и этот handoff. Продуктовый код остаётся в опубликованных ветках A/B;
в root/main автоматически не объединён. Tasks checkbox не менялись:15done/136open,
T006/T036/T163 и live parents открыты. Runtime/source/task reports A/B сохранены.

**Проверки этого этапа:** read-only state/calls/process/timing, ровно1newruntime
на lane относительно предыдущего аудита; source engine/defaultconfig A/B точно
25a5830; CI diff обеих веток пуст; все151checkbox A/B совпали с их initial HEAD.
JSON sums/5model replies/10checks PASS, repeat checks0, quality_contract baseline
разные; Markdown local links/diff-check PASS. origin refs подтверждены: iOSf343f83,
backend123c123, main5d15123 без изменения. Staged whitespace проверяется перед commit. Здесь новые product suites не запускались;
реальные локальные проверки дочерних run перечислены выше. Все интеграционные
результаты относятся к fixtures/privatePG/mock transport, не live Auth/Storage/AI/
StoreKit и не готовности полного пользовательского пути.

**Вывод/ограничения:** оба пакета прошли с первой попытки, лишний Dev B устранён;
причинное ускорение не установлено. A всё ещё10:31Developer; подготовка/отчётность
существенны. B Reviewer93.515s медленнее старого77.672s; baselineQA прервана,
quality_contract разные. Процент экономии/квоты не вычислялся. Подробности старых
попыток сохранены отдельно от raw state; elapsed=null не переписывался.

**Точный следующий шаг:** оценить опубликованные измерения с владельцем.
Обе очереди остановлены; никаких следующих пакетов/CI/main merge без новой команды.
Следующая продуктовая работа: A repository/UI T036 по принятому wire; B installation/
bind HTTP и последующая общая/live приёмка. Сами задачи пока не закрывать.


<!-- orchestrator:project-state -->
## Project State

- 11 ноября владелец возобновил A/B. Текущая цель A: галерея → реальный вид/вероятный диагноз или неопределённость на тестовом стенде. Сначала локальный сценарий, затем согласованный upload/job/status, итоговая сборка и два живых фото. Предыдущая остановка после пилота относится к 10 ноября.

- B6d689b7 prerequisite перенесён только для одногоT036 wireпилота: SQL005–012 acceptedB, agreednullmonthly.limit/counts, HTTPcandidateexcluded. Нет нового A SQLintegration/CI/mainpromotion.

- ПРИОРИТЕТ STOP после одногоPILOT10Nov: T036DTO/transport e04103f COMPLETED (191unit/Simulator/AstraReviewQA), prep441.566/runtime935.649s,1/1/1calls/0repeat/timeout. После принятия сноваSTOP; noCI/no main/no secondruntime/externalrepair. Config6bd5008b/engine25a5830 сохранены, ждать владельца.

- B authorization10November confirmed; previousB1integrated6a83f0e/CIextension6bef677 accepted beforepause; nowexactB6d689b7 SQL005–012+agreednullablewire перенесён для одногоDTO/transportпилота, lateHTTPcandidateexcluded. CIadapter/mainpromotion отложены; T036/productionAPI/live open.

- Narat: Swift 6/SwiftUI/SwiftData, Supabase, StoreKit 2, EN/PL; конституция 5.0.0.
- Scope принят 9 ноября: простой путь и уход, OPEN-PLAN разрешён; документы не подтверждают runtime.
- 151 задача: 15 отмечены (12 исторических + T156 документ + T161 серверный пакет + T162 клиент), 136 открыты; 23 снятых. Из открытых T172–T174 — отдельные необязательные комнаты; пакеты T161–T174 описаны в orchestrator-cleanup-tasks.md, T161 принят по серверному контракту: cap b5f2c8f, slots 01ba170, TS/API eb58c03; fixtures PostgreSQL/Deno, live/client отдельно. Остальные manifests/gates готовятся перед запуском. T155/T157–T160 открыты; T148 остановлена перед pipeline slice.
- Runtime AI классифицирует, советы из проверенных карточек. Sync/outbox, история/приватность/покупки сохранены. Free collection cap=3/no-slot basic care приняты; SQL005–012 monthly acceptedB перенесён как wireprerequisite, HTTP/clientT036/expiry/live открыты.
- T157 question-bank f15e6c6 и follow_up a97ff20 опубликованы (COMPLETED). Score/DTO 31a465f и evidence e2a446d опубликованы. SQL mode guard bd481a9 опубликован: clean/upgrade по 50 pgTAP PASS, history unchanged. Компактные Condition2/Plant2 e7d2d7b/eb40f28 опубликованы: 257 Deno PASS. Три неиспользуемые Swift DTO удалены в 93d77bc: 27 PlantsTests/build/welcome/Simulator PASS. Rooms run-02 COMPLETED: SQL b80a74e и клиент 0d8d4ee опубликованы; clean/upgrade по 66 pgTAP + real owner-lock retry, 259 Deno, 28 PlantsTests/build/welcome/Simulator PASS. Run-01 WAITING по timeout без patch сохранён. Серверная T161 и клиентская T162 приняты в fixture scope; квоты T163 и полный expiry T164 отдельно. T168 client estimator slice dadfcb1 принят (29 PlantsTests/build/Simulator, Sol combined); full T168 server/API guards остаются открыты. PostgreSQL17/pgTAP доступен. Guest claim baseline несовместим с таблицами/API: не объявлять положительный перенос проверенным, исправление T159. Остальная T157/T158–T160 открыта; T148 независима. Применённые миграции не переписывать.
- Оркестратор: простые low/low задачи проходят все checks и одну совмещённую Review/QA на Sol; высокий риск/сложные или повторные замечания — Astra. Resume известной сессии передаёт delta/errors; свежая сессия — полный контракт. Metrics включает все повторы на COMPLETED и сравнивает только одинаковый quality_contract. 123 automation fixtures PASS; live CLI cap/SQL Astra split, TS Sol split и T168 Sol combined приняты, экономика одинакового контракта не измерена. Для нового config нужен новый run-id.
- Auth/profile 9551807, production sync c26a4e0/catalogue create 88345ed и typed receipt e8a12fe приняты. Receipt принят e8a12fe; canonical sync DTO/transport A1 принят 7cb5893 (43 tests/Simulator/Review/QA). A2 canonical engine/disk принят 643622b (49 tests/Simulator/high-risk Review/QA), после исправления null encode и failed-save contexts; durable receipt store 09e9b3a и engine ACK 22bc1a6 приняты(64 tests); capacity/preflight2efd83a принят(72 tests), outbox identity/typed errors1eb80cc принят(79 tests); catalogue journal5997c0d принят(89 tests); repositorysave193a704 принят(99 tests); inputcheckpointf53227b принят(109 tests); owner-fixed model8ba18e1 принят(124 tests); SDKsource68d3e46 принят(137 tests); native helper0a9f2ea принят(150 tests); DEBUGfixture98b2010 принят(158 tests); cardhelper17d70f8 принят(167 tests); UIbinding9b86251 принят(179 tests); views0bb8d21 и actual16UI dbd3b14 приняты(16UI/32PNG/179unit/123automation/Release/Simulator/ReviewQA); slot0016576 принят(183tests/SQLite/Simulator/ReviewQA); ACK/pointerrepair91349a1 принят(184unit/18UI/42PNG/123automation/Release/Simulator/ReviewQA); finalacceptanceT162532984c принята(184unit/18UI/42PNG/336Deno/123automation/SQL/Release/Simulator/ReviewQA),T162[x];liveparentsоткрыты. Широкий run timeout без patch сохранён; capacity run01 context mismatch/interrupted, run02 read-only PASS.
- Владелец поручил подготовить два оркестратора: docs/parallel/README.md, session-ios.md (A=59 ID) и session-backend.md (B=78 ID), allocation.json фиксирует137исходнораспределённыхID;послеT162открыты136(A58/B78). A worktree/ветка codex/plants-ios создана от 4bbd35a; подготовка f4a67ad опубликована. A1 run-01 WAITING: два невалидных diff, третий вызов прерван; кандидат call-2 восстановлен изменением только diff-разделителя, затем принят в run-03. Run-02 compile failure сохранён; run-03 COMPLETED 7cb5893 с полной приёмкой A1 (43 tests); A2 run-01 timeout/raw diff сохранён; run-02/03 FAIL оставлены в истории. Run-04 COMPLETED 643622b,49tests/Simulator/Review/QA; durable receipt store 09e9b3a COMPLETED 55tests; далее mergeB a04794c→engine ACK→repository/UI. B подтвердила запуск; a04794c разрешён для ограниченного merge. Интеграция947d602/72bcccc была опубликована; новая принятая iOSintegration7502bee опубликована mainобычнымpush, fingerprintf7cdd858/1488files,158Swift+SQL+Deno/115automation/SimulatorPASS; срезcard/binding/views/slots/ACKпринят532984cиподтверждёнвmain277d97f,sourceSHA d02fa14d/1505files;далееT006CIconfigurationподготовка(2controllerhelpers/ownconfig/workflow-onlymanifest),remoteнепроверен. A: клиент T162 wire→disk→save и интегратор; B: T163 quota SQL/API→guest/контракты. Свои ветки/publish config обязательны; общий Simulator только A. T172–T174 не входят в текущий запуск.
- B prerequisite a04794c объединяется:005 immutable registration anchors21ee7a7,006 ledger e6b1f7c,007 legacy state guard. ПолныйT163/новые reserve/settlement/B2 и клиентT036 ещё открыты; unknown legacy registration fail-closed подтверждён владельцем. Collection wire не менялся. Объединённые SQL/Deno/115automation/55Swift/Simulator gates PASS, fingerprint63025c67; docs-only main6a9584d сохранён, main 947d602 опубликован; live/deploy нет.
- Реестр запуска из main6a9584d сохранён: A chat01a1c14d-187a-7d91-ac6d-62ae00ec6104, B chat01a1c14d-2b1b-7673-83c4-c95f6fe7f7c1, host local, отдельные worktree/ветки; allocation.status=sessions_started.
- Handoff/tasks/Git изменяет только управляющий процесс; в параллельных worktree каждый controller обновляет собственный handoff, A объединяет факты и итоговые tasks. Fixtures ≠ live; снятый объём не выполнение. Задания A/B разрешают существующий Developer/Reviewer/QA workflow; дополнительные деревья субагентов на старте не запускаются.
<!-- /orchestrator:project-state -->

<!-- orchestrator:task-summary -->
## Task Summary

parallel-ios-t165-sync-compatibility: проверки и Review/QA пройдены; публикация фиксируется в state.
Вызовы — reviewer 1, qa 1. Модели — 177.05 с, проверки — 109.18 с. Повторы моделей — 0, тайм-ауты моделей — 0, тайм-ауты проверок — 0.
Отчёт: [parallel-ios-t165-sync-compatibility](validation/automation/tasks/parallel-ios-t165-sync-compatibility.md).
Продуктовые checkbox не менялись автоматически. Следующий шаг — следующая независимая задача manifest.
<!-- /orchestrator:task-summary -->
