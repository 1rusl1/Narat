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

## Открыто и следующий шаг

Обычная подписанная сборка с новыми параметрами ещё не создана. Реальные Google consent → callback → Supabase token exchange → сохранение одной карточки → холодный запуск **не проверены**. Отдельная тестовая учётка/живой email login ещё не подготовлены. Physical iPhone не проверялся; прежняя Personal-подпись истекла 24 ноября.

Далее: принять узкие AUTH/navigation изменения и объединить их, затем под общим native lease собрать обычный Simulator-артефакт с этой локальной конфигурацией, проверить встроенные IDs/scheme и выполнить живой первый вход. Пароли/коды Google вводит владелец самостоятельно. При фактической ошибке nonce сначала установить причину; ослабление проверки не входит в выполненный объём.

Сбросов лимита использовано: **0**.
