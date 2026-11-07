# Client API Contract: Narat iOS MVP

> **Синхронизация 2026-11-01:** технический дизайн приведён к спецификации Narat
> от 2026-10-30 и конституции 3.0.0: 68 FR, 25 SC, 9 историй.
> Это проект реализации; код, данные, интеграции и приёмочные испытания ещё не выполнены.

**Date**: 2026-11-01 · Base path: `/functions/v1/plants-api/v1` · [Model](../data-model.md) · [Sync](sync.md).

## Общие правила

- `Authorization: Bearer <supabase_jwt>` обязателен: техническая guest session или permanent session. Owner берётся из проверенного JWT; deleting/deleted аккаунт не обслуживается.
- `X-Client-Locale: pl | en`; locale сохраняется при запуске job. Смена языка не переводит историю.
- `X-Installation-Credential: <opaque_secret>` обязателен для analysis/claims/bind, notifications/claim и fallback; `/installations/issue` — исключение первого выпуска секрета. Секрет живёт в Keychain, сервер хранит hash и сравнивает безопасно, не логирует его.
- Каждая мутация имеет UUID `operation_id`. Lookup `operation_receipts` выполняется до побочных эффектов и квоты; payload_hash строится по каноническому телу команды, без токенов/transport headers. Тот же ID с иным payload даёт 409 operation_payload_mismatch.
- Ответ ошибки: `{ "error": { "code": "draft_expired", "retryable": false, "details": {} } }`. UI использует локализованный код, не сырой текст SQL/провайдера.
- Replay возвращает сохранённый response_payload, не повторяет изменение и списание. Состояние доступа из старого ответа не является авторизацией новой операции: право проверяется заново на сервере.

## 1. Установка, доступ и профиль

### `POST /installations/issue`

Guest/permanent JWT, `{operation_id}`. Создаёт строку installation_access, выдаёт `{installation_id, credential}`. Повтор запроса с той же операцией возвращает тот же credential из зашифрованного server-only ответа квитанции; в основной строке только hash. Обычный перезапуск использует Keychain, а не новый issue. Rate limit по установке/IP; новое устройство/сброс Keychain не объявляется решённой защитой «один человек = один набор стартовых попыток».

### `POST /installations/bind`

Permanent JWT + credential, `{operation_id}`. Под locks profiles/installation_access объединяет
starter_identification_consumed и starter_diagnosis_consumed через OR отдельно, first_starter_success_at
через минимум непустых дат; сохраняет linked_owner_ids. Живой starter job на любой стороне даёт
retryable 409 starter_in_progress без успешного receipt. Bind не переносит чужие растения/месячные
квоты и не пополняет попытки. После logout связанная установка может читать/переносить собственный
draft, но для нового анализа требует permanent login. Подробный алгоритм — data-model §4.

### `GET /analysis-access?mode=identification|diagnosis|follow_up`

Guest/permanent, credential; permanent перед новым анализом завершает bind. Ответ показывает
источник для конкретного mode, все остатки и даты. Пример Free после использованного starter ID:

```json
{
  "access_tier": "Free",
  "entitlement_state": "expired",
  "starter": {
    "identification": {"consumed": true, "in_progress": false},
    "diagnosis": {"consumed": false, "in_progress": false}
  },
  "free_monthly": {
    "eligible_from": "2026-11-01T00:00:00Z",
    "limit": 1, "consumed": 0, "reserved": 0, "remaining": 1,
    "period_start": "2026-11-01T00:00:00Z",
    "period_end": "2026-12-01T00:00:00Z"
  },
  "paid_monthly": null,
  "selected_quota_kind": "free_monthly",
  "may_analyze": true,
  "denial_reason": null
}
```

remaining=limit−consumed−reserved. Guest free_monthly=null/requires_account; без первого успешного
starter eligible_from=null/starter_not_yet_used; до первого допустимого месяца remaining=0 и дата видна.
При Free приоритет starter данного режима, затем free_monthly; занятый starter не обходится месячной квотой.
При paid access (active/grace, включая trial) только paid_monthly limit=100; Free и starter не суммируются.
Последний резерв → analysis_in_progress, исчерпание → analysis_quota_exhausted с next_available_at.
Follow_up без paid access → entitlement_required. Низкий confidence/unknown не возвращает успешный расход.
Plan, basic care, first-aid control, observations, photos и report имеют quota_kind=none.
Снимок GET не резервирует право: POST повторно выбирает источник под locks; job возвращает реально выбранный
quota_kind/period, не принимает их от клиента. Начатый Free job завершается в исходном ledger при покупке;
paid job при expiry до commit освобождает резерв, не переключается автоматически на Free.

### `GET /me`

Возвращает безопасные данные профиля, preferred_locale, reminder_hour_local (0..23, default 9), app_account_token, entitlement (offer_kind, valid_until, trial_end_at, auto_renew_enabled), Free-места/free_selection_revision/free_selection_explicit, report_notifications_enabled/trial_reminder_enabled и состояние доступа. Обновление предпочтений — команда profile.update. Секреты, чужие ownership и внутренний бюджет не выдаются.

