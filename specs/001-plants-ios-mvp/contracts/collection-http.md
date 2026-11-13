# Collection HTTP — catalogue plant.create и GET /sync (T019/T044/T162, узкий срез)

Production entry point: Deno.serve(createProductionPlantsApiHandler()).
Поддержаны существующие пути /sync, /plants-api/sync и /functions/v1/plants-api/sync;
новый /v1 prefix этим срезом не добавляется. Bare createPlantsApiHandler()
сохраняет T152: sync/commands без явно переданного handler возвращают 503.
Явные delegates и остальные endpoints сохраняют поведение. Production factory
подключает sync и только catalogue plant.create. Остальные commands не включены.

## GET /sync: доступ и запрос

Существующая проверка Supabase Auth → active profile выполняется до query/RPC.
Постоянный и anonymous active owner допускаются. p_owner_id берётся только
из проверенного контекста. Query owner/user/p_owner_id и любые неизвестные параметры
отклоняются; headers/body не служат источником owner.

Принимаются только уникальные since, until, limit, cursor_updated_at,
cursor_entity_type, cursor_id. Даты — календарно корректные ISO timestamps:
YYYY-MM-DDTHH:mm:ss[.1–6 цифр]Z или числовой offset ±HH:mm (диапазон PostgreSQL
до 15:59); обязательна timezone. Даты передаются без переформатирования,
сравнения учитывают микросекунды. since <= until, limit — целое 1…500
(по умолчанию 200). Отсутствующие timestamps/cursor передаются SQL NULL.
Исключение — limit: передаётся 200, поскольку явный SQL NULL снимает LIMIT,
а не включает default аргумента.

Cursor — полная тройка timestamp/entity_type/UUID; для него обязателен
фиксированный until. since < cursor_updated_at <= until, если since задан.
Допустимые entity_type соответствуют текущему owner_sync_entries:
plants, condition_snapshots, photo_assets, analysis_summaries, care_plan_summaries,
care_tasks, care_entries, care_reversals, schedule_changes, basic_care_memberships,
first_aid_followups, care_observations, recovery_transitions,
notification_claim_summaries. Повторы, частичный cursor, некорректные/чужие
параметры дают 400 VALIDATION_ERROR до создания privileged client/RPC.

## Авторитетный SQL wire

Источник — fetch_sync_delta и owner_sync_entries из
202611090004_retire_free_slots.sql (после retirement rooms).
RPC POST /rest/v1/rpc/fetch_sync_delta, ровно аргументы:
p_owner_id, p_since, p_until, p_cursor_updated_at, p_cursor_entity_type,
p_cursor_id, p_limit. Server-only client использует service-role Authorization/apikey;
JWT пользователя используется отдельным существующим Auth/profile client.
Права RPC ограничены service_role миграцией 202611060002_service_rpc_permissions.sql.

HTTP 200 возвращает исходный JSONB result без DTO-переименований/подставленных полей:

- until: SQL timestamp; без p_until берётся profile.updated_at, не часы Edge.
- has_more: boolean.
- last_cursor: при has_more объект
  {since: timestamp|null, until: timestamp, updated_at: timestamp, entity_type: string, id: UUID};
  иначе null.
- next_since: null на промежуточной странице, until на последней.
- profile: {preferred_locale, reminder_hour_local,
  report_notifications_enabled, trial_reminder_enabled}.
- entitlement: null либо {product_id, state, offer_kind, valid_until,
  grace_until, trial_end_at, auto_renew_enabled}; nullable даты сохраняются.
- changes: массив {entity_type, id, updated_at, deleted_at, data}.
  Живой data — исходный объект проекции SQL; tombstone имеет deleted_at и data=null.

Порядок SQL — updated_at/entity_type/id, since исключающий, until включающий.
Следующая страница повторяет since/until и тройку из last_cursor; после последней
страницы следующий delta начинается с next_since, без старого cursor/until.
Profile/entitlement возвращаются и при пустом changes. Adapter не фильтрует,
не сортирует, не создаёт cursor/watermark, не удаляет tombstones, не добавляет
owner_id/items/payload_json/limit/server_watermark и не восстанавливает retired slots.
Проверяется форма envelope/profile/entitlement/changes и согласованность pagination;
невалидный/null result закрывается 503, без попытки «исправить» ответ.

