# Sync & Offline Protocol: Narat iOS MVP

> **Синхронизация 2026-11-01:** технический дизайн приведён к спецификации Narat
> от 2026-10-30 и конституции 3.0.0: 68 FR, 25 SC, 9 историй.
> Это проект реализации; код, данные, интеграции и приёмочные испытания ещё не выполнены.

**Date**: 2026-11-01 · [API](api.md) · [Data model](../data-model.md).

## 1. Источник истины и LocalOutbox

PostgreSQL хранит подтверждённое состояние. SwiftData хранит бесплатный кеш и LocalOutbox в контейнере ownerId. Ранее полученные полные планы отделены в PlanHistoryCache и читаются после expiry/refund, включая планы trial; applicability и safety проверяются независимо от подписки. Локальные ожидающие действия не объявляются подтверждёнными.

В одной локальной транзакции до сети сохраняются operationId, commandName, payload, expectedRevision nullable, ownerId, plantId nullable, dependsOnOperationId nullable, createdAt. Payload и ID неизменны при retry. Состояния: pending → sending → confirmed; transient/network error возвращает pending; terminal validation/deletion error → failed с понятным пояснением. После crash sending возвращается в pending с тем же ID. Ручного состояния разрешения конфликтов ухода нет.

SyncEngine отправляет последовательно по растению, соблюдает dependencies (например, undo после record), разные экземпляры могут синхронизироваться независимо. При logout контейнер и уведомления отключаются; чужая очередь не отправляется с новым JWT. Полная перезагрузка кеша не стирает outbox и локальные файлы незавершённых операций.

## 2. Серверная транзакция и receipt

1. Проверить активного владельца, command name и payload. Взять profiles FOR UPDATE, затем lock растения; порядок остальных блокировок — data-model.md.
2. Проверить operation_receipts по (owner_id, operation_id), в том числе повторно после получения lock. Совпадение hash возвращает сохранённый response_payload, несовпадение — operation_payload_mismatch. Receipt живёт до удаления аккаунта, не исчезает при TTL черновика.
3. Применить команду к текущим данным, вызвать единственную SQL-функцию calculate_plant_schedule, записать schedule_changes, общую монотонную updated_at и receipt в одной транзакции.
4. Вернуть outcome applied / already_recorded / already_undone и authoritative IDs/revisions. Потерянный после commit ответ безопасно повторяется с тем же ID.

Expected revision полезен для контекста ИИ и объяснения merge; care.record, care.undo и care.correct_date не отклоняются из-за старой plants.revision/care_revision. Проверки владельца, существования растения, даты и допустимых action codes сохраняются.

### Бесконфликтный уход

- Два record одной задачи сериализуются. Partial UNIQUE(task_id) WHERE state='active' и транзакция возвращают второй команде уже существующий entry с outcome already_recorded; в receipt записывается результат второй операции без дублирования ухода.
- Повтор undo той же записи возвращает already_undone. Отмена не удаляет историю и не воскрешает запись при запоздалом replay record. Синхронизация после replay получает актуальный state записи.
- Record с task_id=null — самостоятельный факт, отдельные UUID операций означают разные действия; повтор одного ID идемпотентен.
- Изменение даты ухода обновляет существующий entry, не создаёт второй. Расписание опирается на фактическую историю, не на порядок прихода сетевых сообщений.
- needs_review допускает отметку в один тап, отмену и напоминания с пояснением статуса. Старые инструкции не показываются как актуальные. До применимого нового плана следующие occurrences по старым правилам не создаются.
- Истечение подписки не мешает принять факт ухода или изменить существующую задачу. Новый occurrence проверяет access_class: basic_care — Free-место/paid access, first_aid_control — один бесплатный контроль, premium — paid access; один прогноз без INSERT не создаёт уведомление.
- Удалённое растение возвращает plant_deleted; намерение остаётся в failed, а не бесконечно повторяется. Уход в чужую коллекцию не принимается.

Для plant.edit/room.rename/profile.update передаётся частичный patch. Разные поля объединяются; для одного поля побеждает последний принятый сервером patch. Это политика редактирования свойств, не удаления фактов ухода. Нет ручного выбора версий; ответ содержит актуальные значения. Изменённый AI-контекст не переписывает исходные snapshots.

## 3. Delta по updated_at/deleted_at

Никакой отдельной ленты событий или event-sourcing. Все синхронизируемые таблицы получают owner_id, updated_at и nullable deleted_at; tombstones сохраняются до удаления аккаунта.

Запрос: `GET /sync?since=2026-10-20T10:00:00.000000Z&limit=200`. При первом запуске since отсутствует (полная выборка). Сервер под lock profiles фиксирует `until = profiles.updated_at`: watermark последней завершённой мутации владельца. Каждая последующая мутация получает строго большую метку под тем же lock, включая изменения worker/billing/deletion. Поздно закоммиченная транзакция не может остаться за курсором.

