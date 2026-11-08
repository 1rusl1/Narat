# Data Model: Narat iOS MVP

**Целевой пересмотр 2026-11-08.** [Переход и правила](contracts/revision-2026-11-08.md), [spec](spec.md). Существующие SQL/JSON Schema не объявляются соответствующими этой редакции: T155 и переоткрытые foundation-задачи готовят forward migration и проверку upgrade. OPEN-PLAN / T156 отложен.

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
| kb_releases | id UUID, version, schema_version, manifest_hash, seed_version, condition_manifest_version, prompt_version, guardrail_version, validation_report, state, published_at | draft/validated/published/retired; один текущий published, pin старых сохраняется; целевые партии фактов публикуются независимо; общий охват MVP — SC-016 |
| catalogue_releases | id, version, source_doi nullable, source_hash, published_at, state, kb_release_id nullable | базовый релиз каталога (`skeleton-300-v1`, 606 видов) может публиковаться и обслуживаться с `kb_release_id = null` до готовности правил ухода и протоколов проблем; в каждый момент не более одного `state = 'published'`; переключение и откат выполняются через `publish_catalogue_release` |
| catalogue_release_species | release_id, taxon_id, plant_id, accepted_scientific_name, scientific_name, scientific_name_status, wikidata_id, source_revision, rank, genus, family, common_names JSONB, search_aliases JSONB, descriptions JSONB, hero_image JSONB, watering JSONB, external_taxon_ids JSONB, name_source JSONB, gaps JSONB, care_profile_available BOOLEAN, status | PRIMARY KEY(release_id, taxon_id), UNIQUE(release_id, plant_id); изолирует staging/draft/retired снимки видов от активного опубликованного релиза и сохраняет предыдущие снимки при переключении/rollback; `watering.intervals_days.{spring,summer,fall,winter}` хранит `int (1..365) | null` (все 4 ключа обязательны; null — отсутствие регулярного интервала у источника, без построения расписания; минимум 2 активных сезона, кроме `watering_method = 'immersion'`) |
| catalogue_taxa | id UUID, release_id nullable, plant_id TEXT UNIQUE, accepted_scientific_name, scientific_name, scientific_name_status, wikidata_id nullable, source_revision nullable, rank, family, genus nullable, common_names JSONB, search_aliases JSONB, descriptions JSONB, hero_image JSONB, watering JSONB, external_taxon_ids JSONB, name_source JSONB, gaps JSONB, care_profile_available BOOLEAN, status | `plant_id` стабилен при переименовании; материализует активный `published` релиз из `catalogue_release_species` (видимость в поиске, карточке и `plant.create` строго ограничена `status = 'published'` и принадлежностью к активному `catalogue_releases.state = 'published'`) |
| taxon_external_ids | taxon_id, provider, external_id, source_release, redirect_target | UNIQUE(provider, external_id, source_release); Perenual/WFO/RHS/NC State/GBIF/IPNI/POWO/TROPICOS IDs внешние |
| taxon_names | id, taxon_id, language, kind, value, normalized_search, source_id nullable, source_property nullable, source_revision nullable, review_status | PL/EN/la, scientific/common/synonym/trade; species-level aliases без циклов; нормализованный индекс для регистро- и диакритико-независимого поиска |
| catalogue_media | id, taxon_id, file_title nullable, original_page, local_path nullable, storage_path nullable, sha256, width nullable, height nullable, mime_type nullable, byte_size nullable, author, credit nullable, license_id, license_url, attribution, modifications nullable, is_hero BOOLEAN, review_state | только approved (`is_hero = true` для основной карточки вида); лицензия и атрибуция картинки проверяются отдельно и не перезаписываются пользовательским фото экземпляра |
| evidence_sources | id, source_document_id, url, retrieved_at, license_or_use_basis, validation_method, validated_at, scope | field_evidence JSON pointers с точным источником/фрагментом; специалист не обязателен |
| care_profiles | id, kb_release_id, taxon_id, version, profile JSONB, field_evidence JSONB, validation_report, state | PlantProfile schema, EN/PL в одном ядре, параметры/safety cat-dog, null/unknown; UNIQUE(release,taxon) |
| condition_profiles | id, kb_release_id, condition_id TEXT, version, protocol JSONB, field_evidence JSONB, state | ConditionProfile schema; UNIQUE(release,condition_id), фактический опубликованный словарь без минимального количества |
| kb_vocabularies | kb_release_id, kind, code, localized_text JSONB | symptom/check/limitation/action codes, уникальны в релизе; оба языка |
| kb_fallback_protocols | kb_release_id, fallback_id, prerequisites JSONB, actions JSONB, task_rules JSONB, content_i18n JSONB, field_evidence | healthy/unknown/out_of_scope/unknown_conditions; не считаются конкретными подтверждёнными проблемами; без специфического лечения |
| treatment_options | id, category, active_ingredient nullable, biological_agent nullable, scope | chemical/soap/biological/mechanical; вещество не означает разрешение |