## Ошибки и границы проверки

После Auth/query проверки конфигурация SUPABASE_URL/SUPABASE_SERVICE_ROLE_KEY
читается лениво; отсутствующая/пустая/некорректная service-конфигурация даёт
503 INTERNAL_ERROR, retryable=true. SQL owner_forbidden (42501) → 403 FORBIDDEN;
ошибки параметров 22007/22008/22023/22P02 → 400 VALIDATION_ERROR.
Прочие SQL/transport/JSON/result ошибки → 503. Сообщения общие EN/PL,
raw SQL/network errors и ключи не попадают в response. Auth/profile mapping
срезом не изменён. Health/OPTIONS не читают service-конфигурацию.

collection_http_test.ts использует production factory, реальные Supabase
clients и mocked HTTP transport/config: Auth/profile guards, точные RPC URL/body/
headers, owner A/B, страницы/tombstones/микросекунды, валидация, ошибки и fallbacks.
Это fixtures, не выполнение SQL, live/deploy или end-to-end client sync.
Проверки запускает контроллер после применения patch.

Swift SyncPageDTO пока ожидает owner_id/items/next_cursor/server_watermark/limit;
SyncItemDTO — payload_json, тогда как SQL возвращает changes/data и last_cursor.
SyncCursorDTO не хранит since/until, а клиент должен сохранять окно между
страницами. Клиентский JSONDecoder использует .iso8601; поддержку SQL timestamps
с дробными секундами/offset и точность watermark ещё необходимо адаптировать
и проверить. HTTP query names уже совпадают со Swift; response совместимость
не заявляется. SwiftData/outbox, UI, live sync и полные T019/T044/T149/T162
остаются открытыми; миграции/клиент этим срезом не меняются.

## POST /commands: catalogue plant.create

Те же три prefix, что у /sync; новый /v1 не вводится. Существующий Auth/profile
resolver сохранён. Требуется permanent active owner: нет сессии → 401;
anonymous либо неактивный/отсутствующий profile → 403 до разбора команды/RPC.
Sync по-прежнему допускает active anonymous owner; positive guest claim не включён.

Canonical Swift CommandEnvelopeDTO wire — operation_id, command_name,
payload_json. payload_json — **строка**, внутри которой закодирован JSON object,
не вложенный JSON object, не command_type/payload. Минимальный запрос без фото/опроса:

```json
{
  "operation_id": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
  "command_name": "plant.create",
  "payload_json": "{\"creation_source\":\"catalogue\",\"plant_id\":\"fixture_collection_cap\"}"
}
```

operation_id — UUID. Если X-Operation-Id передан, он тоже должен быть UUID
и совпадать с operation_id без учёта регистра; несовпадение → 409 CONFLICT.
Header не заменяет обязательный operation_id. Envelope plant_id для create
может отсутствовать или быть null (опциональный Swift target); непустой target
отклоняется. Неизвестные envelope поля и любые query параметры → 400.

Payload требует creation_source="catalogue" и species selector plant_id
(строковый slug каталога) либо taxon_id (UUID), в том числе в overrides.
Это не UUID нового экземпляра: экземпляр создаёт SQL.
Допустимые optional поля: personal_name/display_name (string|null),
taxon_id/plant_id, origin_flow_id (UUID|null), photo_id (только null),
creation_intent ("care"|"problem"), add_method ("catalogue"), conditions, overrides.
Фото не требуется. Ненулевой photo_id отклоняется до RPC: текущий SQL не проверяет
owner main_photo_id при INSERT; attachment требует отдельной authoritative проверки.
conditions/overrides — объекты; overrides дополнительно допускает species/names.
Условия — существующие SQL light_level/light_code, light_source ("manual"|"unknown"),
light_confirmed (boolean), watering_habit/watering_code, last_watered/drainage_code,
pot_type; nullable значения сохраняются. Коды соответствуют существующим SQL CHECK.
Ввод camera_estimate и season_override не включён; историческая sync data сохраняется.
Пустые conditions/overrides допустимы. Семантические ограничения SQL остаются
authoritative. Owner/user/p_owner_id, rooms, origin_draft_id/analysis_receipt,
local_fallback/guest/identification source, клиентский plan_availability и
неизвестные поля запрещены на всех принимаемых уровнях до RPC.
Unsupported/retired команды → 400, без вызова другого RPC.