## 2. Фото и задания

### `POST /media/upload-ticket`, `POST /media/complete`

Ticket: `{operation_id, purpose, plant_id?, draft_id?, content_type, byte_size, sha256}`. Клиент сначала нормализует ориентацию, удаляет EXIF, сжимает/уменьшает читаемый исходник любого исходного размера. Облачный вариант не больше 10 МБ; AI derivative — JPEG с длинной стороной 1568px (вариант 2576px сравнивается на eval). Сервер не требует отклонять исходник >10 МБ; ticket проверяет уже подготовленные байты. Невалидный upload возвращает media_validation_failed, клиент исправляет подготовку без потери ответов/квоты.

Ticket возвращает photo_id, закрытый upload URL и TTL 60с. Complete проверяет реально загруженные MIME/размер/hash, ставит ready и один раз фиксирует uploaded_at; job принимает только ready фото своего владельца. Исходник для экспорта может оставаться локально; original_key обозначает нормализованный дневниковый вариант, а не обязательную загрузку необработанного большого файла.

### `POST /analysis/jobs`

```json
{
  "operation_id": "11111111-1111-4111-8111-111111111111",
  "mode": "diagnosis",
  "intent": "problem",
  "add_method": "scan",
  "flow_id": "66666666-6666-4666-8666-666666666666",
  "locale": "pl",
  "draft_id": "22222222-2222-4222-8222-222222222222",
  "photo_id": "33333333-3333-4333-8333-333333333333",
  "conditions": {
    "light_code": "bright_indirect",
    "light_source": "manual",
    "light_confirmed": true,
    "watering_code": "weekly",
    "drainage_code": "unknown"
  }
}
```

- Identification: intent=care, add_method=scan, flow_id, draft_id либо plant_id и ровно одно photo_id; условия не обязательны, snapshot unknown. Vision 3.0 возвращает plant_id/null, статус, diagnosis/comparison=null; backend добавляет названия/локализованные ограничения, клиентские first_action/full_plan=null. Выбранная starter/free_monthly/paid_monthly квота и worker budget действуют до запуска; подтверждение вида и ответы не запускают новое задание.
- Diagnosis: intent=problem, add_method=scan, flow_id, draft_id либо plant_id, ровно одно исходное photo_id, три базовых ответа с unknown и optional pot_type/season_override. У существующего экземпляра expected_care_revision защищает контекст публикации, но не является блокировкой сохранения ухода.
- Follow_up: intent=problem (в рамках текущего запроса помощи, без изменения creation_intent растения), plant_id, photo_id, previous_analysis_id. Сервер добавляет предыдущие фото, условия, историю ухода; одна успешная оценка = одна paid_monthly попытка. Простое сохранение фото — команда photo.add, без job/расхода.
- Plan: permanent JWT, plant_id, flow_id, intent, plan_kind (routine/recovery), access_tier (basic/full), plan_source (analysis/catalogue), для analysis — source_analysis_id; новое photo_id не принимается, quota_kind = none. Правила stale описаны ниже.

Сервер в одной транзакции создаёт snapshot/job и резерв (только identification/diagnosis/follow_up), receipt; ответ `202 {job_id, state, quota_kind}`. Idempotent replay возвращает тот же job. Лимиты и привязка установки проверяются до провайдера; отказ до admission не расходует попытку.

`GET /analysis/jobs/:job_id` → state, created_at, deadline_at, error_code, retryable. `GET /analysis/jobs/:job_id/result` → 200 только для своего succeeded; queued/running — 202, terminal error — соответствующий код. Deadline 55с, provider timeout не более 40с и оставшегося deadline; к 60с клиент видит ошибку и повтор. Поздний lease не публикует результат.

Предварительный результат содержит identification, diagnosis, evidence_basis, limitations, first_action, source snapshot, context_state и подписанную analysis_receipt для восстановления после TTL. Диагноз не содержит полного плана. Определение вида не содержит диагноза и первого лечебного действия; receipt фиксирует mode, intent и flow_id. Маппинг: symptom IDs модели → тексты релиза; condition_factors сервер выводит только из подтверждённого snapshot. first_action, объяснения и source IDs выбирает ProtocolResolver из опубликованной базы, не модель. Результат содержит kb_release_id и protocol_id/version при наличии. Неизвестные ответы не становятся доказанными факторами.

### План из базы, включая stale-анализ

`mode=plan` — backend job, не режим Vision. Routine использует plan_source=catalogue,
recovery — plan_source=analysis и source_analysis_id режима diagnosis/follow_up;
identification не является основанием recovery. Все планы собираются без LLM,
provider_daily_budget и расхода фотоквот, включая consumed=100.

