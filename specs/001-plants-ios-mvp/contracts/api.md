# Client API Contract: Narat iOS MVP

**Целевой пересмотр 2026-11-08.** Base path: `/functions/v1/plants-api/v1`. [Модель](../data-model.md), [sync](sync.md), [правила перехода](revision-2026-11-08.md). Код и машинные schemas проходят T155; наличие endpoint в документе не подтверждает живую реализацию.

## Общие правила

- Verified Supabase JWT обязателен: guest либо permanent. Owner берётся из verified JWT, не из тела; deleting/deleted аккаунты не обслуживаются. Привилегированные RPC имеют закрытые grants и фиксированный search_path.
- `X-Client-Locale: pl | en` задаёт язык нового результата. `X-Installation-Credential` нужен для installation bind/analysis/claim; секрет хранится в Keychain, сервер хранит hash, секреты не логируются. Issue — исключение первичной выдачи.
- Мутации имеют UUID `operation_id`; receipt lookup до побочных эффектов/квоты/count-check. Canonical payload hash исключает credentials/transport headers. Одинаковый ID с иным телом — 409 `operation_payload_mismatch`; replay не повторяет действие. Старый receipt не даёт право на новую операцию.
- Ошибка имеет `{error:{code,retryable,details}}`, UI использует локализованный код, не сырой SQL/provider текст. Pending не объявляется committed. Гостевой expiry — внутреннее условие возврата в обычный flow, не отдельное сообщение пользователю.

## Установка и доступ

`POST /installations/issue`: guest/permanent JWT и operation_id → credential; rate limit по установке/IP, повтор возвращает тот же защищённый результат. Новое устройство не гарантирует «один человек — один starter».

`POST /installations/bind`: permanent JWT и credential; OR used flags каждого starter, никакого переноса чужих растений/месячных квот. Живой starter job даёт retryable conflict до terminal. Регистрация существующего аккаунта не заменяется датой bind. После logout связанная установка не выдаёт starter заново.

`GET /analysis-access?mode=identification|diagnosis|follow_up`: starter flags, текущий Free/paid ledger, remaining=limit-consumed-reserved, period_start/end, selected_quota_kind и denial_reason. Guest monthly отсутствует; permanent Free=3 доступен с регистрации. Paid=100; один общий anchor регистрации без eligible_from по первому starter. Follow_up требует paid. GET не резервирует попытку; POST выбирает источник под lock. Исчерпание показывает стандартную причину/дату, не скрытый анализ.

`GET /me`: безопасный профиль, registered_at, язык/час, подтверждённый entitlement/trial date, collection_count/can_add_plant и состояние automatic care. Нет выбранных мест, report settings и внутренних секретов. Дата регистрации серверная, не редактируется profile.update.

## Фото и анализ

`POST /media/upload-ticket`: operation_id, purpose, plant/draft, content_type/byte_size/hash. Клиент нормализует/сжимает фото, сервер проверяет подготовленные байты (до 10 МБ), выдаёт private signed upload URL на 60 секунд. `POST /media/complete` сверяет реальные MIME/size/hash и owner, фиксирует uploaded_at один раз. AI derivative — JPEG с длинной стороной 1568px до отдельного eval; EXIF удаляется. Camera API используется для фотографии, не оценки света.

`POST /analysis/jobs`: operation_id, mode, ready photo_id, существующий plant_id либо draft, locale и известные условия; сервер выбирает квоту/период и фиксирует исходный контекст и версию каталога/KB. `GET /analysis/jobs/:id` возвращает owner-only pending/succeeded/failed; результат содержит классификацию и проверенную проекцию первой помощи из базы. Нет генерируемых советов/вопросов, disambiguation token или score routing. Повторная диагностика берёт только сведения того же экземпляра и фактический журнал. Technical failure освобождает резерв один раз; unknown сам по себе не делает анализ бесплатным.

Worker повторно проверяет owner/срок доступа/photo и защищает budget/lease. Начатый job остаётся в исходном ledger/периоде; expiry платного доступа до commit не превращает запрос автоматически в бесплатный. Получение плана/сохранение фото не расходуют фотоквоту.

## Сохранение результата и коллекция

`POST /claims/prepare`: свой succeeded draft до семи дней от completion → ограниченный proof (15 минут); proof можно обновить пока draft действителен. `POST /claims/commit`: permanent owner, proof, operation_id и правки вида/условий/комнаты. До admission проверить срок, затем безопасный staging-copy и атомарная публикация; валидный начатый claim не обрывается cleanup. `GET /claims/:id` — только целевой owner, copying=202, опубликовано=200 с реальным plant_id/следующим доступным шагом.

