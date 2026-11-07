# Data Model: Narat iOS MVP

> **Синхронизация 2026-11-01:** технический дизайн приведён к спецификации Narat
> от 2026-10-30 и конституции 3.0.0: 68 FR, 25 SC, 9 историй.
> Это проект реализации; код, данные, интеграции и приёмочные испытания ещё не выполнены.

**Date**: 2026-11-01 · **Основание**: [spec.md](spec.md), 68 FR / 25 SC, включая сессию 2026-10-30.

## Обогащение ухода (целевое поведение от 6 ноября)

Факт вида относится к стабильному taxon_id, теме, источнику/версии, области применимости и состоянию проверки. Публикация и отзыв оцениваются для конкретного факта и зависящих от него действий. Таблица care_profiles и её флаг описывают действующий контракт T147; переход к доступности по действиям планируется в T055/T115. Ответы при добавлении принадлежат личному экземпляру и версии его условий. При диагностике выполненные действия берутся из его журнала с фактическими датами, исправлениями и отменами. Открытая задача и наблюдение за грунтом не свидетельствуют о поливе.

## Общие правила

- Внутренние ID и `operation_id` — UUID. Семантические KB plant_id/condition_id/symptom_id — стабильные строки; plant_id ↔ catalogue taxon_id UUID, не UUID личного экземпляра. Системное время — UTC `TIMESTAMPTZ`; фактическая местная дата ухода — `DATE` с IANA timezone. Будущая дата ухода отклоняется при команде.
- Все приватные строки принадлежат `owner_id`; RLS и сервер проверяют `auth.uid()` и `profiles.account_state = 'active'`. Операционные поля квот недоступны для клиентской записи.
- Все синхронизируемые строки имеют `updated_at` и nullable `deleted_at`, даже если ниже эти общие поля опущены. Создание неизменяемой записи тоже задаёт `updated_at`. Удаление оставляет tombstone до удаления аккаунта; файл удаляется отдельно.
- Каждая транзакция, меняющая бесплатные проекции владельца, сначала блокирует его `profiles` через `SELECT ... FOR UPDATE`. Единая метка изменения `GREATEST(clock_timestamp(), profiles.updated_at + interval '1 microsecond')` записывается во все затронутые строки и `profiles.updated_at`. Это watermark для [sync](contracts/sync.md), а не отдельная лента событий.
- Порядок блокировок: profiles владельцев по UUID → installation_access по UUID → monthly_quotas → plants по UUID → дочерние записи. Worker заранее получает контекст job, затем берёт блокировки в этом порядке и повторно проверяет lease. Связанные операции не меняют порядок.
- `revision` меняется при любом изменении экземпляра. `care_revision` — только при смене вида или условий; имя, комната и главное фото не делают контекст ИИ устаревшим. Команды ухода не отклоняются из-за несовпадения ревизии.

## 1. Каталог и Golden Records

| Сущность | Ключевые поля | Ограничения |
| --- | --- | --- |
| source_registry | id, donor, urls, status, use_basis, allowed_operations JSONB, terms_checked_at, valid_until, rate_limit | candidate/allowed/blocked/expired; ingestion только allowed, отдельно коммерческое/LLM use |
| source_documents | id, source_id, canonical_url, content_hash, markdown_key, published_at nullable, retrieved_at, rights_snapshot | immutable source snapshot, документы из одного первоисточника не независимые |
| kb_releases | id UUID, version, schema_version, manifest_hash, seed_version, condition_manifest_version, disambiguation_policy JSONB, prompt_version, guardrail_version, validation_report, state, published_at | draft/validated/published/retired; один текущий published, pin старых сохраняется; целевые партии фактов публикуются независимо; общий охват MVP — SC-016 |
| catalogue_releases | id, version, source_doi nullable, source_hash, published_at, state, kb_release_id nullable | базовый релиз каталога (`skeleton-300-v1`, 606 видов) может публиковаться и обслуживаться с `kb_release_id = null` до готовности правил ухода и протоколов проблем; в каждый момент не более одного `state = 'published'`; переключение и откат выполняются через `publish_catalogue_release` |
| catalogue_release_species | release_id, taxon_id, plant_id, accepted_scientific_name, scientific_name, scientific_name_status, wikidata_id, source_revision, rank, genus, family, common_names JSONB, search_aliases JSONB, descriptions JSONB, hero_image JSONB, watering JSONB, external_taxon_ids JSONB, name_source JSONB, gaps JSONB, care_profile_available BOOLEAN, status | PRIMARY KEY(release_id, taxon_id), UNIQUE(release_id, plant_id); изолирует staging/draft/retired снимки видов от активного опубликованного релиза и сохраняет предыдущие снимки при переключении/rollback; `watering.intervals_days.{spring,summer,fall,winter}` хранит `int (1..365) | null` (все 4 ключа обязательны; null — отсутствие регулярного интервала у источника, без построения расписания; минимум 2 активных сезона, кроме `watering_method = 'immersion'`) |
| catalogue_taxa | id UUID, release_id nullable, plant_id TEXT UNIQUE, accepted_scientific_name, scientific_name, scientific_name_status, wikidata_id nullable, source_revision nullable, rank, family, genus nullable, common_names JSONB, search_aliases JSONB, descriptions JSONB, hero_image JSONB, watering JSONB, external_taxon_ids JSONB, name_source JSONB, gaps JSONB, care_profile_available BOOLEAN, status | `plant_id` стабилен при переименовании; материализует активный `published` релиз из `catalogue_release_species` (видимость в поиске, карточке и `plant.create` строго ограничена `status = 'published'` и принадлежностью к активному `catalogue_releases.state = 'published'`) |
| taxon_external_ids | taxon_id, provider, external_id, source_release, redirect_target | UNIQUE(provider, external_id, source_release); Perenual/WFO/RHS/NC State/GBIF/IPNI/POWO/TROPICOS IDs внешние |
| taxon_names | id, taxon_id, language, kind, value, normalized_search, source_id nullable, source_property nullable, source_revision nullable, review_status | PL/EN/la, scientific/common/synonym/trade; species-level aliases без циклов; нормализованный индекс для регистро- и диакритико-независимого поиска |
| catalogue_media | id, taxon_id, file_title nullable, original_page, local_path nullable, storage_path nullable, sha256, width nullable, height nullable, mime_type nullable, byte_size nullable, author, credit nullable, license_id, license_url, attribution, modifications nullable, is_hero BOOLEAN, review_state | только approved (`is_hero = true` для основной карточки вида); лицензия и атрибуция картинки проверяются отдельно и не перезаписываются пользовательским фото экземпляра |
| evidence_sources | id, source_document_id, url, retrieved_at, license_or_use_basis, validation_method, validated_at, scope | field_evidence JSON pointers с точным источником/фрагментом; специалист не обязателен |
| care_profiles | id, kb_release_id, taxon_id, version, profile JSONB, field_evidence JSONB, validation_report, state | PlantProfile schema, EN/PL в одном ядре, параметры/safety cat-dog, null/unknown; UNIQUE(release,taxon) |
| condition_profiles | id, kb_release_id, condition_id TEXT, version, protocol JSONB, field_evidence JSONB, state | ConditionProfile schema; UNIQUE(release,condition_id), 40 published IDs |
| kb_vocabularies | kb_release_id, kind, code, localized_text JSONB | symptom/check/limitation/action codes, уникальны в релизе; оба языка |
| kb_fallback_protocols | kb_release_id, fallback_id, prerequisites JSONB, actions JSONB, task_rules JSONB, content_i18n JSONB, field_evidence | healthy/unknown/out_of_scope/unknown_conditions; не входят в 40 conditions; без специфического лечения |
| treatment_options | id, category, active_ingredient nullable, biological_agent nullable, scope | chemical/soap/biological/mechanical; вещество не означает разрешение |
| product_evidence | id, treatment_id, exact_sku, category, pl_label_url, authorization_id nullable, authorization_status, application_scope JSONB, non_professional_use, indoor_use, offer_url, checked_at, valid_until, state | approved; scope/label/PL проверены; <=30 дней и до expiry, неизвестное исключается |
| treatment_blocks | id, treatment_id nullable, product_id nullable, reason, effective_at, updated_at | срочный отзыв отдельно от immutable release; применяется к runtime и кешу |

