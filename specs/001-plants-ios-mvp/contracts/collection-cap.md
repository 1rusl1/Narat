# Collection cap — API/sync addendum (T161)

Дополнение к [api.md](api.md) и [sync.md](sync.md), 2026-11-09.
Описывает реализованную серверную границу, а не принятие пользовательского сценария.

## Коллекция и ошибки

SQL `202611090003_collection_cap.sql`: без verified paid access новое живое
растение допускается только при count < 3; paid/trial снимает этот лимит.
Считаются все неудалённые экземпляры owner, независимо от enabled care/старых мест.
Триггер на `plants` покрывает INSERT, восстановление tombstone и перенос owner,
включая прямых табличных writers, command RPC и claim writers, дошедших до таблицы.
Обычная правка/удаление не требуют свободного места. Вставка уже удалённой строки
не занимает место. Owner сериализуется через profiles; stale RR/serializable writer
должен повторить транзакцию после serialization failure, а не обходить cap.

Отказ SQL: `COLLECTION_LIMIT_REACHED` (P0001). Это лимит коллекции, не квота
фотоанализов и не требование выбрать три места. HTTP mapping этого отказа в
общем commands/claim router данным срезом не добавлен. `owner_profile_not_found`
(P0002) и `account_not_active` (42501) сохраняют owner boundary.
Атомарный отказ не должен оставлять растение/расход/новый успешный receipt.
Положительный guest claim ещё не принят: покрытие триггера не доказывает весь claim flow.

## Basic care и старые receipts

Активный TS command DTO: только `basic_care.enable|basic_care.disable`,
`operation_id`, обязательный `plant_id`; selected_plant_ids не принимается.
Новый state: `has_paid_access`, `memberships`; membership содержит только
`plant_id/enabled/enabled_at`. Нет resolveActiveFreePlantIds, Free-мест или
автоматического выбора первых трёх. HTTP передаёт новый payload только с plant_id.

`free_care.select` — исключительно compatibility replay через authoritative SQL:
owner/profile validation, затем lookup receipt, затем для новой операции
400 VALIDATION_ERROR / FREE_SELECTION_RETIRED. Исторический exact replay возвращает
сохранённый ответ без преобразования, включая исторические slot/selection поля.
Тот же operation_id с другим command/payload получает 409 CONFLICT
(`operation_payload_mismatch`), без нового успешного select.

Hash остаётся прежним SQL:
`encode(digest(coalesce(p_payload::text, '{}'), 'sha256'), 'hex')`.
Это PostgreSQL jsonb text, не JSON.stringify на клиенте; SQL NULL даёт '{}',
JSON null — 'null'. Legacy HTTP adapter сохраняет старую проекцию: truthy plant_id
и truthy selected_plant_ids копируются без сортировки/дедупликации/проверки массива;
null/false/отсутствующее поле опускается, пустой массив сохраняется.
Не следует включать operation_id/command_type или новые ключи в hashed payload.
Поэтому null/некорректный selection также проходит receipt lookup в SQL.
Новые typed DTO не описывают исторический ответ.

EntitlementGate допускает basic care для active owner, enabled/nondeleted membership
при verified paid access либо snapshot subscriptionState=none И offerKind=none
(представление отсутствия subscription history). Expired/revoked/billing_retry,
неподтверждённый paid или grace после verified срока не возвращают Free care
даже при старом slot. SQL дополнительно проверяет живое растение, active plan,
совпадение context revision/snapshot и остаётся authoritative для scheduling.
Чтение старых планов, chemical applicability, первая помощь и analysis quota не меняются.

## Sync и границы готовности

SQL `202611090004_retire_free_slots.sql` удаляет free_slot из активных membership
проекций и free_care_selection_explicit из profile sync. Порядок
updated_at/entity_type/id, since/until, cursor, watermark и tombstones сохранены.
Старые физические поля, исторические receipts, растения/фото/история не очищаются;
upgrade не запускает reconciliation. Старые receipts не переписываются в новый DTO.
Owner/RLS, media и quota не меняются.

`plants-api/basic-care.ts` НЕ подключён в production `index.ts`.
HTTP fixtures вызывают реальный handler с fake Supabase RPC; это не live интеграция
и не подтверждение доступности маршрута. SQL clean/upgrade/race gates и Deno fixtures
остаются обязательными проверками контроллера; этот документ не объявляет их пройденными.
Клиент и pending/outbox adaptation — T162; полный expiry/automation lifecycle — T164.
Positive guest transfer, T155/T158 и весь пользовательский runtime остаются открытыми.