Для Free count<3 проверяется под owner lock при создании нового экземпляра, включая claim. Retry опубликованной операции возвращает тот же экземпляр. При достижении лимита `collection_limit_reached`, данные/черновик не объявляются сохранёнными. Paid unlimited.

Истёкший draft — 410 `draft_expired`: клиент очищает незавершённый сценарий и возвращается к обычному добавлению без TTL-экрана, AI-вызова и восстановления cached result. `plant.create/source=expired_guest_draft` больше не поддерживается. Старые payload/receipt не принимаются как способ создать подтверждённый анализ из удалённого результата. Семь дней не затрагивают постоянную коллекцию.

Исходные анализ/фото/условия сохраняются при правках; новое состояние экземпляра не переписывает прежний анализ. Внутренние overrides/snapshots/revisions не обязывают продукт к номеру версии два. Комната не делает анализ stale.

## Команды и чтение

`POST /commands`: `plant.create/edit/delete`, `room.create/rename/delete`, `photo.set_main`, `care.record/undo/correct_date/postpone`, `profile.update`, `account.delete`, разрешённые schedule-команды. Точные payload существующих неизменённых команд сверяются в T155 с реализацией; нельзя ослаблять owner/provenance/idempotency ради совместимости.

- Catalogue create не требует фото/опроса/полной KB. Удаление комнаты оставляет растения без комнаты. Каждый новый экземпляр проходит collection limit; разные растения одного вида не сливаются.
- `care.record/undo/correct_date` принимают фактическую дату не из будущего; stale revision сама не отклоняет валидный факт. При paused/expired сохраняют только журнал, не создают автоматическое продолжение. `postpone` не создаёт care_entry; для неактивного расписания не обещает новый reminder.
- `plant.edit` пересматривает применимость: неподходящие будущие задачи и reminders приостановлены, ручные записи доступны. Изменение имени/комнаты/main photo само не инвалидирует контекст ухода.
- `profile.update` меняет язык, разрешённые настройки и целый час 0..23 (default 9); не меняет quota anchor или расход. Нет Free-selection/report команд.
- `GET /catalogue` и карточка вида — опубликованная проекция, поиск/пагинация/атрибуция, без полного private протокола. Конкретный существующий base catalogue RPC согласуется T149/T155.
- Owner endpoints чтения коллекции/фото/истории и `GET /plans/:plant_id/current`/история версий сохраняют доступ после expiry; чтение не возобновляет автоматический уход. При отсутствии материала возвращается явное отсутствие, а не фиктивный план.
- Создание и обновление полного плана требуют paid и применимости; payload/start/steps/completion ожидают OPEN-PLAN / T156. Старые decision_revision/treatment_start/повторы не являются утверждённым новым контрактом.

## Подписки и напоминания

`POST /billing/verify`, `/billing/restore`: operation_id и подписанная транзакция; JWS/environment/bundle/product/appAccountToken/ownership проверяются сервером. Два продукта, eligibility trial проверяется StoreKit; неизвестная eligibility не обещает trial. Verify/restore не сдвигают registration anchor и не пополняют использованное. Отдельный billing-webhook проверяет Notifications V2 и дедуплицирует notification_uuid; это не пользовательский JWT endpoint.

Прекращение подтверждённого доступа ставит паузу всего автоматического ухода/напоминаний. История/ручные факты доступны. Endpoint обычного ухода не включает free_care.select; клиент не может выбрать тройку для обхода expiry. При первом Free-уходе применяется collection cap, не slots.

Добровольное напоминание об окончании trial остаётся с проверенной датой/дедупликацией. Monthly report/notification claims не входят в API. Локальный планировщик отменяет care reminders по подтверждённому expiry и неприменимости, включая известный срок offline.

## Аналитика

`POST /funnel/events`: только enum/payload из [revision](revision-2026-11-08.md). Server purchase не принимается как клиентский факт. Owner isolation, дедупликация, отсутствие приватного содержимого, сбой не блокирует основную операцию. Нет cohort/report/attribution endpoints.

## Ошибки и удалённые маршруты

401/403 — auth/owner/entitlement; 404/410 — отсутствующий ресурс/draft; 409 — повтор ID с иным payload или живая операция; 422 — невалидные условия/дата/медиа, нет применимых фактов; 429 — quota/budget/rate limit; 502/504 — provider/timeout. `collection_limit_reached` объясняет подписку до нового сохранения. Сервер никогда не выдаёт committed без persistence.

Disambiguation/clarifications, reports, expired_guest_draft fallback, Free-selection и product-revocation API сняты. T155 проверяет отсутствие пути обхода через старые клиентские payload и документирует совместимость существующих клиентов. Внешние секреты, private Storage keys и подписанные URL не входят в общие проекции; фото выдаются через owner-checked короткие ссылки.
