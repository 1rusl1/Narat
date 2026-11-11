# Client API — целевой MVP

> Актуальная серверная граница Free-коллекции и retirement slots: [collection-cap.md](collection-cap.md), 2026-11-09. Исторические slot/selection поля ниже не входят в новые проекции; клиентская T162 и живой API ещё не приняты.
Редакция 2026-11-09; base `/functions/v1/plants-api/v1`. [Переход](revision-2026-11-09.md), [статус схем](README.md). Наличие endpoint в документе не доказывает реализацию.

## Общие границы

Verified Supabase JWT (guest/permanent), active owner из JWT; RLS/private Storage. Mutations используют operation_id и canonical payload hash: lookup receipt до побочных эффектов/проверки нового расхода, mismatch — 409. Replay не даёт нового права доступа. Ошибка содержит локализуемый code/retryable; pending не считается committed. `X-Client-Locale` принимает pl/en для совместимости; клиент MVP отправляет en; installation credential — Keychain/серверный hash, не логировать.

## Анализ и сохранение

| Маршрут | Цель |
| --- | --- |
| POST /installations/issue, /installations/bind | Существующая безопасная выдача/bind starter-доступа, без переноса чужих данных или повторных попыток. |
| GET /analysis-access?mode=identification\|diagnosis | Starter/месячная квота, остаток/период/причина отказа; GET не резервирует. Повторная диагностика использует diagnosis. |
| POST /media/upload-ticket, /media/complete | Приватная загрузка, owner/MIME/size/hash; signed URL 60 секунд. Клиент сжимает до <=10 МБ, AI JPEG 1568px до отдельного eval, EXIF удаляется. |
| POST /analysis/jobs; GET /analysis/jobs/:id | Idempotent job с фото/контекстом/locale и версией каталога/KB; reserve/lease и атомарный success+расход. Результат — классификация/ограничение и snapshot применимых действий, без вопросов или AI-советов. |
| POST /claims/prepare, /claims/commit; GET /claims/:id | Перенос действительного семидневного draft после входа, proof 15 минут с возможностью обновления пока draft действителен. Staging-copy/атомарная публикация, защита cleanup, owner и count<3 Free. |
| GET /catalogue, /catalogue/:id | Опубликованные виды, поиск EN/Latin/синонимы (существующие PL данные совместимы), атрибуция; без обязательной KB. |
| GET /me | Профиль, registered_at, entitlement, квота/collection count и automatic-care state; без внутренних секретов. |

Quota anchor — регистрация постоянного аккаунта. Free=3/paid=100 за общий период, starter раздельны; правила короткого месяца/переноса расхода из [редакции 8 ноября](revision-2026-11-08.md) сохраняются. Unknown не освобождает успешный анализ от расхода. Ошибка освобождает reserve ровно раз. Worker фиксирует исходный ledger, проверяет lease/owner/access; expiry не переводит запрос автоматически на Free.

Удалённый draft даёт внутренний 410 draft_expired; клиент возвращается к обычному добавлению без TTL-экрана/восстановления из кеша/скрытого анализа. Replay действительного успешного claim не создаёт растение заново. Постоянные медиа не очищаются по guest TTL.

## Команды и рекомендации

`POST /commands`: plant.create/edit/delete, care.record/undo/correct_date/postpone, profile.update, account.delete и необходимые schedule-команды. Catalogue create не требует фото/опроса, атомарно проверяет лимит. Новый контракт не принимает room CRUD/photo.set_main/free_care.select/report/diagnostic answers/local fallback.

Существующий owner endpoint чтения рекомендаций/истории сохраняется. Создание/явное обновление расширенных рекомендаций требует verified paid и применимых данных, не AI/фотоквоту. Тело — действия сейчас, условия/основание и следующая проверка, без treatment timeline. Включение ухода создаёт только применимые checks, не care факт. Record/undo/correct_date согласуют будущее атомарно; неприменимость/expiry оставляют только ручной журнал. UI не нуждается в отдельном lifecycle API для лечебных стадий.

`GET /sync` — существующий owner delta с устойчивой пагинацией, права/automatic care даже при пустом delta; подробности в sync.md. Коллекция, фото и прежние рекомендации читаются владельцем после expiry.

## Оплата, события, напоминания

Billing endpoints/server notifications проверяют signed store data, ownership, dedup и entitlement; restore не покупка. Аналитический endpoint принимает только enum/минимальный payload с event_id; client best-effort без durable outbox, server purchase выводится из billing. Сохранение квоты и покупки не зависят от analytics доставки.

Care/trial reminders планируются локально. Отдельный `/notifications/claim` в целевом MVP не нужен; trial дата подтверждена сервером, opt-in локален. Повтор по одному локальному ID не создаёт дубликат. Старые клиенты/маршруты отключаются по T159, не через немедленное удаление исторических данных.