Production factory лениво создаёт server-only service-role client из
SUPABASE_URL/SUPABASE_SERVICE_ROLE_KEY и вызывает ровно:

```text
POST /rest/v1/rpc/execute_plant_create_command
{ p_owner_id: authenticatedContext.ownerId, p_operation_id: envelope.operation_id,
  p_payload: JSON.parse(envelope.payload_json) }
```

p_now не задаётся. После валидации payload передаётся без добавления defaults,
переименования, удаления null, trimming значений или вычисления hash. SQL владеет
лимитом/транзакцией/hash/receipt. Повтор отправляет те же operation/payload в SQL;
adapter не создаёт receipt/replay флаг/plant/watermark.

HTTP 200 — исходный canonical JSONB receipt из execute_plant_create_command
(202611090002_retire_rooms.sql), например:

```json
{
  "plant_id": "22222222-2222-4222-8222-222222222222",
  "care_revision": 1,
  "context_state": "current",
  "next_available_step": "enable_basic_care",
  "paid_action": "generate_full_routine_plan",
  "plan_availability": "available",
  "watermark": "2026-11-03T09:00:00.999999+00:00"
}
```

SQL может вернуть другой next_available_step/plan_availability и paid_action=null.
Required validation: plant_id UUID, care_revision положительное safe integer,
context_state/next_available_step/plan_availability непустые строки,
watermark корректный SQL timestamp. Все поля сохраняются losslessly.
Null/unexpected result → 503; пустой успех не подставляется.

COLLECTION_LIMIT_REACHED (P0001) → HTTP 409 COLLECTION_LIMIT_REACHED,
retryable=false; это отдельный collection cap, не QUOTA_EXHAUSTED анализа.
23505 / operation_payload_mismatch → 409 CONFLICT; header mismatch также 409.
owner_profile_not_found (P0002), account_not_active/owner_forbidden (42501) → 403.
taxon_not_published (P0002), SQL parameter/constraint codes
22007/22008/22023/22P02/23502/23503/23514 → 400 VALIDATION_ERROR.
Прочие SQL/transport/config ошибки, включая serialization/deadlock, → 503
INTERNAL_ERROR, retryable=true; повтор сохраняет operation/payload.
Все сообщения EN/PL общие: raw error/details/hint и service credentials не возвращаются.
Lookup/retry/cap порядок остаётся текущим SQL; HTTP fixtures не заменяют DB gate.

## Клиентская адаптация и проверки

CommandResponseDTO сейчас требует status/operation_id/replayed, отсутствующие в SQL
receipt. Нельзя объявлять текущий Swift save совместимым или добавлять эти поля
в Edge как фиктивное подтверждение. Следующий клиентский шаг: отдельный DTO реального
create receipt, безопасное подтверждение outbox по успешному SQL ответу, mapping
COLLECTION_LIMIT_REACHED с сохранением ввода, затем save UI и проверка клиента.
Требуется также описанная выше адаптация SyncPageDTO/cursor/SQL timestamps.

collection_http_test.ts расширен без удаления sync assertions: production composition
с mocked HTTP transport, exact create/retry RPC args/receipt, cap/conflict/errors,
owner isolation, permanent-owner boundary, validation, config и explicit delegates.
Это fixtures; отдельно контроллер запускает неизменённый SQL cap/history/retry/
concurrency gate в изолированном PostgreSQL. Live, guest claim, UI, клиентский
save/outbox и полный объём T019/T044/T149/T162 этим срезом не принимаются.

## POST /commands — plant.edit (V10, целевой контракт T069/T070/T071)