Release JSON экспорт и PostgreSQL import содержат одни ID/версии/hash.
Прежний формат импорта вида: [PlantProfile](contracts/plant-profile.schema.json),
[ConditionProfile](contracts/condition-profile.schema.json). Сырые документы/полные
записи и treatment registry server-only; в клиентском каталоге безопасная проекция,
сохранённый персональный план выдаётся только владельцу, включая чтение после expiry; создание нового полного плана требует paid access. Unknown safety не означает безопасность.

## 2. Аккаунт, коллекция и гостевое сохранение

| Сущность | Ключевые поля | Ограничения |
| --- | --- | --- |
| profiles | id (Auth UID), account_state, anonymous, app_account_token, preferred_locale, reminder_hour_local, starter_identification_consumed, starter_diagnosis_consumed, starter_identification_job_id nullable, starter_diagnosis_job_id nullable, first_starter_success_at nullable, quota_anchor_at nullable, free_selection_revision, free_selection_explicit, report_notifications_enabled, trial_reminder_enabled, updated_at | account_state IN ('active','deleting','deleted'); preferred_locale IN ('pl','en'); `reminder_hour_local INT NOT NULL DEFAULT 9 CHECK (reminder_hour_local BETWEEN 0 AND 23)`; starter flags BOOLEAN NOT NULL DEFAULT false; free_selection_revision BIGINT NOT NULL DEFAULT 0; free_selection_explicit BOOLEAN NOT NULL DEFAULT false; opt-ins BOOLEAN NOT NULL DEFAULT false; app_account_token только permanent; quota_anchor_at фиксируется при первом подтверждённом предоставлении paid access, включая trial |
| guest_drafts | id, guest_owner_id, flow_id, intent, add_method, photo_id, condition_snapshot_id, analysis_job_id, expires_at | TTL 24ч; не постоянная коллекция; удаление не сбрасывает стартовые попытки |
| draft_claims | id, draft_id, proof_hash, expires_at, target_owner_id nullable, operation_id, payload_hash nullable, overrides JSONB nullable, result_plant_id nullable, state | proof 15м; prepared → copying → published → cleanup_done; proof не логируется; overrides входят в payload_hash |
| rooms | id, owner_id, name, revision, updated_at, deleted_at | удаление обнуляет plants.room_id и обновляет затронутые растения, не удаляя их |
| plants | id, owner_id, origin_flow_id, creation_intent, add_method, personal_name, display_name, taxon_id nullable, plant_id TEXT nullable, cultivar_label nullable, room_id nullable, main_photo_id nullable, current_condition_snapshot_id nullable, current_snapshot_id nullable, origin_draft_id nullable, creation_source, revision, care_revision, created_at, updated_at, deleted_at | creation_source IN ('catalogue','analysis','identification'); creation_intent IN ('problem','care'), add_method IN ('scan','catalogue'); identification не означает диагноз; catalogue требует published taxon (`taxon_id` ↔ семантический `plant_id`), `personal_name`/`display_name` по умолчанию берётся из локализованного названия или `scientific_name`, `main_photo_id` и `current_condition_snapshot_id` необязательны (загрузка личного фото меняет только `plants.main_photo_id`, не `catalogue_taxa.hero_image`); UNIQUE(owner_id, origin_draft_id) при ненулевом origin_draft_id предотвращает дубль claim/fallback |
| condition_snapshots | id, owner_id, plant_id nullable, draft_id nullable, version, light_code, light_source, light_confirmed BOOLEAN, watering_code, drainage_code, pot_type, season_override, created_at | неизменяемые значения; ровно одна связь plant/draft; UNIQUE(plant_id, version) для постоянной истории |
| photo_assets | id, owner_id, plant_id nullable, draft_id nullable, purpose, original_key, analysis_key, content_hash, capture_at nullable, uploaded_at nullable, state, updated_at, deleted_at | uploaded_at фиксируется сервером при первом ready и неизменен, claim/fallback сохраняет исходную проверенную дату; capture_at nullable и только доверенная/явно подтверждённая дата съёмки; purpose IN ('initial','follow_up','diary'); state IN ('initialized','uploaded','ready','failed','deleting','deleted'); ключи и signed URLs не входят в sync |
| deletion_jobs | id, owner_id, scope, target_id, encrypted_apple_ref nullable, state, operation_id, created_at, completed_at | scope IN ('plant','account'); при account delete удалить связь owner из linked_owner_ids, сохранив обезличенные маркеры расхода стартовых попыток установки; revoke_access → purge_storage → purge_data → revoke_apple → delete_auth |