Для routine PlanService читает версионные опубликованные факты для запрошенного действия, для recovery — применимый ConditionProfile,
актуальные taxon/snapshot/care_revision и сохранённые наблюдения анализа. Для stale
повторно проверяются host applicability и предпосылки; прежняя причина — историческая
гипотеза. Недостаточно наблюдений — 422 reassessment_required, нет протокола —
422 condition_profile_unavailable. Новый скан не запускается автоматически.
Исходное фото/результат остаются в истории; повторное чтение фото моделью для plan
отсутствует. В обычной ветке ухода source_analysis_id и фото не требуются.

Для access_tier=full paid access проверяется при admission и commit; basic только routine и требует
активного basic_care_membership с Free-местом либо paid access. Care_revision проверяется перед
публикацией (иначе context_changed). Доступность профиля/протокола проверяется до
предложения покупки ради плана. Публикация plan/rules/первых tasks атомарна;
recovery_check берётся из протокола и копируется в comparison_traits/photo_angle_hint.
Routine без основания не получает выдуманную проверку восстановления.

Job/result/receipt содержат kb_release_id, schema version и hashes наблюдений/проекции.
Клиентский PreliminaryAnalysis/FullPlan сохраняет продуктовые поля; schema 3.0 описывает
только ответ провайдера, а не клиентский JSON. Подробности —
[KB module](../knowledge-base-pipeline.md).

## 3. Сохранение гостевого результата

### `POST /claims/prepare`

Guest JWT + credential: `{operation_id, draft_id, overrides?}` → `{claim_id, proof, expires_at}`. Только свой succeeded draft до server TTL. Proof 15м, сервер хранит hash; перед сменой auth сессии клиент сохраняет proof и GuestDraftCache. При истекшем draft — 410 draft_expired; при истекшем proof и живом draft можно получить новый proof гостевым credential.

### `POST /claims/commit`

Permanent JWT + credential: `{operation_id, claim_id, proof, overrides?}`. Overrides: частичные taxon_id, conditions (включая light_source/light_confirmed), room_id либо new_room_name. После старта copying effective overrides заморожены; изменение тела требует новой операции до старта копирования, а не неявного replay с иным payload. Пока перенос не опубликован, draft_claims фиксирует operation_id/payload_hash и дедуплицирует повтор с 202; окончательный operation_receipts с ответом 200 записывается только вместе с публикацией экземпляра. Pending ответ не выдаётся за финальную квитанцию.

Сервер проверяет proof/установку, фиксирует target_owner_id, выполняет приватную staging-copy и атомарно публикует экземпляр, фото, исходный результат, snapshot и комнату. Ответ при копировании — 202 `{claim_id, state: "copying"}`; `GET /claims/:claim_id` доступен только целевому владельцу. Финальный 200 возвращает сохранённый результат операции (формат ниже). Cleanup не удаляет draft с начатым валидным claim до завершения переноса; истечение TTL во время копирования не обрывает публикацию.

Смена вида/условий через overrides создаёт snapshot версии 2, care_revision = 2, исходный анализ = stale; без изменения — 1/current. Изменение только комнаты не делает stale. Фото и исходный snapshot остаются доказательствами старого результата. Starter-маркеры переносятся OR по режимам с минимальным first_starter_success_at, не списываются заново. UNIQUE(owner_id, origin_draft_id) и receipts исключают дубль при повторе/гонке claim и fallback.

### Fallback после server TTL

После 410 draft_expired клиент **не** перезапускает анализ: загружает кешированное нормализованное фото под permanent owner и отправляет `/commands` → plant.create с `source: "expired_guest_draft"`, origin_draft_id, original_conditions, cached_preliminary_result, analysis_receipt, photo_id и overrides.

Сервер проверяет подпись receipt, installation binding, locale и хеши исходных фото/условий/результата. Поправки проверяются отдельно и не подменяют подписанный исходный контекст. Затем применяет те же правила snapshot/revision/stale и возвращает тот же next_available_step. Подпись/OR маркеров не требует живого тела guest_draft; TTL не выдаёт новые стартовые попытки. Учитываются owner isolation и дедупликация по origin_draft_id.

Если кеш частично утрачен, ответ local_draft_incomplete содержит missing_fields. Клиент предлагает сохранить доступные вид/фото без подтверждённого анализа либо восстановить недостающие данные; не объявляет старую помощь безвозвратно потерянной только из-за TTL. Произвольный неподписанный результат с клиента не прикрепляется как доверенный AI-результат. Отсутствие/неверная подпись — local_result_unverifiable; справочное добавление из каталога по-прежнему возможно.

### Результат сохранения (FR-048)

```json
{
  "operation_id": "44444444-4444-4444-8444-444444444444",
  "plant_id": "55555555-5555-4555-8555-555555555555",
  "revision": 1,
  "care_revision": 2,
  "analysis_context_state": "stale",
  "next_available_step": {
    "kind": "generate_plan",
    "plant_id": "55555555-5555-4555-8555-555555555555",
    "plan_id": null,
    "reason_code": "context_updated"
  }
}
```

Ответ дополнительно содержит intent, plan_kind (routine/recovery), access_tier (basic/full), plan_source и plan_availability (available/unknown_species/care_profile_unavailable/condition_profile_unavailable/reassessment_required/diagnosis_unresolved/treatment_schedule_unavailable). Доступность проверяется до предложения оплаты ради этого плана; при недостатке данных kind=view_plant с reason_code, а не обещание недоступного плана.