Локальный серверный срез принимает ровно один ключ верхнего уровня: `personal_name`, `conditions` или `taxon_id`. Смешанный запрос возвращает 400 целиком. Используется тот же `/commands`, что у `plant.create`, с Auth постоянного активного владельца.

```json
{
  "operation_id": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
  "plant_id": "22222222-2222-4222-8222-222222222222",
  "command_name": "plant.edit",
  "payload_json": "{\"personal_name\":\"Living room Monstera\"}"
}
```

`plant_id` в envelope — UUID экземпляра. Внутри `payload_json` допустимы только следующие поля. Пропущенные поля сохраняют текущее значение. Нужен хотя бы один ключ для правки.

- `personal_name` — строка длиной 1–120 символов после удаления пробелов по краям. Она обновляет оба поля имени экземпляра.
- `taxon_id` — UUID вида или гибрида из действующего опубликованного каталога. Сервер одновременно обновляет UUID таксона и его каталожный slug, сохраняет личное имя и переносит текущие значения условий в новый snapshot. Регистр UUID не влияет на replay. Повторный выбор текущего канонического таксона сохраняет ревизии.
- `conditions` — непустой объект частичной правки. Значения строковые. Для явного сброса используется `unknown`.
  - `light_code` — `low`, `medium`, `bright_indirect`, `direct_sun`, `unknown`. При явном изменении освещения сервер выводит `light_source` и `light_confirmed` из выбранного значения. У `unknown` это `unknown` и `false`, у остальных значений — `manual` и `true`.
  - `watering_code` — `several_weekly`, `weekly`, `less_often`, `frequent`, `moderate`, `sparse`, `unknown`.
  - `drainage_code` — `yes`, `no`, `unknown`. Исторические значения сохраняются при пропуске поля.
  - `pot_type` — `terracotta`, `plastic`, `glazed_ceramic`, `standard_drainage`, `other`, `unknown`.

Коды берутся из SQL wire. Например, Swift `LightLevel.brightDirect` кодируется как `direct_sun`. Старые данные читаются из sync. Попытки записать фото, комнату, camera estimate или сезонное переопределение возвращают 400. Сервер сохраняет исторические значения вне поля правки.

```json
{
  "plant_id": "22222222-2222-4222-8222-222222222222",
  "revision": 3,
  "care_revision": 2,
  "condition_snapshot_id": "33333333-3333-4333-8333-333333333333",
  "watermark": "2026-11-13T18:30:00.123456+00:00"
}
```

HTTP 200 возвращает текущие ревизии, UUID актуального snapshot или `null`, и watermark. Повтор той же операции возвращает исходную квитанцию. Повтор ID с другими командой, экземпляром или содержимым и несовпадение с опциональным `X-Operation-Id` дают 409 `CONFLICT`. Неизвестный, чужой и удалённый экземпляр дают 404 `NOT_FOUND` для новой операции. Некорректный запрос, неподдерживаемый таксон и query-параметры дают 400. Без сессии — 401, anonymous и неактивный профиль — 403, ошибка сервера — 503 с `retryable=true`.

Под блокировкой владельца и экземпляра реальная правка увеличивает `revision`. Имя само по себе сохраняет `care_revision`, snapshot и расписание. Изменение вида или базовых условий увеличивает `care_revision` и создаёт новый snapshot, сохраняя предыдущий. Новый snapshot при изменении одного вида отделяет исходный анализ даже при последующем возврате к прежнему виду. Анализы и их исходные связи сохраняются. Опубликованные summary устаревшего контекста получают `context_state=stale`. Старый first-aid action и его незавершённый контроль теряют применимость. Для неприменимых будущих правил и открытых задач требуется пауза, выключение напоминаний и проверка, что reconciliation или ручная запись их не возобновляют. История завершённых задач, ручные записи, основное и контрольные фото сохраняются. Эффективно пустая правка возвращает квитанцию без новых ревизий или snapshot. Срез условий ставит `rule_state=paused` для правил со старым контекстом и выключает reminders открытых задач по ним. Прежний незавершённый first-aid control становится `superseded`. Исторические snapshots и связи анализов сохраняются. Текущий API диагноза сохраняет исходный результат, а `analysis_summaries` отражает `stale`. Команда не запускает AI.