### Свет и подтверждение (FR-034, FR-047)

`light_code IN ('low','bright_indirect','direct_sun','unknown')`, `watering_code IN ('several_weekly','weekly','less_often','unknown')`, `drainage_code IN ('yes','no','unknown')`.
`light_source IN ('manual','camera_estimate','unknown')`:

- manual: известная категория выбрана пользователем, light_confirmed = true;
- camera_estimate: только low / bright_indirect, light_confirmed = true после явного подтверждения; false допускается лишь в несохранённой локальной оценке, не в snapshot для анализа;
- unknown: light_code = unknown, light_confirmed = false. Неудачная/пропущенная оценка сохраняется как unknown; direct_sun выбирается только вручную.

### Overrides и перенос (FR-046, US2.9–US2.13)

Overrides — частичный объект `taxon_id`, `conditions`, `room_id` или `new_room_name` (два последних взаимоисключающие); пропущенный ключ означает «сохранить», null — явное удаление допустимого значения. Комната должна принадлежать владельцу; новая создаётся в транзакции публикации.

При claim исходные фото, результат и snapshot копируются под владельца, исходное содержание анализа не переписывается. Без содержательного изменения вида/условий новый экземпляр имеет care_revision = 1. Если вид или условия изменены, транзакция создаёт новый актуальный snapshot, устанавливает care_revision = 2 и `analysis_results.context_state = 'stale'`; исходный анализ ссылается на сохранённую копию исходного snapshot версии 1. Одно изменение комнаты не создаёт новый контекст ухода. Повтор операции не повышает revision ещё раз.

При истекшем guest TTL `plant.create` принимает локальный fallback: нормализованное фото загружается заново, результат и исходный snapshot проверяются по подписанной сервером analysis_receipt (job ID, installation ID, locale, хеши фото/результата/исходных условий, факт успешного учёта). Подпись не выдаёт доступа к чужой коллекции. Секрет установки и permanent JWT подтверждают право переноса. Документ с клиента без проверяемого происхождения не становится доверенным AI-результатом. Если кеш неполон, сохраняются доступные сведения без выдуманного анализа; причина показана, стартовые попытки не возвращаются. Origin draft ID одинаков для claim/fallback, поэтому гонка двух путей даёт один экземпляр.

## 3. Анализы, планы и уход