Строки выбираются по `since < updated_at <= until`, включая deleted_at IS NOT NULL. Порядок `(updated_at, entity_type, id)`; page_token кодирует фиксированные since/until и последний tuple, привязан к владельцу и параметрам. Индекс `(owner_id, updated_at, id)` на каждой проекции. Допустимо обновление строки между страницами: новая версия за until попадёт в следующий delta, не теряется навсегда.

```json
{
  "until": "2026-10-21T08:00:00.000005Z",
  "next_page_token": null,
  "next_since": "2026-10-21T08:00:00.000005Z",
  "profile": {"preferred_locale": "pl", "reminder_hour_local": 9},
  "entitlement": {"state": "active", "valid_until": "2026-11-20T14:00:00Z", "grace_until": null},
  "changes": [
    {"entity_type": "rooms", "id": "66666666-6666-4666-8666-666666666666", "updated_at": "2026-10-21T08:00:00.000005Z", "deleted_at": "2026-10-21T08:00:00.000005Z", "data": null}
  ]
}
```

На промежуточных страницах next_since = null. Клиент применяет страницу и page_token одной локальной транзакцией; только после последней страницы обновляет syncSince = until. Restart продолжает страницу либо повторяет окно, не пропускает изменения. Старые версии не заменяют более новые; одинаковые версии применяются идемпотентно. Оптимистические данные показываются как overlay outbox поверх подтверждённого кеша.

Entity types: profiles (без auth/квотных секретов), rooms, plants, condition_snapshots, photo_assets (только безопасная metadata), analysis_summaries, care_plan_summaries, care_tasks, care_entries, care_reversals, schedule_changes, basic_care_memberships, first_aid_followups, care_observations, recovery_transitions, notification_claim_summaries. Summary анализа содержит бесплатную первую помощь и статус контекста; summary плана — ID/версия/актуальность без full_body. Квоты получаются через analysis-access, каталог — через каталоговый endpoint.

Тела полных планов, приватные Storage keys, claim proofs и signed media URLs не возвращаются. Entitlement и доступные настройки профиля возвращаются при каждом sync, даже при пустом delta. При expiry/refund PlanHistoryCache остаётся читаемым, новые full/premium действия закрыты; safety блокирует конкретные инструкции. Кеш и outbox не удаляются.

Неверный page_token/другая учётная запись → invalid_sync_cursor, клиент начинает полную выборку. Полная загрузка собирается отдельно, атомарно заменяет подтверждённый кеш после всех страниц и сохраняет outbox; последующий delta подхватывает изменения после until. Файлы невыполненных local operations не удаляются.

## 4. TTL и сохранение гостевого результата

GuestDraftCache сохраняет фото/исходные ответы/результат/analysis_receipt и overrides до подтверждённого сохранения либо явного отказа. Server TTL 24ч относится к guest_drafts/временным медиа и не сбрасывает стартовые попытки. До входа `/claims/prepare`, после входа `/claims/commit`; copying имеет отдельные состояния от DB transaction.

При draft_expired клиент после входа загружает кешированное фото в новый owner scope и ставит plant.create/source=expired_guest_draft в LocalOutbox. Сервер проверяет receipt и применяет overrides по [API](api.md); исходный контекст сохраняется, обновлённый становится snapshot версии 2 при содержательном изменении. Один origin_draft_id объединяет claim/fallback и не создаёт дубль. Нет нового AI-job и списания фотоквоты. Неполный кеш имеет явный путь сохранения доступных сведений без поддельной диагностики.

## 5. Напоминания

ReminderScheduler использует due_local_date и текущую IANA timezone устройства с profiles.reminder_hour_local: default 9, целое 0..23. Смена часа, языка или timezone перестраивает до 30 ближайших уведомлений с устойчивыми IDs по owner/task/дате; если выбранный час сегодня уже прошёл, сегодняшняя задача остаётся в списке, прошедшее время не отправляется повторно. Будущие дни используют новый час. Несуществующий местный час при DST переносится к ближайшему допустимому времени того же дня, повторяющийся час даёт одно уведомление.

Open и needs_review с reminder_eligible=true участвуют в планировании, completed/superseded/deleted — нет. Для needs_review используется нейтральный шаблон «проверьте уход» с обозначением статуса. Завершение, отмена, перенос, смена аккаунта и отзыв разрешения отменяют/обновляют соответствующие IDs. Offline клиент не создаёт подтверждённых новых задач; expiry сохраняет допустимые старые reminders, но basic задачи вне выбранной тройки получают reminder_eligible=false. Подтверждённые Free-места и срок entitlement позволяют локально снять лишние reminders даже до sync. Фактическая доставка выключенным устройством не обещается.


## 6. Незавершённое добавление и метрики

