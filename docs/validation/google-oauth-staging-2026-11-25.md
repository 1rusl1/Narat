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

## История первого probe5: найден nonce blocker

Владелец завершил вход в Google. Root на ordinary5 реально увидел возврат с ошибкой Sign-in failed и сохранёнными видом/именем. Auth-журнал staging подтвердил400 на id_token exchange из-за отсутствующего переданного nonce при nonce в Google-токене. SDK8 не имеет public custom-nonce API. [Факты](tester-google-native-preauth-2026-11-25.json). Проверка nonce на сервере остаётся включённой; начат изолированный SDK10.1 secure fix. Это текущий Simulator probe, причина поведения старой физической сборки отдельно не доказана.

## Живой маршрут после secure fix

На ordinary auth probe6 из `0c9b530` реальный Google-вход и автоматическое сохранение прошли. My plants до и после холодного запуска показал одну и ту же карточку; она открылась с прежним именем и видом. [Подробный результат и ограничения](tester-google-catalogue-live-2026-11-25.md). Проверка nonce остаётся включённой. Это результат каталога на Simulator; фото/physical/Apple отдельно.

## Открыто и следующий шаг

Итоговая сборка со всеми исправлениями ещё не готова. Внутренний probe6 прошёл auth/signature/dSYM/DEBUG-exclusion проверки, но строгий embedded name guard FAIL: Plants вместо Narat. Metadata имени исправляется отдельно, без ослабления проверки финального пакета.

Отдельная учётка [подготовлена и проверена через Auth/API](tester-separate-account-2026-11-25.md); ordinary UI этой учётки ещё не проверен. Physical iPhone не проверялся; прежняя Personal-подпись истекла 24 ноября. Далее — оставшиеся каталожные/result исправления, photo live path и итоговый новый артефакт.

Сбросов лимита использовано: **0**.