Ответ подтверждает SQL-коммит. Клиент дочитывает owner delta до `until >= watermark` и использует присланные SQL ревизии и snapshot. Явное обновление рекомендаций из пригодных данных проверяется отдельно. Проверки реализации включают сохранность исторического snapshot и фото, 400/404/409, replay, отсутствие нового анализа и паузу будущих задач после правки вида и условий.

### Явное обновление базовой рекомендации после plant.edit

Проект отдельной команды `care.recommendation.refresh` через существующий `POST /commands`. Текущий `GET /plants/{id}/care/recommendation` читает опубликованный профиль, показывает обоснованный совет и возвращает `next_check: null`, пока действует пауза. Команды обновления в текущем Edge нет.

Запрос использует UUID экземпляра в `plant_id`, UUID операции в `operation_id` и `payload_json: "{\"expected_care_revision\":2}"`. Владелец берётся из Auth. Под блокировкой владельца и карточки SQL проверяет receipt, затем актуальность care revision и snapshot. Чужая, удалённая или отсутствующая карточка даёт 404. Устаревшая ревизия либо изменённый payload для того же operation ID дают 409. Точный повтор возвращает прежнюю квитанцию даже после новой правки.

Для этого среза допустим один базовый `check_soil`. Используется действующий resolver опубликованного профиля с доказательствами применимости действия и интервала к текущему таксону и условиям. Общего совета по таксону недостаточно для возобновления. Без доказательств, подтверждённого локального дня последнего полива или права на автоматический уход команда возвращает 200 с `state: "paused"` и причиной `insufficient_evidence`, `missing_watering_anchor` или `automatic_care_unavailable`. Сохраняется receipt, расписание и журнал остаются прежними.

Локальная миграция 044 добавляет внутренний SQL resolver. Он удерживает блокировки владельца, карточки, текущего snapshot и строк публикации до конца транзакции вызывающей команды. Для будущей записи результат нужно использовать в той же транзакции. Правило допускается только при точном совпадении шести полей snapshot с проверенным `validation_report.refresh_conditions[action_id]` и наличии одобренного источника для действия, интервала и пути `/actions/<index>/refresh_conditions`. Без этой разметки resolver возвращает SQL NULL. Публикация разметки и подключение команды остаются отдельными шагами.

При достаточных данных команда возвращает `state: "refreshed"`. Она атомарно сохраняет план текущего контекста и одно актуальное правило проверки, помечает заменённые правила `superseded` и выключает их открытые напоминания. Старые планы, завершённые задачи, snapshots, диагнозы и факты журнала доступны в истории. Повтор той же операции и повторное обновление того же актуального правила с другим ID не создают дубль. Ответ содержит `plant_id`, `care_revision`, `state`, `reason` (null при успехе) и `watermark`. Клиент перечитывает тот же GET для совета и даты, рассчитанной по опубликованному интервалу и локальному дню полива. Команда не вызывает AI и не пишет в квотный ledger.

Первый gate использует синтетический опубликованный профиль с явно применимым и подтверждённым интервалом. На clean/upgrade через рабочий HTTP и SQL он проходит цепочку `plant.edit` → пауза и GET без даты → явное обновление → одна следующая проверка с прежним фактом полива. Тем же gate проверить отказ при пропавших доказательствах, expiry и устаревшей ревизии, отсутствие дубля при двух конкурентных операциях, точный replay, неизменные историю и квоту. Покрытие старого SQL-калькулятора и расширенных рекомендаций остаётся отдельным.

## POST /commands — plant.delete (V13, целевой контракт T082/T083)

Маршрут подключён в локальном серверном срезе. После явного подтверждения удаления клиент отправляет команду на существующий `/commands` с теми же prefix, что у `/sync`. Сервер берёт владельца из проверенной Supabase Auth-сессии и активного постоянного профиля. Без сессии возвращается 401, для anonymous либо неактивного или отсутствующего профиля — 403 до разбора команды.

```json
{
  "operation_id": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
  "command_name": "plant.delete",
  "plant_id": "22222222-2222-4222-8222-222222222222",
  "payload_json": "{}"
}
```