| Сущность | Ключевые поля | Ограничения |
| --- | --- | --- |
| analysis_jobs | id, owner_id, flow_id, intent, add_method, draft_id nullable, plant_id nullable, mode, kb_release_id, schema_version, prompt_version, plan_source nullable, source_analysis_id nullable, previous_analysis_id nullable, operation_id, payload_hash, locale, photo_ids, snapshot_id, expected_care_revision, quota_kind, quota_state, quota_installation_id nullable, quota_owner_id nullable, monthly_quota_id nullable, state, lease_token nullable, provider_started_at nullable, created_at, deadline_at, usage JSONB, error_code nullable | mode IN ('identification','diagnosis','plan','follow_up'); state IN ('queued','running','succeeded','failed','timed_out'); UNIQUE(owner_id, operation_id); quota_kind IN ('starter_identification','starter_diagnosis','free_monthly','paid_monthly','none'); quota_state IN ('reserved','consumed','released','not_applicable'); резерв хранится в job, отдельных slot/reservation таблиц нет |
| analysis_results | id, origin_analysis_id, mode, job_id, origin_job_id, owner_id, plant_id nullable, draft_id nullable, source_photo_id, source_snapshot_id, source_care_revision, locale, kb_release_id, classification JSONB, condition_candidates JSONB, protocol_id nullable, identification JSONB, diagnosis_status, probable_cause, evidence_basis JSONB, limitations JSONB, first_action JSONB, source_ids, context_state, result_hash, analysis_receipt, created_at | mode=identification: diagnosis_status/probable_cause/first_action = null, evidence_basis = {visible_symptoms: [], condition_factors: []}, limitations отражает неопределённость вида; context_state IN ('current','stale'); evidence_basis = {visible_symptoms: string[], condition_factors: string[]}; limitations = string[]; origin_analysis_id = исходный result UUID, origin_job_id неизменны при переносе; квота уже учтена до receipt |
| care_plans | id, job_id nullable, operation_id nullable, owner_id, plant_id, locale, plan_kind, access_tier, attribution_flow_id nullable, source_kind, source_analysis_id nullable, source_photo_id nullable, snapshot_id, kb_release_id, diagnostic_decision_id nullable, diagnostic_decision_revision nullable, treatment_start_local_date nullable, protocol_id nullable, care_profile_id nullable, context_revision, version, full_body JSONB, next_check_date nullable, comparison_traits JSONB, photo_angle_hint TEXT nullable, state, created_at, updated_at | ровно одна связь job_id/operation_id; plan_kind IN ('routine','recovery'); routine требует source_kind=catalogue, recovery — analysis; source_kind IN ('analysis','catalogue'); catalogue = источник проверенных правил, включая care после скана; state IN ('active','superseded'); access_tier IN ('basic','full'); basic только routine; генерация full требует paid access; опубликованный собственный full читается после expiry; analysis-план может быть построен по stale-анализу, но на актуальном snapshot |
| task_rules | id, plan_id nullable, first_aid_id nullable, owner_id, plant_id, access_class, rule_state, action_code, condition_code, interval_days, algorithm_version, algorithm_params JSONB, applied_modifiers JSONB, treatment_step_id nullable, start_offset_days, repeat_count, repeat_index, treatment_start_local_date nullable, phase nullable, check_offset_days nullable, comparison_traits JSONB, photo_angle_hint TEXT nullable, source_ids | access_class IN ('basic_care','first_aid_control','premium'); rule_state IN ('active','paused','superseded'); ровно одна связь plan_id/first_aid_id; basic_care только условные проверки грунта, first_aid_control только единственный контроль, premium — расширенный уход; интервалы по проверенному care_profile; check_up хранит непустые comparison_traits и подсказку ракурса |
| care_tasks | id, owner_id, plant_id, rule_id nullable, occurrence_key, action_code, due_local_date, timezone, condition_code, reminder_eligible BOOLEAN, inactive_reason nullable, localized_reason_snapshot JSONB, comparison_traits JSONB, photo_angle_hint TEXT nullable, state, revision, completed_entry_id nullable, updated_at, deleted_at | UNIQUE(plant_id, occurrence_key); state IN ('open','completed','superseded','needs_review'); первый water при неизвестной истории: condition_code = 'check_soil_first' |
| care_entries | id, owner_id, plant_id, task_id nullable, action_code, occurred_at, occurred_local_date, timezone, recorded_at, state, operation_id, updated_at | state IN ('active','voided'); UNIQUE(task_id) WHERE state = 'active'; исправление даты сохраняет ID записи |
| care_reversals | id, owner_id, entry_id, operation_id, recorded_at | UNIQUE(entry_id); отмена переводит entry в voided; история не удаляется |
| schedule_changes | id, owner_id, plant_id, from_date, to_date, cause_code, source_event_id, explanation_code, created_at | объяснение изменения следующей проверки |

### Жизненный цикл планов и задач

- `mode=plan, plan_source=analysis`: сохранённые наблюдения/кандидаты + текущие taxon/snapshot + применимый ConditionProfile. Stale допускается только после проверки применимости; иначе reassessment_required. Сам анализ не меняется; care_revision до commit проверяется.
- Plan access_tier=full требует paid access на старте/публикации; basic требует включённого базового ухода и доступного места либо paid access; quota_kind=none, provider_started_at=null и usage без provider call. Ни фото-, ни provider budget не расходуются; offline synthesis имеет отдельный бюджет.
- Обычный персональный plan после скана или каталога имеет source_kind=catalogue, учитывает подтверждённый вид и текущие условия, детерминирован, без LLM и фотоквоты; отсутствие reviewed care_profile явно возвращается ошибкой.
- Публикация плана/правил/первых задач атомарна. Восстановление содержит recovery_check, его comparison_traits/photo_angle_hint копируются в план, правило и контрольную задачу. Для обычного каталожного ухода без контрольной проверки comparison_traits = [], photo_angle_hint = null.
- Новый occurrence требует применимого правила и разрешения по access_class: basic_care — выбранное Free-место либо paid access; first_aid_control — один контроль первой помощи без места; premium — paid access. Paid access означает state active/grace с подтверждённым сроком, включая trial (offer_kind=trial). После expiry новые premium occurrences закрыты, базовая тройка продолжает уход. Существующие задачи/факты сохраняются; одно ближайшее вхождение на правило.
- Смена вида/условий переводит незавершённые задачи неприменимого плана в needs_review. Такой статус допускает выполнение в один тап, отмену и напоминание; текст помечает необходимость пересмотра, не повторяет старые указания как актуальные. Повторный уход пересчитывает существующие даты по текущей истории; новый occurrence по старому плану не вставляется.
- Команды care.record/care.undo сериализуются строкой растения и сохраняются независимо от expected_revision, если владелец активен, растение существует и данные валидны. Повтор record той же задачи возвращает уже активную запись, undo уже отменённой записи — успешный no-op с receipt. Это не новая отметка ухода.

## 4. Подписки, стартовые и месячные квоты

| Сущность | Ключевые поля | Ограничения |
| --- | --- | --- |
| purchase_ownership | environment, original_transaction_id, owner_id, app_account_token, first_verified_access_at, created_at | PRIMARY KEY(environment, original_transaction_id); один app account; первый доступ, включая trial, задаёт profiles.quota_anchor_at |
| subscription_events | notification_uuid, environment, transaction_id, verified_payload JSONB, processed_at, state | дедупликация Notifications V2; поздний webhook не откатывает статус; факты trial/оплаты/продления/refund раздельны |
| entitlements | owner_id, product_id, state, offer_kind, valid_until, grace_until, trial_end_at nullable, auto_renew_enabled, checked_at, updated_at | state IN ('active','grace','billing_retry','expired','revoked'); offer_kind IN ('trial','paid'); paid access только до подтверждённого active/grace; trial_end_at подтверждён магазином, не вычисляется как локальные now+7d |
| installation_access | id, credential_hash, starter_identification_consumed, starter_diagnosis_consumed, starter_identification_job_id nullable, starter_diagnosis_job_id nullable, first_starter_success_at nullable, linked_owner_ids UUID[], created_at, updated_at | flags BOOLEAN NOT NULL DEFAULT false; отдельный живой job на режим; secret только в Keychain; cleanup draft не сбрасывает расход |
| monthly_quotas | id, owner_id, quota_kind, period_start, period_end, limit_count, consumed_count, reserved_count, updated_at | quota_kind IN ('free_monthly','paid_monthly'); UNIQUE(owner_id,quota_kind,period_start); free limit=1, paid limit=100; CHECK(consumed_count >= 0 AND reserved_count >= 0 AND consumed_count + reserved_count <= limit_count) |
| provider_daily_budget | utc_date DATE PRIMARY KEY, started_calls INT, max_calls INT, input_tokens BIGINT, output_tokens BIGINT, updated_at | started_calls >= 0; max_calls > 0; started_calls <= max_calls; cap обязателен до live AI |

