# Существующая SDK-сессия: read-only проверка PASS

22 ноября 2026. Обычный подписанный Simulator Release из принятого source `1371ae0`. Парольный файл не использовался; внешний API-клиент не создавался, auth storage/Keychain/токены не читались. Код приложения не менялся.

## Что выполнено

До установки и запуска сделан согласованный SQLite backup с WAL через mode=ro: очередь **всех владельцев пуста**, известная Monstera и её владелец определены однозначно. Проверены accepted proof, подпись и SHA архива, исключение 14 DEBUG-маркеров. Установлен этот же ordinary Release, штатный запуск — только English, без fixture/legacy-флагов.

Существующая постоянная SDK-сессия восстановилась без формы входа. Через My plants открыты точная известная карточка и Account settings. Новый sealed snapshot подтвердил того же владельца, новую canonical checkpoint publication и новую согласованную EN overview generation. UI показывает «Reminders are off for this account.». Скрипт завершился с кодом 0 и освободил ресурс.

Отдельный read-only проход Settings → Collection Close → Today → Settings также завершился с кодом 0. Визуально проверен Today: свежий Last checked, No scheduled checks, известная карточка и Refresh care читаемы. **Все 22 canonical rows сохранены без изменений**, включая прежние записи и tombstone; decoded profile и час не изменились, outbox 0 → 0. Строки JSON профиля отличались порядком ключей, decoded значения равны. Снимки получены из sealed SQLite; raw helper не заменяет Swift DTO/Planner validation или SDK authority.

Счётчики: password login, внешний API-клиент, чтение auth storage, создание аккаунта, изменения данных ухода, consent, permission и arm intents — **0**. Приложение могло штатно обновить собственную SDK-сессию и выполнить sync; число его сетевых запросов не измерялось. Прежний preflight STOP до Auth сохранён как отдельная попытка, его результаты не переписаны.

## Фактическая структура UI и ограничения

Снимок Today — 1206×2622 px. `today.root` экспортируется как ScrollView с рамкой `{x:0,y:0,width:402,height:874}`. Mobile dump содержит только `data.elements`; строк Application/Window нет. Compact Care reminders сейчас отсутствует: NoSchedule и выключенная preference не дают eligible consent offer. Это согласуется с исходниками; фактическая строка footer/hit point ещё не наблюдалась. Прежний helper, требующий Application/Window, нельзя считать проверенным на этой структуре.

Приватные PNG/AX/SQLite находятся в отдельном OUT `/private/tmp/narat-care-existing-sdk-probe-evidence-20261122`; хеши PNG/AX и итогов сохранены в соседнем JSON. В репозиторий не включены сырые владельцы, содержимое Store, PII, настройки или секреты.

Следующий шаг: отдельно подготовить и проверить Store-based live operator поверх восстановленной SDK-сессии. До полива — actual native Notification Center PNG/AX и визуальный аудит, review корректной рамки Today/footer. Затем согласованный цикл с одной известной записью, временным часом, G1/G2, реальной доставкой и точным восстановлением. System delivery/tap, physical и внешняя передача остаются открытыми. Парольный файл для этого SDK-пути не требуется; новые аккаунты и извлечение токенов не разрешались.
