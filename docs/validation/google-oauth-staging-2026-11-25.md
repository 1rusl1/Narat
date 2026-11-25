# Google OAuth: staging, 25 ноября 2026

## Выполнено через Chrome

Владелец вошёл самостоятельно. Проверен существующий Supabase-проект `narat-staging` (`ijwnyjdomwvnzmmcurkt`), совпадающий с backend выданной сборки. В начале Google и Apple были отключены. Другой проект организации не изменялся.

Создан отдельный Google Cloud-проект `narat-staging-20261125` / Narat Staging: существующие проекты относились к другим приложениям. Billing, пробный платный тариф, дополнительные Google API и Firebase App Check не подключались.

После отдельных подтверждений владельца:

- Согласованный email текущего Google-аккаунта выбран для поддержки и уведомлений; адрес в Git не записан.
- Принята Google API Services User Data Policy. Создан экран согласия External / **Testing**; приложение не опубликовано.
- Созданы Web-клиент Narat Staging Supabase и два iOS-клиента для `app.narat.plants` / `app.narat.plants.personal`.
- Web callback: `https://ijwnyjdomwvnzmmcurkt.supabase.co/auth/v1/callback`.
- Google включён только в указанном Supabase staging. Сохранены три client ID, Web первым, и Web client secret. Повторное открытие формы подтвердило значения и включённый провайдер; dashboard показал Successfully updated settings.
- **Skip nonce checks выключен**, Allow users without an email выключен. Apple и остальные настройки входа не менялись.
- Аккаунт владельца добавлен в тестовый список Google; строка сохранена и проверена после закрытия формы. Отдельный аккаунт тестировщика ещё не добавлен.

Проверка — реальные страницы Google/Supabase, AX и визуальный просмотр; это не fixture. Создание клиентов и сохранение настроек не доказывают успешный нативный вход.

## Локальная конфигурация

В Root подготовлены Git-ignored `ios/Configuration/Auth.local.xcconfig` и `Personal.local.xcconfig`: публичные iOS/server client ID и соответствующая reversed callback scheme. Предыдущие локальные настройки сохранены в `build/private`; прочие строки сохранены. Public-only manifest: `build/private/narat-google-oauth-20261125.json` (0600). Web secret передан только в staging Supabase, в файлы/коммиты/чат не выводился; переменная с секретом в браузерной сессии очищена.

Для staging в ignored Auth.local также задан `NARAT_APPLE_SIGN_IN_ENABLED = NO`, поскольку удалённый Apple-провайдер выключен. Окончательный embedded Info.plist и приоритет настройки над project build settings ещё нужно проверить при сборке; при необходимости задать тот же build flag явно. Настройки активных изолированных оркестраторов не менялись: их уже запущенные fixture/build проверки не проверяют новую OAuth-конфигурацию. Три исходных пользовательских PBX/xcstrings побайтно совпали с baseline.

## Реальный первый вход: найден дополнительный blocker

Владелец завершил вход в Google. Root на ordinary5 реально увидел возврат с ошибкой Sign-in failed и сохранёнными видом/именем. Auth-журнал staging подтвердил400 на id_token exchange из-за отсутствующего переданного nonce при nonce в Google-токене. SDK8 не имеет public custom-nonce API. [Факты](tester-google-native-preauth-2026-11-25.json). Проверка nonce на сервере остаётся включённой; начат изолированный SDK10.1 secure fix. Это текущий Simulator probe, причина поведения старой физической сборки отдельно не доказана.

## Открыто и следующий шаг

Обычный подписанный Simulator Release **0.1.0(5)** собран из чистого принятого `9b9eeebb`: встроенные Google iOS/server client ID и callback, Apple NO, отсутствие 19 DEBUG-сентинелов, backend/public key, подпись и App/dSYM UUID проверены. [Build metadata](tester-auth-ordinary-probe-2026-11-25.json). Это внутренний auth probe, не итоговый артефакт со всеми исправлениями.

Probe установлен в отдельный Simulator `59EDB547-D026-43D1-801B-AA6D644765C7`. Живой каталог → имя → Save открыл Google; владелец завершил вход. Возврат в Narat и сохранность имени/вида наблюдались, но серверный обмен отклонён с описанной выше nonce-ошибкой. Постоянная сессия, сохранение одной карточки и холодный запуск **пока не подтверждены**. Последний native lease освобождён. Старые Simulator не изменялись.

Отдельная учётка тестировщика ещё не подготовлена. Physical iPhone не проверялся; прежняя Personal-подпись истекла 24 ноября. Первичная ошибка helper до Xcode из-за неверного ожидания env-переменной lease исправлена и проверена двумя no-native cases; общий wrapper не менялся. Реальная Xcode-сборка probe5 одна и прошла PASS.

Далее: принять secure nonce/SDK пакет, собрать обычный probe6 и повторить Google → точное сохранение → холодный запуск. Пользовательский PBX diff будет сохранён отдельно от staging SDK-изменения; исходные xcstrings не меняются. Остальные исправления продолжаются независимо. Пароли/коды Google вводит владелец самостоятельно. При фактической ошибке nonce сначала установить причину; ослабление проверки не входит в выполненный объём.

Сбросов лимита использовано: **0**.