### Атомарный выбор источника квоты

1. После lookup receipt блокируются profiles владельцев по UUID → installation_access по UUID → monthly_quotas по (owner_id,quota_kind,period_start) → plants/дочерние строки. Резерв и его terminal state находятся в analysis_jobs; сеть выполняется вне row lock.
2. При paid access identification/diagnosis/follow_up используют только paid_monthly. Исчерпание 100 не открывает запасные starter/Free; plan, сохранение фото, уточнение, отчёт и контроль без AI не расходуют фотоквоту.
3. Без paid access identification/diagnosis сначала используют неистраченный starter соответствующего режима, затем доступный free_monthly. Занятый резерв starter возвращает analysis_in_progress, а не обходит его через месячную квоту. Follow_up требует paid access. Guest имеет только starter; permanent перед admission завершает bind. Без доступной квоты возвращается причина и следующая дата, без скрытого вызова.
4. Starter success атомарно ставит consumed у установки/аккаунта для данного режима, очищает job pointers и фиксирует минимальный first_starter_success_at. Failure/timeout освобождает pointers без расхода. Пригодные unknown/low-confidence результаты считаются успехом; это не основание для бесплатного бесконечного retry.
5. Bind/claim под теми же locks объединяет consumed через OR отдельно по режимам, first_starter_success_at через минимум непустых дат и сохраняет linked_owner_ids. Живой starter job на любой объединяемой стороне даёт retryable starter_in_progress без успешного receipt. Известная привязанная установка не запускает новый guest job после logout. Расход разных устройств/аккаунтов не обнуляется; чужие данные/месячные квоты не переносятся.
6. Free — UTC-календарный месяц [первое число 00:00, первое число следующего месяца 00:00). Первый допустимый месяц следующий за first_starter_success_at. Пока успешного starter нет, free_monthly недоступна, даже если уже был paid/trial. Остаток не накапливается; неиспользованный starter сохраняется. Free ledger не меняется при покупке/expiry/restore.
7. Paid anchor — первое подтверждённое предоставление доступа, включая trial. Окна anchor + N календарных месяцев UTC с независимым clamp дня: 31 Jan → 28/29 Feb → 31 Mar. Trial→paid/restore/смена тарифа/повторная подписка не сбрасывают anchor и расход. Поздняя сверка более раннего подтверждённого first access требует reconciliation периодов под owner lock с сохранением consumed/reserved, не выдачи новой квоты.
8. Monthly admission увеличивает reserved_count. Success переводит reserved→consumed, failure/timeout — reserved→released один раз под lease/quota_state. Job остаётся в исходном источнике/периоде через границу месяца; Free job, начатый до покупки, завершает свой резерв. Paid job при потере права до публикации освобождает резерв и возвращает entitlement_required, не переходит скрыто на Free.
9. Перед LLM короткая транзакция с project advisory lock и provider_daily_budget проверяет <=10 leases, cap/deadline; фиксирует started_calls/provider_started_at. Повтор worker не вызывает модель заново; ошибки не возвращают provider budget. Usage/cost учитываются также для ошибок отдельно от успешной продуктовой квоты. Offline synthesis имеет отдельный бюджет.

Термин trial обозначает только подписочный пробный период. Два продукта: месяц 49,99 PLN без trial и год 199,99 PLN с добровольными 7 днями для eligible; фактическая локализованная цена/eligibility берутся из магазина. Подтверждённое offer_kind определяет Trial/Paid для аналитики. Локальное отключение auto-renew не отменяет срок доступа.

## 5. Receipts и локальные данные

| Сущность | Назначение |
| --- | --- |
| operation_receipts | owner_id, operation_id, command_name, payload_hash, response_payload JSONB, committed_at; PRIMARY KEY(owner_id, operation_id); запись результата вместе с мутацией; тот же ID с иным payload — operation_payload_mismatch |
| LocalOutbox (SwiftData) | operationId, commandName, payload, expectedRevision nullable, ownerId, plantId nullable, dependsOnOperationId nullable, localState (pending/sending/confirmed/failed), createdAt; запись намерения до сети; сетевой сбой возвращает pending |
| LocalCache (SwiftData) | бесплатные Plant/Room/CareTask/CareEntry/PreliminaryResult, syncSince и page cursor; контейнер изолирован по ownerId; полный sync не удаляет outbox |
| GuestDraftCache (SwiftData + файлы) | flowId, intent, addMethod, currentStep, confirmedTaxonId nullable, originDraftId, нормализованное фото, исходные ответы, предварительный результат, analysis_receipt, overrides; локальный кеш не очищается только из-за server TTL; удаляется после подтверждённого сохранения или явного отказа пользователя |
| PlanHistoryCache (зашифрованный, owner-scoped) | ранее опубликованный личный план, версия/дата/context_revision и safety validity; expiry/refund не удаляют и не закрывают чтение; неприменимые инструкции и отозванные/просроченные средства скрываются; logout изолирует кеш |

