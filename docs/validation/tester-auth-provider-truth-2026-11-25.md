# AUTH-A2 — частичная приёмка, 25 ноября 2026

**PASS в узком объёме:** доступность провайдеров, восстановимые ошибки конфигурации/показа, сообщения EN/PL и корректная проверка Google callback в переданном Bundle. Изменены `CatalogueSaveView.swift`, `GuestCatalogueView.swift`, `NativeAuthConfiguration.swift`, `CatalogueConnectionTests.swift`. Защиты SDK/owner/epoch/checkpoint/outbox сохранены. Default Apple-only Harness прежний; только Google success-case получает валидную тестовую конфигурацию.

Реально выполнено: diff PASS0.038с; 149automation PASS46.710с; Release PASS172.930с; iOS/build/welcome/units PASS195.427с. Swift511/511, failed0/skipped0: прежние508 и3 новых регрессии с реальными SDK/HTTP-fixture/SQLite. Независимые highReview89.080с/highQA108.098с — PASS, findings0. Проверки не перезапускались для приёмки.

Run `nov25-auth-provider-truth-A2-01`, source FP `6e10b698f834d73ba0cec425e4f90bb28aa435d3cbf7128afeba5ae2bc101102`. Итог engine WAITING/publish-disabled, inflightnil/failures[]; controller1 ожидаем из-за отключённой публикации, wrapper0. Это не productFAIL. Точные source SHA/пути raw/check/answer сохранены в соседнем JSON; patch SHA `abca2beb8e034adf1eec36ff005402eb7b414842ce25758c79262a00417b018c`.

Предыдущие попытки сохранены без переписывания: broad Developer timeout900.017с/source0/checks0; A1 transportPASS53.233с/semanticBLOCKED/source0/checks0 из-за Apple-only fixture и старой Google-success итерации. A2 исправляет именно конфигурацию этой fixture, сохраняя исходные success assertions/HTTP counts.

**Не проверено:** rendered native auth, email LOGIN continuation, настоящий Google/Apple OAuth, живой перенос гостевого фото, физический iPhone. Полные задачи входа/T046 не закрываются. В AUTH-B уточнить copy: первый вход создаёт аккаунт; после успешного входа сохранение выбранного растения продолжается автоматически. Отдельного Confirm нет. Исходная конфигурация Google в frozen lane не обновлялась; новая настройка Root пока не является положительным live-тестом.

Следующий шаг: Root интегрирует4 проверенных файла; после принятой Nav+A базы — AUTH-B с существующим email LOGIN, точным checkpoint и rendered cases. C1/C2 пока только private read-only proposal. Правило бюджета Nov25 заменило прежние резерв30/noreset: доступны текущий остаток и максимум один официальный сброс при необходимости; фактически сбросов0. Секреты, конфигурации и сборочные артефакты не включены.
