# Collection HTTP — GET /sync (T019/T162, узкий срез)

Production entry point: Deno.serve(createProductionPlantsApiHandler()).
Поддержаны существующие пути /sync, /plants-api/sync и /functions/v1/plants-api/sync;
новый /v1 prefix этим срезом не добавляется. Bare createPlantsApiHandler()
сохраняет T152: sync/commands без явно переданного handler возвращают 503.
Явные delegates и остальные endpoints сохраняют поведение. Production factory
подключает только sync; POST /commands (включая plant.create) остаётся unavailable.

## Доступ и запрос

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
не заявляется. SwiftData/outbox, UI, command/create, live sync и полный T019/T162
остаются открытыми; миграции/клиент этим срезом не меняются.