Delta выбирается по updated_at/deleted_at с устойчивой пагинацией; точные запросы, high-watermark и replay определены в [contracts/sync.md](contracts/sync.md). Отдельные таблицы журналов изменений и серверный event-sourcing состояния приложения в MVP не используются; funnel_events ниже — отдельные продуктовые метрики, а не механизм синхронизации. Nullable ссылки профиля на job добавляются FK после создания analysis_jobs, без циклической зависимости миграций.


## 6. Намерение и события воронки (FR-049–FR-051)

`intent IN ('problem','care')` отделён от `add_method IN ('scan','catalogue')`.
В problem допустим scan, в care — оба метода. До выбора method/intent могут быть null
только в локальном состоянии/событии открытия. Flow UUID создаётся при начале добавления,
сохраняется при возврате, перезапуске незавершённого сценария и входе; новое добавление — новый flow.
Creation intent/source фиксируют происхождение экземпляра, а не ограничивают последующий уход.
Поля intent/mode/flow и исходные хеши включаются в подписанный analysis_receipt для claim/fallback.
При identification исходные условия unknown; последующее заполнение/исправление передаётся
через существующие overrides. Изменение условий не требует повторного определения вида.

| Сущность | Поля / ограничения |
| --- | --- |
| funnel_events | event_id UUID PRIMARY KEY, semantic_dedup_key TEXT UNIQUE, flow_id UUID nullable, owner_id (серверный JWT; ON DELETE CASCADE), installation_id, intent nullable, previous_intent nullable, add_method nullable, step, event_source (client/server), access_tier, source_context, context_id nullable, occurred_at, verified_at nullable, received_at; фиксированные enum, без фото, diagnosis, названий комнат и свободного текста; прямой клиентский SELECT/INSERT запрещён RLS, запись только через проверенный API |
| AddFlowState (SwiftData) | flowId, initialIntent, currentIntent, addMethod, currentStep, selectedPhoto nullable, confirmedTaxonId nullable, answers, draftId nullable; возврат не стирает совместимые данные; хранится до завершения/явного отказа |
| FunnelOutbox (SwiftData) | eventId, flowId, fixedPayload, deliveryState; сохраняет UUID при повторе, работает до входа; не блокирует основной сценарий |

Steps клиента: flow_started, intent_selected, intent_changed, method_selected, species_confirmed,
paywall_shown, paywall_dismissed, trial_requested, report_viewed, app_opened, paid_action_requested.
Steps сервера: result_ready, plant_saved, first_useful_task_created, care_completed,
free_monthly_scan_used, trial_started, trial_ended, purchase_confirmed, renewal_confirmed,
access_expired, refund_confirmed, plan_created. Restore не создаёт покупку; trial_requested не означает trial_started.
У каждого события есть access_tier Free/Trial/Paid, subject installation/account, source_context
(onboarding/plant/free_scan/report/today/profile), фиксированные IDs контекста и server verified time для серверных фактов.
flow_id nullable для событий вне добавления; event_id и semantic dedup_key уникальны.
Клиент не может прислать серверное событие/цену/usage; неизвестные поля отклоняются.
При входе события привязываются по существующему owner proof/credential, а не знанию flow_id;
catalogue-only использует тот же proof без AI. До входа уникальность только на установку.

Отдельные server-only billing_facts (UNIQUE(environment,transaction_id,fact_kind)) содержат
verified amount/currency, period, refund linkage; provider_usage (UNIQUE(job_id,provider_attempt_id))
хранит tokens, model, tariff_version, cost/currency, usage_state known/unknown и installation/account attribution.
Неизвестная фактическая стоимость не становится нулём. Финансовые суммы разных валют не складываются без явного курса/даты.
Сервисный отчёт разделяет flow conversion и уникальные installations/accounts, intention/method,
Free/Trial/Paid, когорты и полные окна D7/D30/первого продления. Возврат после отказа и повторное
использование выводятся из app_opened и фактических действий; trial→оплата и первое продление — разные события.
Знаменатели и наблюдаемый период явны; выручка за 30 дней не называется LTV.
Фото, диагнозы, наблюдения, свободный текст и названия растений/комнат в аналитику не входят.

## 7. KB pin, обновление и расчёт дат

Job/result/plan фиксируют kb_release_id; analysis_receipt подписывает также release,
версию схемы и hash готовой бесплатной проекции. Follow-up использует совместимые
словари, старые наблюдения интерпретируются по своему релизу. Новый опубликованный
релиз не переписывает историю. Применение нового профиля к экземпляру — явное
обновление плана с новой версией; rollback меняет default release, не чужие факты ухода.

ScheduleCalculator получает care_profile/protocol из плана и применяет только
подтверждённые параметры. Месяцы сезона, min/max days, unknown fallback и множители
входят в алгоритм релиза и его evidence. Pot_type и season_override доступны необязательно в онбординге; материал не определяется
по фото. Unknown pot/неизвестное отопление не применяют множитель (нейтральный 1). Для semi-hydro
обязательна отдельная стратегия. FC не вычисляются из camera_estimate.

Схемы provider 1.2/2.0 заменены 3.0 до реализации; client-facing поля first_action/full_body
остаются backend-проекцией базы. Развёрнутых данных нет; при импорте старых fixtures
нужен явный mapping и повторная валидация, а не перенос сгенерированных советов как Golden.

## 8. Уточнение диагноза и лечебные задачи (полный промпт)