`NextAvailableStep.kind`: enable_basic_care / select_free_plants / record_first_aid /
open_first_aid_control / generate_plan / open_plan / view_plant. Сохранение возвращает основной
бесплатный следующий шаг и optional `paid_action` {kind, available, reason_code}; subscribe доступен
только как ответ на явный запрос платного действия, а не обязательный следующий экран сохранения.
Для problem — применимое первое действие/существующий контроль; для care — включение базового ухода
или выбор тройки. При нехватке данных view_plant с reason_code; ранее полученный план можно открыть
после expiry, но его applicability отображается отдельно. Сохранение не выполняет уход автоматически.
Платное предложение возникает по запросу full plan/extended care/анализа без Free-квоты после первой
пользы; availability проверяется до paywall. `RequestedAction` на клиенте хранит action/plant/flow,
care_revision и context/source; отмена возвращает к Free, подтверждённая покупка возобновляет запрос
после повторной проверки применимости. Start лечения остаётся отдельным явным подтверждением.

## 4. Команды, каталог, планы и оплата

### `POST /commands`

Envelope: `{operation_id, command, plant_id?, expected_revision?, payload}`. Permanent JWT; операция записывается в LocalOutbox до отправки. Ответ 200: `{operation_id, outcome, result, revisions, next_available_step?}`. Для plant.create result содержит формат результата сохранения выше; replay возвращает тот же результат. Mutations и receipt атомарны.

| Команда | Payload / поведение |
| --- | --- |
| plant.create | flow_id, intent, add_method; source=catalogue + published taxon_id (связывается с семантическим `plant_id` вида), необязательные personal_name/display_name (по умолчанию локализованное имя вида или `scientific_name`), photo_id (`main_photo_id` личного экземпляра, не заменяющий видовое `hero_image` каталога), conditions (`current_condition_snapshot_id = null`, если вопросы об условиях не заполнялись) и room; в текущем контракте T147 без опубликованного `care_profile` возвращает `plan_availability = 'care_profile_unavailable'` и `next_available_step.kind = 'view_plant'`; либо source=expired_guest_draft с проверяемым локальным результатом diagnosis/identification; нет диагностики или списания при сохранении |
| plant.edit | частичный patch имени/вида/условий/комнаты; только вид/условия повышают care_revision, создают snapshot, помечают analyses stale и незавершённые неприменимые tasks needs_review |
| room.create / room.rename / room.delete | имя/ID; удаление разрывает привязки, сохраняет растения/историю |
| care.record | entry_id (UUID клиента), task_id nullable, action_code, occurred_at, occurred_local_date, timezone; одна активная запись на task; fact ухода всегда сохраняется независимо от revision и подписки |
| care.undo | entry_id; ставит voided и сохраняет reversal; повторная отмена — успешный no-op |
| care.correct_date | entry_id и новая фактическая дата; valid прошлое/сегодня; без revision-конфликта; пересчёт истории не создаёт новый факт ухода |
| photo.add / photo.set_main | готовое своё photo_id; добавление без анализа бесплатно и не расходует квоту |
| schedule.relocalize | IANA timezone устройства; пересчёт будущих местных дат/уведомлений с проверкой access_class/Free-мест перед новым occurrence |
| profile.update | preferred_locale, reminder_hour_local (целое 0..23), report_notifications_enabled, trial_reminder_enabled; сохранение часа перестраивает уведомления клиента; default 9 |
| plant.delete / account.delete | явное подтверждение; отзыв доступа и асинхронная очистка; account delete не отменяет подписку App Store |

Семантика care.record/care.undo, устаревших revisions и доставки команд — [sync](sync.md). needs_review не блокирует care.record/care.undo/уведомления; INSERT следующего task требует применимого правила и разрешения access_class (basic_care/first_aid_control/premium); исключённые из Free-тройки basic задачи не имеют активных напоминаний. Отказ возможен при удалённом растении, неверных данных, чужом владельце, но не из-за старой ревизии.

