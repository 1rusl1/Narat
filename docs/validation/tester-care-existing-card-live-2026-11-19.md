# Живая проверка полива существующей карточки — 19 ноября 2026

Статус: **setup выполнен, UI-прогон ещё не запускался**.

Обычный HTTP-вход выделенного постоянного Free-владельца, затем
`POST /commands plant.create` с одним замороженным operation ID создали
одну Monstera deliciosa. До setup коллекция была пустой; после — одна
карточка, entitlement=null и ноль care_entries. Создание выполнено вне
приложения, поэтому локальной create-confirmation новой карточки нет.

Условия setup: medium/manual/confirmed, watering unknown, drainage yes,
plastic pot — как в существующем опубликованном staging care-контексте.
Новые рекомендации, Auth Admin, SQL-изменения, AI и покупки не использованы.
Тестовая карточка оставлена для следующего прогона; повторную не создавать.

Отдельное живое readback рекомендации: available, check_soil, опубликованный
интервал проверки 7 дней и источник; next_check/routine_check отсутствуют
до факта ухода и включения/явного обновления. Это не готовая задача.

Детерминированный harness: `/private/tmp/narat-tester-care-live.py`.
`python3 -m py_compile` — PASS; реальный режим `prepare` — PASS.
Operation/receipt/UUID сохранены в локальном файле режима 0600:
`/private/tmp/narat-tester-care-live-evidence-20261119/fixture.json`.
Пароля и токенов в этом файле нет; доступ хранится отдельно вне Git.

После приёмки UI-пакета: собрать подписанный ordinary EN Release с чистого
accepted SHA, проверить отсутствие DEBUG fixtures, установить в выделенный
Simulator и выполнить collection → existing card → Record watering →
канонический журнал → enable/refresh текущего ухода → следующая дата →
cold reopen → correct date/пересчёт → cold reopen → undo →
cold reopen. HTTP-readback должен подтвердить один исходный факт, тот же
operation/entry ID, исправленную дату и voided после отмены. App запускать
без тестовых аргументов. До согласованного освобождения Simulator/Xcode
оркестратором режимы `build/run` не выполняются.

Это подготовка живой приёмки конкретного нового пути. B01–B11, физический
iPhone, настоящий offline/reconnect, Today и доставка care notifications
этим setup не приняты.