| Сущность | Поля | Ограничения |
| --- | --- | --- |
| diagnostic_decisions | id UUID, revision INT, origin_decision_id nullable, analysis_result_id, owner_id, kb_release_id, policy_version, context_revision, original_candidates JSONB, answer_snapshot_ids, decision_scores JSONB, selected_condition_id nullable, state, first_action_projection, decision_receipt, created_at | PRIMARY KEY(id,revision); версии append-only, current — последняя; awaiting_answers/resolved/uncertain/skipped/stale; max 2 различных вопроса на id |
| diagnostic_answers | id, decision_id, question_id, answer_revision, answer (yes/no), operation_id, received_at, owner_id | immutable, UNIQUE(decision_id,question_id,answer_revision); не более 2 distinct question IDs; редактирование — новая версия, не повторное добавление веса |

kb_releases.disambiguation_policy: confidence_threshold=0.80, closeness_delta=0.10,
max_questions=2, answer_weight=0.15, policy_version. Это первоначальные параметры;
полный отчёт eval отделяет routing heuristic от калиброванной вероятности.
Question IDs и yes/no targets принадлежат pinned ConditionProfile/паре кандидатов.
Ранги 1/2, различные condition IDs, scores по убыванию, confidence в [0,1].
`visual_markers` в provider 3.0 — коды опубликованного словаря; прежние symptom IDs
интерпретируются этим словарём, свободный текст не даёт новых диагностических признаков.

При diagnosis/follow_up пригодная классификация + безопасная помощь завершают job и
однократно расходуют квоту. Затем решение/ответы обновляются без провайдера/квоты;
повтор operation_id возвращает ту же версию. После общих блокировок profiles владельца → plant (если есть), под блокировкой
root decision id проверяются
owner, текущий care_revision, expected_revision/ожидаемый вопрос и уникальность операции.
Правка ответа создаёт новую answer/decision revision и пересчитывает ОТ исходных scores
и последнего snapshot ответов, поэтому вес не накапливается при retry/редактировании.
Выбранные condition/profile должны быть применимы к текущему taxon; смена контекста
помечает решение stale. Analysis payload остаётся неизменным.

analysis_receipt и decision_receipt разделены: второй связывает analysis hash/release,
policy, вопросы/ответы, решение/версию и hash бесплатной проекции. Claim/TTL переносит
все проверенные версии/receipt; pending ввод обрабатывается как новый пользовательский
ответ по тому же root после восстановления, а не как доверенный server decision.
GuestDraftCache и SwiftData содержат pending answers/current question/receipt/revision.
В sync выдаются только собственные summary/answers, без полного банка вопросов/планов.
Recovery plan ссылается на (diagnostic_decision_id,revision); API поле protocol_id
обозначает конкретную версию condition_profiles.id, не новый свободный протокол.

condition_snapshots: pot_type = terracotta/plastic/glazed_ceramic/other/unknown
(default unknown), season_override = auto/summer/winter (default auto). Эти поля
передаются в conditions/overrides, изменение повышает care_revision. Auto season
считается от текущей локальной даты по календарю релиза при каждом расчёте;
это не измерение реального микроклимата. Heating unknown не угадывается.

Task action codes дополнены isolate/wash_pests/treat_pests; rule хранит phase,
step ID, конечные повторы и дату старта. occurrence_key включает plan/step/repeat index,
UNIQUE исключает дубль. Один шаг — одно правило; timeline можно вычислить целиком,
но INSERT только ближайшего premium occurrence по каждому правилу и только с paid access. Бесплатная первая помощь/контроль учитываются отдельно; начало полного лечения не дублирует уже выполненное совместимое действие (см. §9).
Нулевой interval допустим при одном выполнении. Отмеченный по care.record факт определяет
проверку интервала следующей обработки; delay не означает исполнение шага или двойную дозу.
Отозванный/неподтверждённый продукт блокирует инструкции и новые treatment occurrences;
история сохраняется, existing tasks могут получить needs_review.

Sync отдаёт последнюю decision summary на стабильный id с новой owner watermark,
а не все строки composite PK(id,revision) как разные сущности с одинаковым cursor id.
Полная история revisions читается owner API отдельно. Diagnostic commands соблюдают
общий порядок блокировок/operation receipts и монотонную updated_at профиля.

## 9. Free-уход, первая помощь и переход к обычному уходу

| Сущность | Поля | Ограничения |
| --- | --- | --- |
| basic_care_memberships | id, owner_id, plant_id, enabled_at, enabled, free_slot nullable, updated_at, deleted_at | UNIQUE(owner_id,plant_id); free_slot INT CHECK(free_slot BETWEEN 1 AND 3); UNIQUE(owner_id,free_slot) WHERE free_slot IS NOT NULL; free_slot требует enabled; paid позволяет enabled без free_slot |
| first_aid_followups | id, owner_id, plant_id, origin_analysis_id, decision_revision, kb_release_id, protocol_id, action_code, first_action_snapshot, check_policy_snapshot, action_entry_id nullable, control_task_id nullable, context_revision, state, updated_at | UNIQUE(owner_id,plant_id,origin_analysis_id); одна связь с контрольной задачей; повтор сохранения/уточнения/выполнения не создаёт второй контроль; источник plan не обязателен |
| care_observations | id, owner_id, plant_id, task_id, status_code, note nullable, photo_id nullable, observed_at, operation_id, updated_at, deleted_at | status_code IN ('improved','unchanged','worse','unknown'); фото своё того же экземпляра; без AI/квоты; заметка только личная история, не аналитика |
| recovery_transitions | id, owner_id, plant_id, recovery_plan_id, observation_id, expected_care_revision, operation_id, state, routine_plan_id nullable, created_at, updated_at | UNIQUE(owner_id,operation_id); explicit_requested/confirmed/reassessment_required; нет автоматического recovered по задачам/времени |