`GET /catalogue?query=&locale=&page=&limit=` → список опубликованных видов только из текущего активного `catalogue_releases` (`state = 'published'`, включая базовый релиз `skeleton-300-v1` с `kb_release_id = null`; при отсутствии опубликованного релиза возвращается `total = 0, items = []`), поиск без учёта регистра и диакритики (`normalize_catalogue_search_text`) по PL/EN обиходным названиям, латинскому `scientific_name`, роду (`genus`), семейству (`family`) и синонимам (`search_aliases` / `taxon_names`), с fallback `display_name` на `scientific_name` (`localized_name = null`), если для выбранной локали нет обиходного имени.
`GET /catalogue/:taxon_id?locale=` (принимает UUID `taxon_id` или семантический `plant_id`; возвращает карточку только если вид опубликован в текущем активном `catalogue_releases.state = 'published'`) → полная бесплатная справочная карточка базового каталога (21 обязательное поле; машиночитаемый контракт — [catalogue-skeleton.schema.json](catalogue-skeleton.schema.json), `definitions.card`; вход импорта — `definitions.record`). Схема используется Ajv в TS и тем же JSON в SQL; отсутствие обязательного поля, неверный тип или формат блокируют импорт/публикацию. SQL `project_catalogue_species_card` и TS `projectCatalogueSkeletonCard` возвращают:
- таксономия и источники имени: `taxon_id`, `plant_id`, `scientific_name`, `accepted_scientific_name`, `scientific_name_status`, `wikidata_id`, `rank`, `genus`, `family`, `external_taxon_ids`, `name_source`;
- локализованные названия: `localized_name` (`string | null`), `display_name`, `common_names: {en, pl}`, `search_aliases: {en, pl}`;
- описания: локализованный объект `description` (с fallback на `en`) и словарь `descriptions: {en, pl}` с полями `text`, `language` (`"en" | "pl"`), `source_url`, `source_revision`, `article_wikidata_id`, `revision_url`, `history_url`, `attribution`, `license` (`"CC-BY-SA-4.0"`), `license_url`, `modifications`, `review_status` (и `translation_source_language: "en"` для переведённых записей);
- видовое изображение: `hero_image` (`file_title`, `source_page`, `local_path`, `storage_path`, `sha256` (64 hex), `bytes`, `width`, `height`, `mime`, `license`, `license_url`, `author`, `credit`, `attribution`, `modifications`);
- сезонные интервалы полива: `watering` (`intervals_days: {spring, summer, fall, winter}` — значения `int (1..365) | null`, все четыре ключа обязательны; `null` означает, что источник не задаёт регулярный интервал для сезона: клиент не создаёт по нему расписание и не подменяет его нулём, другим сезоном или запретом полива; требуется минимум 2 сезона с положительным интервалом `1..365`, кроме полуводных видов с `watering_method = "immersion"`, где все 4 сезона могут быть `null`; также включает `watering_method`, `drainage_preference`, `match_level` (`species_exact | species_synonym | genus_representative | botanical_group_representative`), `matched_on`, `source: {id, repository, commit, snapshot_sha256, plantfolio_id}`);
- доступность расширенного профиля и безопасность: `care_profile_available` (`false`, пока полный `PlantProfile` не опубликован в `care_profiles`) и `safety: {cat: {status: "unknown"}, dog: {status: "unknown"}}` (при наличии опубликованного `care_profiles` заполняется из `profile.safety`).
Для опубликованной карточки `description`, обе `descriptions`, `hero_image` и `watering` — обязательные объекты, `wikidata_id` — строка `Q[1-9][0-9]*`, `care_profile_available` — boolean. `common_names.en/pl` — массивы объектов с обязательными строками `name/source_property`, `search_aliases.en/pl` — массивы строк, `external_taxon_ids` — объект массивов строк. `taxon_id` в SQL — UUID; `null` допустим только в offline-проекции до присвоения БД. `name_source` — объект либо `null`; `localized_name` — строка либо `null`. У изображения `bytes/width/height` — положительные целые, `mime/storage_path/credit` необязательны (в исходном bundle `mime` отсутствует). Необязательные поля происхождения и их типы заданы схемой.

Целевое поведение по FR-052/056: флаг `care_profile_available` описывает прежнюю проекцию. Доступность совета определяется отдельно по каждому действию и условиям экземпляра. Обновление контрактов и реализации запланировано в T055/T115.

Параметры алгоритма, полные протоколы и тексты планов — server-only; каталог работает без подписок, LLM-вызовов и расхода квот. Семантический `plant_id` вида однозначно связан с `taxon_id` UUID, а личный экземпляр пользователя в `plants` имеет собственный UUID `id` и ссылается на вид через `taxon_id` / `plant_id`.

`GET /plans/:plant_id/current?access_tier=basic|full` и `GET /plans/:plant_id/versions/:version_id`
→ собственный ранее опубликованный план, в том числе после expiry/refund/trial, с created_at/version,
context_revision, applicability current/stale/blocked и актуальными restrictions. Историческое чтение
не создаёт план/задачи и не требует подписки. Неприменимые инструкции блокируются (возвращается metadata
и reason, не активный совет); safety mask действует online/offline независимо от оплаты.
Чужой/отсутствующий план → resource_not_found/plan_not_found. Cache не даёт права создавать новый full plan.

`POST /billing/verify`, `POST /billing/restore` принимают operation_id и подписанную транзакцию, проверяют JWS, environment, bundle/product IDs, appAccountToken и ownership. Verified entitlement (offer_kind/valid_until/trial_end_at/auto_renew_enabled) и quota_anchor_at от первого предоставления доступа, включая trial, определяет сервер. Verify/restore не пополняют квоту. Два продукта month/year; eligibility проверяется StoreKit до покупки, неизвестная eligibility не обещает trial. Сервер подтверждает реально предоставленный trial по транзакции, не клиентскому флагу. Ownership conflict не переносит чужую покупку. Notifications V2 принимает отдельный `/functions/v1/billing-webhook`, проверяет подписи и дедуплицирует notification_uuid; публичный webhook не использует пользовательский JWT.

