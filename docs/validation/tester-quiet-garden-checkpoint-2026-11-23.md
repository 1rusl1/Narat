# Narat0.1.0(4): пакет готов для технической приёмки

Код `f1abe59c9bc3bf2329b51f73330aa86738ff7f06` сохранён и отправлен в origin. Полное committed iOS-дерево `bcee2aea03537bce09138d5bcaf095b273c8a787` равно принятому a131e57. Сборки выполнены из чистого detached checkout; три пользовательских PBX/xcstrings сохранены в Root и не включены.

Локальный пакет: [инструкция](../../build/technical-checkpoint-0.1.0-4/README.md), [Simulator ZIP](../../build/technical-checkpoint-0.1.0-4/Narat-0.1.0-4-Simulator.zip), [manifest](../../build/technical-checkpoint-0.1.0-4/manifest.json). Это Git-ignored артефакты, в origin находятся исходники/отчёты.

| Артефакт | Реальная проверка | Ограничения |
|---|---|---|
| Ordinary Simulator Release0.1.0(4) | buildPASS; подпись хоста original+retained+packagecopy; App/dSYM UUID; mainSHA внутри ZIP; arm64+x86_64 | iOS17+; собрана SDK26.5, запуск проверен iPhone17Pro/iOS26.5 |
| Ordinary Personal0.1.0(4) | buildPASS; подпись original+retained+packagecopy; App/dSYM UUID; разрешённый профиль/устройство; backend/publickey | профиль до24.11.2026 19:19:31МСК; AppleSignIn отключён; install/UI/delivery этой версии не проводились |
| Обычный запуск Release | Установка только на выделенный Simulator, новый PID/installedbinaryhash; после начального восстановления Root фактически просмотрел главную без fixturecontrols/error/clipping | Только Home; без входа/полива/AI/новой живой сквозной приёмки |
| UI gallery |44sha-matchedENPL/lightdarkPNG, RootactualVIEW44 и независимыйLight22 | Тестовые данные/representative; не все состояния25семейств/VoiceOver/клавиатура/узкий/физический экран |

Обе сборки — обычные, без Plants.debug.dylib;19DEBUG implementation-sentinel отсутствуют. Ожидаемый backend и публичный клиентский ключ проверены, приватные конфигурации/пароли/пользовательские базы не копировались. Старый checkpoint3 сохранён. Временные derived удалены только внутри новых собственных build-output после сохранения app/dSYM; старый кэш не удалялся.

[Снимок обычной главной](../../build/technical-checkpoint-0.1.0-4/ordinary-release-home.png) и[область проверки](../../build/technical-checkpoint-0.1.0-4/ordinary-release-home-proof.json). Первый кадр показывал нормальное начальное SDK-восстановление; после дополнительного ожидания главная отобразилась без loading. Это не переименовано в новую live/notification приёмку.

Исходный технический этап: [14проверок/Review/QA/44снимка](tester-quiet-garden-technical-2026-11-23.md). ПолныйQG7/TodayXXXL/VO/keyboard/narrow/physical/external/fullMVP и T075/T077/T080/T098 остаются открыты. Покупки/расширение рекомендаций отложены.

Следующий шаг — техническая приёмка по[маршруту тестировщика](../tester-handoff.md) на обычном Simulator-пакете. Физическая/внешняя матрица и новый живой цикл принимаются отдельно. [Машинные доказательства/SHA/UUID](tester-quiet-garden-checkpoint-2026-11-23.json).