Включение basic care — явная команда. Первые три включённых экземпляра занимают свободные
места; четвёртый сохраняется в коллекции, но Free-активация предлагает выбор тройки/подписку.
При paid access число enabled не ограничено; free_slot сохраняет предпочтения для expiry.
basic_care.enable вызывает детерминированную сборку basic plan внутри команды; care_plans.operation_id
связывает результат с receipt без обязательного analysis job. Явное обновление уже включённого basic
через mode=plan может использовать job_id; ни один путь не вызывает Vision.
Выбор тройки заменяется атомарно под profiles lock и free_selection_revision; select проверяет
профиль/условия каждого указанного собственного растения и может включить ранее не enabled экземпляр
в той же транзакции, освободив исключённое место. Ошибка одного профиля откатывает весь выбор.
Явный выбор, включая пустой, задаёт free_selection_explicit=true; коллизия возвращает
free_selection_changed с текущим выбором (это не конфликт команды факта ухода).
Expiry использует выбранные места (включая явный пустой выбор); только при отсутствии явного
выбора и сохранённых мест — первые три enabled_at, tie-break plant_id.
Удаление экземпляра освобождает место, не включает чужое растение молча; eligibility пересчитывается
при командe, foreground и billing/maintenance, а не зависит от своевременного webhook.

При снятии Free-места вне paid access правило basic_care paused, старые задачи сохраняют ID/state,
но reminder_eligible=false/inactive_reason=free_slot_removed. Обычные старые premium задачи после
expiry остаются доступными по FR-020; их выполнение не создаёт новый premium occurrence.
В paid access изменение предпочтений Free не выключает оплаченный basic care.
Возврат в basic care требует актуального вида/условий; проверяется история, старый открытый occurrence
повторно используется или superseded с объяснением. Ни просрочка, ни pause не создают факт выполнения.

Basic plan access_tier=basic содержит только условные проверки грунта и объяснения; пересчёт/обновление
бесплатны в пределах места. Платный routine план не создаёт вторую водную цепочку: один активный
basic rule family на plant; premium дополняет его подкормкой/пересадкой/расширенным контролем.
care.postpone меняет due_local_date и schedule reason, не создавая care_entry/дополнительный occurrence;
допускается только перенос базовой проверки, не химических обработок вне проверенных интервалов.

Первое действие доступно до входа; после сохранения first_aid.record создаёт факт и максимум один
контроль из применимого опубликованного protocol/fallback, без full plan/paid access/Free-места.
Срок считается по опубликованному правилу относительно фактического выполнения, не фиксированным 72ч.
Нет action/check policy — reason_code, без выдуманной задачи. Undo/correct_date пересчитывают тот же
контроль; при отмене исходного действия незавершённый контроль сохраняет state/ID, получает
reminder_eligible=false/inactive_reason=first_action_undone; rule_state=paused. Выполненные факты
сохраняются. Повтор record после undo переиспользует связь, пересчитывает дату и после проверки
применимости возвращает rule_state=active/reminder_eligible=true с очисткой inactive_reason. Наблюдение/фото контроля бесплатны;
follow_up AI запускается отдельно по явному запросу с paid access.
При старте полного лечения resolver сопоставляет уже выполненное first_action с protocol step,
условиями и фактической датой; один факт может удовлетворить соответствующий шаг без повторного
назначения. Неэквивалентные действия не объединяются, конфликты требуют пересмотра.

recovery.transition требует наблюдение текущего состояния, применимость и явное подтверждение.
Ухудшение/unknown/устаревший контекст → reassessment_required с уточнением и явным доступным анализом,
без скрытой покупки/скана. Успешный переход атомарно supersede незавершённые recovery rules,
сохраняет факты, создаёт/актуализирует единственный basic care в пределах прав; extended routine —
только отдельным запросом с paid access. Нет места — free_slot_required до изменения расписания.

## 10. Progress Report и добровольные уведомления

Отчёт — вычисляемая owner-проекция, не второй журнал: month=YYYY-MM, timezone=IANA.
Границы завершённого календарного месяца переводятся в UTC; действия фильтруются по occurred_at
в [start,end), только active entries, отмены/исправления учтены. Фото используют capture_at либо неизменяемый uploaded_at (только ready)
с date_source=capture/upload; наблюдения — observed_at. Текущие ближайшие задачи
возвращаются отдельно от итогов прошлого месяца. Нет AI/фотоквоты/оценки здоровья.
Response включает period/timezone, data_as_of owner watermark, coverage_start, partial_month,
missing_data flags и нейтральные пояснения. Отсутствие записей не означает отсутствие ухода.
Кеш ReportCache ключуется owner+month+timezone+locale+watermark, инвалидируется изменением истории;
офлайн показывает дату кеша и pending changes, не объявляет неподтверждённые операции итогом.

| Сущность | Поля | Ограничения |
| --- | --- | --- |
| notification_claims | id, owner_id, kind, period_key, installation_id, scheduled_at, state, updated_at | UNIQUE(owner_id,kind,period_key); kind IN ('progress_report','trial_end'); progress period_key=YYYY-MM без timezone; trial key=original_transaction_id+trial_end_at; reserved/scheduled/cancelled; отмена не разрешает другой установке второй report |

Opt-in хранится в profiles отдельно для report и trial, default false. Локальный UserNotifications
планирует report на первый день после отчётного месяца в выбранный час, trial — за 24ч до подтверждённого
trial_end_at. Серверный claim разрешает одно устройство/месяц; потеря связи/отмена может пропустить
уведомление, но не повторить его. Payload/ID фиксируются до scheduling, replay на том же устройстве
только сверяет pending/delivered; отсутствие обоих после неопределённого результата не повод отправить ещё раз.
На смене timezone уже отправленный report не повторяется; ещё pending переносится с тем же ID.
При смене trial-end/expiry/refund/opt-out удаляются прежние локальные requests, дата остаётся в UI.
Report доступен при первом открытии нового месяца без уведомления; создание claim заранее не создаёт
сам отчёт и не позволяет показать незавершённый месяц как завершённый.
