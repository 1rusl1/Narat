# Живая проверка полива существующей карточки — 19 ноября 2026

Статус: **PASS конкретного живого прогона UI-кандидата; весь этап ухода открыт**.

Ordinary EN Release собран из frozen candidate
`2fbf99de163a546f51654511e230cf5a3664fb1e`, подпись и отсутствие DEBUG fixtures
проверены. Установленный executable совпал по SHA-256 с собранным. Это не
принятие полной девятки UI-фикстур: два новых offline/rejection сценария ещё
исправляются отдельным оркестратором; старые семь прошли. Контент/Today/
notifications этим прогоном не расширялись.

## Реально пройдено на живом staging

- Existing Free card из HTTP setup → Record watering → обязательное
  подтверждение в обычном UI → ровно один канонический факт.
- Enable/refresh базового ухода → дата 2026-11-26, основание и источник.
- Cold launch → та же запись/карточка и дата.
- Correct date на 2026-11-18 → та же entry/operation identity, следующая
  проверка 2026-11-25; cold launch сохранил изменение.
- Undo → тот же факт voided, next_check/routine_check=null; cold launch
  сохранил историю отмены. Второго факта не создано.

[Санитизированный отчёт и хеши кадров](tester-care-existing-card-live-2026-11-19.json).
Root визуально просмотрел next-check и cold-undone PNG. Установка сначала
превысила 70s timeout и закончилась позднее; первый UI-agent старт вывел Home,
а runner не дождался confirmation. Эти неуспехи сохранены отдельно; после
исправления только временного runner успешный лог —
`/private/tmp/narat-tester-care-live-evidence-20261119/ordinary-care-ui-retry-ae02f33d.log`.
Product candidate между попытками не менялся. Это не настоящий offline-тест.

Signed app сохранён в
`/private/tmp/narat-tester-care-live-evidence-20261119/signed-release-2fbf99de163a/Plants.app`.
Перед удалением только своего воспроизводимого DerivedData (1.1GiB) архив
сверен по SHA-256 и `codesign --verify --deep --strict`; исходники, кадры,
build logs, shared caches и тестовый Simulator сохранены.

## Подготовка и воспроизведение

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

Для повторной проверки после изменения product sources: собрать подписанный ordinary EN Release с чистого
accepted SHA, проверить отсутствие DEBUG fixtures, установить в выделенный
Simulator и выполнить collection → existing card → Record watering →
канонический журнал → enable/refresh текущего ухода → следующая дата →
cold reopen → correct date/пересчёт → cold reopen → undo →
cold reopen. HTTP-readback должен подтвердить один исходный факт, тот же
operation/entry ID, исправленную дату и voided после отмены. App запускать
без тестовых аргументов. До согласованного освобождения Simulator/Xcode
оркестратором режимы `build/run` не выполняются.

Это приёмка только указанного нового пути в candidate. B01–B11 целиком, физический
iPhone, настоящий offline/reconnect, Today и доставка care notifications
этим setup не приняты.