`GET /sync` доступен permanent владельцу; since/until, поля и пагинация определены в
[sync.md](sync.md). GuestDraftCache не требует доступа гостя к постоянной коллекции.

## 5. Ошибки и границы

| Статус | Коды и обработка |
| --- | --- |
| 401 / 403 | invalid_session, installation_credential_required, entitlement_required, owner_forbidden; не раскрывать чужой UUID/контент |
| 404 / 410 | resource_not_found, plant_deleted, draft_expired; draft_expired запускает локальный fallback после входа |
| 409 | operation_payload_mismatch, starter_in_progress, analysis_in_progress, free_selection_changed, context_changed, clarification_conflict; старой revision команд ухода здесь нет |
| 422 | invalid_conditions, invalid_reminder_hour, future_care_date, media_validation_failed, local_draft_incomplete, local_result_unverifiable, source_photo_unavailable, care_profile_unavailable, condition_profile_unavailable, reassessment_required, diagnosis_unresolved, treatment_schedule_unavailable, free_slot_required, invalid_free_selection, invalid_report_period, first_aid_unavailable, first_aid_control_unavailable |
| 429 | analysis_quota_exhausted (с датой обновления), provider_budget_exhausted, rate_limited; plan не блокируется исчерпанием фотоквоты/provider budget; общий rate limit сохраняется |
| 502 / 504 | provider_failed, invalid_ai_result, analysis_timed_out; резерв освобождён один раз, ошибка не расходует успешную попытку |

Ошибки и unknown не превращаются в диагноз. Общий catalogue/sync не содержит full_body (собственные сохранённые планы читаются отдельным owner API), server secrets, Storage keys или подписанных URL. Выдача фото отдельным owner-checked media endpoint с TTL 60с; права на исходное фото повторно проверяются перед AI-вызовом.


## 6. Воронка намерений (FR-051)