`plant_id` обязателен и содержит UUID сохранённого экземпляра. `payload_json` — строка с пустым JSON-объектом. Неизвестные поля envelope, непустой payload, неверный UUID и любые query-параметры дают 400 `VALIDATION_ERROR`. Опциональный `X-Operation-Id` валидируется как UUID и должен совпасть с обязательным `operation_id` без учёта регистра. Несовпадение даёт 409 `CONFLICT`.

HTTP 200 возвращает квитанцию отзыва доступа.

```json
{
  "plant_id": "22222222-2222-4222-8222-222222222222",
  "deletion_job_id": "33333333-3333-4333-8333-333333333333",
  "state": "deleting",
  "watermark": "2026-11-12T15:30:00.123456+00:00"
}
```

Под блокировкой владельца SQL проверяет `operation_receipts` до проверки текущего состояния карточки. Совпадение владельца, ID операции, команды, нормализованного UUID карточки и декодированного payload возвращает исходный 200 с тем же `deletion_job_id` и `watermark`, в том числе после завершения очистки. Переиспользование ID владельца для другой команды или карточки даёт 409. Неизвестная или чужая карточка даёт 404 `NOT_FOUND`. Другая операция для сохранившейся tombstone-карточки того же владельца даёт 409. Неожиданная ошибка SQL или транспорта даёт 503 `INTERNAL_ERROR`, `retryable=true`. При повторе сохраняется исходный envelope.

Под блокировками владельца и карточки одна транзакция записывает receipt, ставит одну `deletion_jobs` с `scope='plant'`, `target_id=plant_id`, `state='purge_storage'` и публикует tombstones карточки и связанных с ней приватных сущностей в owner sync. Все tombstones получают один `watermark` в `updated_at` и `deleted_at`, `data=null`. Транзакция целиком откатывается при сбое любого шага. Клиент завершает открытое окно `/sync` и дочитывает delta до `until >= watermark`. Квитанция подтверждается по tombstone карточки. Локальная точка синхронизации берётся из `next_since` последней успешно применённой страницы.

После коммита новые чтения удалённой карточки, её главного и контрольного фото, рекомендации и связанной диагностики закрыты. Отдельные HTTP-маршруты чтения возвращают 404. Data API также скрывает строки. Повтор ранее принятого запроса диагностики этой карточки возвращает 404 без запуска worker. Неиспользованный резерв связанного анализа освобождается через штатное завершение квоты.

Квитанция подтверждает отзыв доступа и постановку в очередь. Служебный маршрут `POST /internal/plant-deletions/{deletion_job_id}/storage` обрабатывает одну пачку до 20 объектов в приватном `analysis-inputs` по ключам с подтверждённой принадлежностью. Общие и неподтверждённые ключи оставляет на месте, действующие upload tickets и начатые анализы откладывает. Подтверждение Storage проверяется по метаданным. Тот же job можно повторить при сбое и поздней записи. Маршрут требует служебный ключ. Служебный `POST /internal/plant-deletions/{deletion_job_id}/data` после Storage одной транзакцией очищает приватные проекции завершённых анализов, имя и сортовую метку карточки, заметки удалённых наблюдений. Ответ `{state: "pending"|"cleared", cleared: number}` описывает только этот шаг. Ledger, sync tombstones и квитанция сохраняются. Служебный `POST /internal/plant-deletions/sweep` обрабатывает страницу до десяти заданий, включая `purge_data` для поздних объектов. Следующая страница запрашивается с `?after=<next_after>` до `null`. Новый проход начинается с первой страницы. `failed` считает сбои этой страницы, `pending` — задания, ожидающие следующего прохода. Команда `tools/automation/sweep_plant_deletions.ts` обходит страницы и возвращает суммарные счётчики. Требуются `NARAT_PLANT_PURGE_ORIGIN` и `NARAT_PLANT_PURGE_KEY`. Плановый вызов и очистка остальных приватных полей остаются отдельными. `state: "deleting"` в квитанции сохраняется для точного replay. Удаление аккаунта и отзыв Apple-токена принимаются отдельно.