AddFlowState сохраняет flow_id, намерение, способ, текущий экран, фото и ответы.
В care режим identification выполняется до вопросов; после возвращения и входа не
запускается заново. GuestDraftCache/claim/fallback сохраняют режим результата, intent,
flow_id и receipt. Catalogue-only flow хранится локально без обязательного AI draft.
При повторном запуске незавершённый сценарий можно продолжить, завершённый onboarding
открывает Today. Переход между намерениями не расходует попытку и сохраняет совместимый ввод.

FunnelOutbox сохраняет UUID события до отправки и повторяет его с тем же payload;
отказ аналитики не задерживает сохранение растения. Перенос guest flow через одноразовый
proof описан в API; чужая очередь никогда не отправляется с новым аккаунтом. События воронки
не входят в GET /sync и не являются источником состояния коллекции. Поля origin_flow_id,
creation_intent и add_method экземпляра входят в обычную бесплатную проекцию растения.

## Golden Records и safety товаров (поправка 2026-10-25)

analysis_summaries/care_plan_summaries сохраняют kb_release_id и protocol reference
без полного протокола; версии истории не меняются при публикации новой базы.
Каталог — безопасная проекция, полные профили/лечебные протоколы не входят в sync.
Клиент получает актуальные treatment_blocks и проверяет valid_until перед показом
товара. Известный серверу отзыв применяется при связи; без сети после valid_until
химический совет скрыт до обновления. Немедленный отзыв на офлайн устройстве не обещается.
PlanHistoryCache не закрывается по сроку entitlement; устаревшие/отозванные инструкции блокируются независимо от оплаты.

## Уточнение и лечение (полный промпт)

Sync дополнен собственными diagnostic_decision_summaries/diagnostic_answers с revision,
kb release/policy/context и receipt; полный банк вопросов не включается. GuestDraftCache
сохраняет current question/pending answer и оба receipt для resume/claim/TTL.
Неоднозначность конфликтующих ответов обновляется отдельным clarification API;
бесконфликтность care.record/undo не меняется. Изменение pot_type/season_override
входит в care_revision. Task snapshots содержат phase/step ID/repeat index и ближайшую
дату; новый treatment occurrence требует active/grace и актуальной применимости.

## Narat: согласование доступа и локальных действий

Entitlement (включая offer_kind/trial_end_at/auto_renew_enabled), Free-выбор с revision и opt-ins
возвращаются при каждом sync. Истечение проверяется по подтверждённому valid_until/grace_until,
а не только по приходу webhook. До snapshot/delta сервер reconciles membership/reminder eligibility
под owner lock, чтобы idle аккаунт после expiry не сохранял оплаченные автоматические повторы.
Basic care pause снимает reminders, но не удаляет care_task/entry. На другом устройстве изменение
подхватывается при sync; немедленная отмена на отключённом устройстве не обещается. При offline
смене выбора локально снимаются затронутые reminders, активация новых мест ждёт подтверждения сервера.

free_care.select — одна owner-scoped операция с expected_selection_revision; при конфликте клиент
показывает актуальную тройку и предлагает повторить выбор. Факты care.record/undo/correct_date
по-прежнему принимаются без revision-диалога. Care.postpone не выполняет задачу. first_aid.record,
observation.record и recovery.transition имеют обычные operation IDs и сохраняются в outbox;
зависимые фото/факты отправляются перед ними. Stale переход не выключает старое расписание частично.

PlanHistoryCache хранит версии/дату/applicability и validity evidence, не полные Golden Records.
Изменение условий локально сразу отмечает известный старый контекст stale; sync обновляет маски
применимости/отзыва. Без сети по истечении valid_until химический совет скрывается; остальной
сохранённый текст доступен с датой проверки. Logout/переключение аккаунта изолирует все кеши и reminders.

RequestedAction сохраняет запрошенный платный шаг/контекст до покупки, не исполняет его при pending.
После verify/trial возобновление заново проверяет актуальность и права; отмена закрывает paywall,
сохраняет Free следующий шаг, повторный запуск приложения не показывает обязательное предложение.

Trial/report reminders отдельны от care tasks, не создают фиктивный уход. IDs включают owner/claim.
После server claim клиент атомарно сохраняет scheduling attempt до UserNotifications; при повторе
проверяет pending/delivered requests. Неопределённый исход не приводит к новому уведомлению.
Opt-out/permission denial/logout отменяют local requests; claim не освобождает месяц для второго
устройства. Trial_end reminder пересоздаётся только для нового подтверждённого срока, старый отменяется;
прошедшее время не доставляется задним числом. Report timezone меняет только pending schedule,
не period_key; уведомление опционально, отчёт доступен при открытии нового месяца.

ReportCache не синхронизируется как второй журнал: GET /reports/progress строится по подтверждённым
данным. Ключ owner+month+timezone+locale+data_as_of, при care/undo/correction/photo/observation delta кеш
инвалидируется; без сети видна дата сохранённого отчёта и неподтверждённые изменения отдельно.
User report не входит в FunnelOutbox; туда попадает лишь report_viewed с фиксированным контекстом.