`POST /funnel/events` принимает guest/permanent JWT и фиксированный payload:
`{event_id, flow_id?, step, intent?, previous_intent?, add_method?, source_context, context_id?, occurred_at}`. Source_context — фиксированный enum onboarding/plant/free_scan/report/today/profile; произвольный текст не допускается.
Разрешённые клиентские steps и схема хранения — [data-model.md](../data-model.md#6-намерение-и-события-воронки-fr-049fr-051).
Неизвестные поля, свободный текст и серверные steps отклоняются; owner_id выводится
из JWT. Повтор event_id с тем же payload возвращает 200/replayed, иной payload — 409.
События не расходуют фотоквоту, их доставка не блокирует добавление. Порядок реконструируется
по occurred_at и сохранённой цепочке flow; время клиента не доказывает покупку.

Серверные события result_ready/plant_saved/first_useful_task_created/care_completed/free_monthly_scan_used/
trial_started/trial_ended/purchase_confirmed/renewal_confirmed/access_expired/refund_confirmed/plan_created
создаются после соответствующего подтверждения, с event_id и semantic dedup_key. Pending/cancelled/restore
не новая покупка; нулевой trial не revenue. Billing verify принимает авторизованный flow/source_context
и requested action attribution; webhook завершает связанное событие без повторного учёта.

`POST /funnel/claims/prepare` (guest JWT + installation credential) создаёт одноразовый
15-минутный proof для переноса только собственных событий flow. `POST /funnel/claims/commit`
(permanent JWT + тот же credential + proof + operation_id) связывает flow с аккаунтом
идемпотентно; proof не требует успешного AI и не даёт доступа к растениям. Это поддерживает
также каталог без фото. Результаты analysis claim переносятся отдельным существующим протоколом.

Сервисный отчёт (не публичный клиентский endpoint) показывает первые выборы, переключения
и переходы до покупки/плана по намерению и методу, по distinct flow_id. Покупка после смены
намерения относится к ветке на момент покупки; отчёт первого выбора остаётся неизменным.
Отдельный сервисный monetization report добавляет Free/Trial/Paid, когорты, D7/D30, первое продление, refunds, revenue и provider cost, включая неуспешные вызовы. Полные окна и знаменатели обязательны; неизвестная стоимость/межустройственная уникальность явно unknown. Аналитический отчёт не является пользовательским Progress Report. Автоматического отключения ветки или изменения тарифов нет.

## 7. Версии KB и миграция контракта 3.0

До создания job сервер выбирает published release и фиксирует его ID/schema/prompt;
модель получает только его plant/condition/symptom/limitation IDs. Неизвестный ID,
несогласованный режим/статус или свободный совет — invalid_ai_result, резерв освобождается.
Healthy/insufficient_data/out_of_scope выбирают готовый fallback релиза. Runtime result
возвращает до двух кандидатов с rank/confidence и visual_markers, без заявления о калиброванной вероятности.

Provider schema 1.2/2.0 заменены 3.0 несовместимо: plan, first_action, full_plan и генерируемые
тексты удалены. У кода/развёрнутых клиентов пока нет пользователей, dual-write не нужен.
При появлении старых fixtures их переводят явным скриптом с protocol mapping;
выдуманные source IDs не импортируются. Job pin фиксируется и в signed receipt для TTL.
Старые результаты/планы остаются историческими snapshot, новая база не меняет их молча.
Публичный catalogue/sync не отдаёт полные Golden Records или платные тела.

Перед показом товара, включая PlanHistoryCache, проверяются актуальные блокировки и срок.
После valid_until без сети химическая рекомендация скрывается до проверки; отозванная
онлайн запись блокируется сразу, офлайн проверка выполняется при следующем соединении.
Полные гарантии немедленного отзыва на отключённом устройстве не заявляются.

## 8. Disambiguation API (FR-061/064)

Готовый `GET /analysis/jobs/:job_id/result` дополнен visual_markers и кандидатами
`{condition_id, rank, confidence}` (max 2), `diagnostic_decision` с id/revision/state,
`clarification_required` и одним текущим вопросом `{question_id,text,answer_options:[yes,no]}`
на locale результата. Полный банк вопросов/ConditionProfile клиенту не выдаётся.
Для identification диагностическое решение null. Фото job завершается с пригодной
первой помощью даже при awaiting_answers: пользовательское ожидание не держит lease.

Для повторной диагностики сервер использует контекст только данного экземпляра: актуальные условия, фото и фактические записи ухода с учётом отмен и исправлений; клиентские произвольные утверждения о выполнении задач не принимаются вместо истории. При повторной диагностике список вопросов пуст даже при неоднозначном результате, отдельный шаг ответа не требуется. Это целевой контракт FR-004/061.

`GET /analysis/results/:id/clarifications`: свой guest/permanent JWT, installation
credential для guest → текущий decision, принятые ответы, заданный вопрос/лимит,
локализованная первая помощь. Owner/release/care_revision проверяются сервером.

`POST /analysis/results/:id/clarifications`:
`{operation_id, decision_id, expected_revision, question_id, answer:"yes"|"no"}`
либо `{operation_id, decision_id, expected_revision, skip:true}` (взаимоисключающие формы).
Ответ: `{decision_id,revision,state,question?,selected_condition_id?,first_action,
limitations,decision_receipt}`. Запрашиваются только вопросы, пригодные для пары top-2.
Вопрос/ответ/score/решение и operation receipt сохраняются атомарно. Повтор с тем же
operation ID не добавляет вес/новый вопрос. При конфликте — 409 clarification_conflict
с собственной актуальной revision; клиент обновляет состояние. Это не revision-конфликт
команд ухода. Можно исправить ранее принятый ответ того же question_id: новая версия,
пересчёт от исходных scores; max 2 distinct question IDs, без накопления бонуса.

Порог входа и правило расчёта — KB §8.2. После каждого ответа разрешение либо
следующий вопрос; после max/skip/no question остаётся uncertain/skipped без придуманного
диагноза. Missing answer не равно no. Вызовы не используют LLM/provider budget/фотоквот.
Stale context → context_changed/reassessment_required, не скрытый повтор анализа.

Клиент сохраняет receipt и current/pending answer state в GuestDraftCache. Claims/fallback
принимают optional cached_decision + decision_receipt, проверяют связанный analysis hash,
release/policy/ответы и переносят историю идемпотентно. Неподтверждённый локальный pending
ответ после входа отправляется как пользовательский ввод, сервер сам рассчитывает решение.
Фотоквота учитывается только в исходном успешном analysis job.

## 9. Условия и старт лечения (FR-062/063)

`conditions`/overrides/plant.edit дополнены optional pot_type (terracotta/plastic/
glazed_ceramic/other/unknown) и season_override (auto/summer/winter); пропуск при создании —
unknown/auto, при patch — сохранить. Значения не распознаются по фото; изменение
повышает care_revision и делает прежние решения/планы неприменимыми по общим правилам.

`mode=plan, plan_kind=recovery` дополнительно принимает diagnostic_decision_id,
diagnostic_decision_revision, treatment_start_local_date и optional selected_treatment_option_id.
Без уточнённого применимого решения — diagnosis_unresolved; при отсутствии проверенного
расписания — treatment_schedule_unavailable, до предложения покупки ради такого плана.
Start по умолчанию — сегодняшняя локальная дата подтверждённого явного запроса; это не
запись уже выполненной обработки. Выбор treatment option только из approved профиля/PL mapping.

FullPlan дополняется краткой заразностью/unknown, urgency, duration_weeks и treatment
steps/timeline. Поля interval_days/repeat_count/start_offset_days имеют семантику KB §9.1.
Task rules/occurrences поддерживают isolate/wash_pests/treat_pests; нет INSERT всех
будущих повторов для обхода entitlement. Общие care.record/undo/backdate, приватность
и 30 локальных notifications остаются прежними. Dose/product из LLM не принимаются.

В result envelope исходный analysis/first_action и analysis_receipt неизменны.
Актуальные decision/first_action/decision_receipt передаются отдельной проекцией;
UI выбирает её при наличии, иначе исходную безопасную помощь. Hash analysis_receipt
не включает изменяющуюся decision projection; decision_receipt подписывает её отдельно.
Это позволяет восстановить оба состояния без подмены исходного анализа.

## 10. Free-уход, контроль и переход (FR-023/066/067)

Следующие операции используют общий POST /commands, permanent JWT и operation_receipts.

| Command | Payload | Result / ограничения |
| --- | --- | --- |
| basic_care.enable | plant_id, expected_care_revision | проверяет профиль/условия, создаёт membership/basic plan/rules атомарно; первые три занимают места, четвёртый без paid access → free_slot_required, коллекция сохраняется |
| basic_care.disable | plant_id | paused basic rules, reminder_eligible=false у прежних базовых tasks; история не удаляется |
| free_care.select | plant_ids: UUID[0..3], expected_selection_revision | разные собственные экземпляры, включая ещё не enabled; проверка профиля/условий и включение выбранных/замена мест атомарны, ошибка откатывает весь выбор; explicit flag сохраняет также пустой выбор; возвращает memberships/revision/affected_tasks; stale selection → free_selection_changed; платный уход сохраняется при active/grace |
| care.postpone | task_id, due_local_date, timezone | только открытая базовая проверка, дата не раньше сегодня; прежняя/новая дата и причина, без care_entry; не переносит химическую обработку произвольно |
| first_aid.record | plant_id, analysis_result_id, decision_revision?, occurred_at, occurred_local_date, timezone | применимое опубликованное первое действие; один факт и максимум один control, без paid access/места; already_recorded при повторе; если нет срока — контроль null + reason, факт действия может сохраниться |
| observation.record | plant_id, task_id, status_code, note?, photo_id?, observed_at | личное наблюдение для контроля, optional своё ready фото; без job/AI/квоты; не является автооценкой здоровья |
| recovery.transition | plant_id, recovery_plan_id, observation_id, expected_care_revision, confirm:true | current applicability + явное подтверждение; improved не гарантирует выздоровление; unknown/worse/stale → reassessment_required; атомарное согласование правил с basic care по доступу |

First aid связывается по origin_analysis_id, не текущей revision решения: повторное уточнение не открывает
ещё один бесплатный контроль. Care.undo/correct_date работают с полученным entry по общему протоколу; undo отключает reminders
незавершённого контроля через reminder_eligible=false/inactive_reason=first_action_undone, повторная
отметка переиспользует тот же контроль и после проверки актуальности восстанавливает его напоминание.
Снятие Free-места не запрещает сохранить факт старого ухода. Полные правила lifecycle — data-model §9.
Новый photo follow_up вызывается только отдельным явным POST /analysis/jobs по paid_monthly.

## 11. Progress Report и reminders (FR-068)

`GET /reports/progress?month=YYYY-MM&timezone=IANA` — permanent owner, Free/Trial/Paid/expired.
Только завершённый местный месяц; future/current month → invalid_report_period. Ответ:
`{month,timezone,period_start,period_end,data_as_of,coverage_start,partial_month,missing_data,
actions_by_type,photos,observations,upcoming_tasks}`. Photos содержат metadata/IDs/date_source,
не публичные storage URL; защищённая выдача фото сохраняется. Изменённые/отменённые записи
пересчитываются при чтении; upcoming_tasks относятся к текущему состоянию, не прошлому месяцу.
Нет AI, расхода квоты, генерации новых задач или утверждений о росте/выздоровлении.
ReportCache/offline semantics и фильтрация дат — data-model §10.

`POST /notifications/claim`: `{operation_id,kind,period_key,installation_id,timezone}`.
Проверяет owner, credential/binding installation, opt-in, тип/период; progress_report допускает завершённый либо текущий месяц
для предварительного scheduling после его окончания, trial_end только подтверждённый будущий срок.
Сервер возвращает `{claim_id,may_schedule,notification_id,scheduled_at,reason_code}`;
unique owner/kind/period_key исключает другие устройства, timezone не входит в report key.
Клиент не назначает прошедшее напоминание задним числом. Claim не гарантирует доставку и не
блокирует доступ к отчёту/дате окончания trial. Отмена/перестройка описана в sync §5.

## 12. Совместимость документационного изменения

API path v1 остаётся: развёрнутого приложения/миграций в репозитории нет. Прежние поля
trial_used/trial_in_progress и общий quota_kind trial/monthly заменены starter и раздельными
monthly источниками до реализации; trial — только подписка. Старые fixtures должны быть
пересозданы/явно переведены без выдуманного расхода. Provider schema 3.0 и Golden Record schemas
1.0 не меняются: коммерческие права/отчёт принадлежат backend DTO, а не Vision/KB JSON.
При обнаружении реальных развёрнутых данных остановить destructive migration, провести inventory
и описать backfill под отдельную проверку; нынешняя синхронизация не является production migration.