Release JSON экспорт и PostgreSQL import содержат одни ID/версии/hash.
Прежний формат импорта вида: [PlantProfile](contracts/plant-profile.schema.json),
[ConditionProfile](contracts/condition-profile.schema.json). Сырые документы/полные
записи server-only; в клиентском каталоге безопасная проекция,
сохранённый персональный план выдаётся только владельцу, включая чтение после expiry; создание нового полного плана требует paid access. Unknown safety не означает безопасность.


## Аккаунт и коллекция

Профиль сохраняет owner/account_state, язык, час напоминаний, подтверждённые entitlement/trial данные, immutable `registered_at` постоянного аккаунта и общий quota anchor. Нужен различимый серверный факт остановки автоматического ухода после expiry; отсутствие активной подписки у нового Free-пользователя само по себе не означает такую остановку. Конкретная миграция состояния определяется T155 без изменения FR-020.

plants, rooms, condition_snapshots и photo_assets сохраняют стабильные ID/owner и исходные контексты. На Free новый экземпляр допускается при count<3 под owner lock; paid unlimited. Нет таблицы/поля выбора трёх active places. Удаление комнаты сохраняет растения. Исторический camera estimate не становится ручным ответом; новый ввод света manual/unknown.

Guest draft содержит succeeded_at/expires_at, фото/ответы/результат и source owner; expires_at = succeeded_at + семь суток. Действительный claim переносит результат безопасно, повтор через origin_draft_id/operation receipt не создаёт дубль. После удаления draft cached result не является источником создания analysis. Draft с уже принятым claim защищён от cleanup. Короткий proof отдельно от срока результата.

## Анализы и факты ухода

analysis_jobs хранит owner/mode/photo/locale, исходный snapshot, catalogue/KB version, quota kind/period/reserve state и provider attempt/lease. analysis_results сохраняет классификацию, ограничения и происхождение первой помощи. Никаких required diagnostic questions/answers/decision_score в новой модели. Существующие диагностические данные мигрируются без потери исходного анализа, а не принимаются как активный опрос.

care_entries/care_reversals сохраняют фактическую дату, recorded_at и связь с экземпляром/операцией. Задача не является фактом выполнения; отмена не удаляет всю историю. care_tasks различают активное назначение и приостановку по неприменимости/expiry; последние не создают напоминаний или следующих шагов. Ручная запись доступна в любом из этих состояний и не снимает паузу.

Конкретные поля care_plans/task_rules/treatment steps, порядок/длительность/завершение/обновление определяются только после T156. Наличие старых repeat_count/start_offset/diagnostic_decision полей в SQL или schemas не является принятым продуктовым требованием. История планов остаётся доступной владельцу.

## Подписки и квоты

purchase_ownership и subscription_events сохраняют принадлежность транзакции/notification_uuid и verified state. entitlements хранит active/grace/billing_retry/expired/revoked, offer_kind, valid_until, trial_end_at/auto_renew и дату проверки. Клиент не назначает себе право доступа.

installation_access хранит два independent starter consumed/job pointer; bind объединяет used flags, не передаёт чужие данные/квоты. monthly_quotas ключуется owner/kind/period_start: Free limit=3, paid/trial=100, consumed/reserved неотрицательны и не превышают лимит. Общие границы от registered_at; первое использование starter не запускает период. Выбор ledger, край коротких месяцев и перенос прежнего расхода — contracts/revision-2026-11-08.md.

provider_daily_budget и leases ограничивают стоимость/параллелизм отдельно от продуктовой квоты. Ошибочный provider call может стоить денег без списания пользовательской попытки; неизвестный usage не считается нулём. Резерв job атомарен, timeout/replay не списывают второй раз. Это внутренний контроль, не аналитический отчёт.

## Локальное хранение и события

Owner-scoped SwiftData/outbox сохраняют ожидающие действия; immutable operation receipt связывает ID с payload/ответом. Ручные записи при expiry/неприменимости синхронизируются без возобновления ухода. Известные сроки доступа проверяются локально, удалённый отзыв доступа подхватывается при связи.

Funnel events ограничены семью enum из revision-документа, event_id уникален, confirmed purchase — server-only. Нет report cache, cohort tables или report notification claim. Настройки trial reminder могут сохраняться отдельно. Все удаления полей и старых маршрутов сначала проходят T155 compatibility/upgrade, без потери пользовательских данных.
