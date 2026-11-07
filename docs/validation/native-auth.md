# Native auth — T041

Дата: 2026-11-02. Клиентский сервис AuthenticationServices / GoogleSignIn → Supabase Auth.

## Реализовано

- `NativeAuthService`: подготовка переноса → native provider → обмен ID token → permanent session.
- Обязательный `prepareForSessionChange` вызывается до открытия провайдера. Вызывающий ClaimFlowModel должен сохранить GuestDraftCache и получить/сохранить claim proof. Ошибка подготовки не меняет сессию.
- Отмена, ошибка провайдера или сети не удаляют GuestDraftCache/AddFlowState, не запускают повторный анализ, не выполняют guest sign-out. Успех входа также не очищает черновик: это разрешено только после подтверждённого сохранения растения.
- Параллельный повторный вход блокируется; ошибки представлены стабильными кодами без вывода токенов/личных данных.
- Apple: криптографический nonce, SHA-256 для native request, исходный nonce для Supabase; ограничение presentation context активным окном. Отмена task закрывает Apple authorization controller.
- Google: ID/access tokens; проверка client ID и зарегистрированной callback URL scheme; обработчик `.onOpenURL` в приложении.
- Capability Sign in with Apple, public xcconfig с необязательным локальным override, Info.plist для публичных параметров и Google URL scheme.
- Apple authorization code возвращается вызывающему коду для будущего серверного обмена credential для revoke. Серверный обмен/удаление аккаунта относятся к дальнейшим задачам; код не сохраняется в UserDefaults или дневнике.

## Конфигурация перед живым входом

Создать `ios/Configuration/Auth.local.xcconfig` (исключён из Git). Только публичные клиентские параметры:

```xcconfig
// $() сохраняет второй slash: // без этого трактуется xcconfig как комментарий.
NARAT_SUPABASE_URL = https:/$()/PROJECT.supabase.co
NARAT_SUPABASE_PUBLISHABLE_KEY = PUBLIC_PUBLISHABLE_OR_ANON_KEY
GOOGLE_IOS_CLIENT_ID = IOS_CLIENT_ID.apps.googleusercontent.com
GOOGLE_SERVER_CLIENT_ID = WEB_CLIENT_ID.apps.googleusercontent.com
GOOGLE_REVERSED_CLIENT_ID = com.googleusercontent.apps.IOS_CLIENT_ID
```

В Supabase включить Apple/Google и разрешённые client IDs. Для Apple зарегистрировать bundle ID `app.narat.plants` с Sign in with Apple и настроить signing team/provisioning. Серверные Apple secrets и Supabase service_role/secret key в приложение не попадают.

Клиент Supabase создаётся один раз и совместно используется auth/prepare/commit/session refresh. `NativeAuthConfiguration` проверяет параметры; `makeService(client:)` создаёт адаптеры поверх этого общего клиента. Отсутствующий конфиг выдаёт `configurationMissing`, без фиктивного успешного входа.

## Граница готовности

T041 реализует сервис. Экран входа и его вызов из сохранения подключаются вместе с T046/T047, когда будет готова подготовка/публикация claim. Сейчас приложение по-прежнему показывает демонстрационный анализ US1; живое получение/сохранение результата ещё не подключено. Подключать native sign-in с пустым preparation callback в сценарии гостевого сохранения запрещено.

Сценарии тестов: checkpoint до провайдера, отмена и сохранность кеша после повторного открытия store, ошибка checkpoint, Apple nonce/code, Google token exchange, ошибка сети/повтор, отклонение неверного provider/nonce, блокировка конкурентного входа, отмена task, публичная конфигурация и случайность nonce. Используются тестовые провайдер/обмен без реальных OAuth-аккаунтов.

Результат: `xcodebuild test` на iPhone 17 Pro / iOS 26.3 — **TEST SUCCEEDED**, 2026-11-02. Прошли 16 XCTest unit-тестов (включая 10 NativeAuthTests), 3 Swift Testing и 2 UI-теста: всего 21, без ошибок.

Команда:

```sh
xcodebuild -project ios/Plants.xcodeproj -scheme Plants -destination 'platform=iOS Simulator,id=32009F39-32EF-426B-A91E-31B368D6C27E' -derivedDataPath /tmp/PlantsDerivedData -disableAutomaticPackageResolution -parallel-testing-enabled NO test
```

Лог итогового запуска: `/tmp/narat-auth-final-tests.log`; xcresult: `/tmp/PlantsDerivedData/Logs/Test/Test-Plants-2026.11.02_11-47-25-+0300.xcresult`. Первый запуск без явной версии iOS не стартовал из-за системного сбоя test runner (`Mach -308`); это не ошибка тестовых утверждений. Повтор на конкретном iOS 26.3 прошёл.

Реальный Apple/Google OAuth и вход на физическом устройстве этим тестом не подтверждаются.

## Первичные источники

- [Supabase Swift: signInWithIdToken](https://supabase.com/docs/reference/swift/auth-signinwithidtoken)
- [Google Sign-In iOS](https://developers.google.com/identity/sign-in/ios/sign-in)
- [Google: ID token для backend](https://developers.google.com/identity/sign-in/ios/backend-auth)
- [Apple: отмена authorization controller](https://developer.apple.com/documentation/authenticationservices/asauthorizationcontroller/cancel())

Контракты сверены также с локальными исходниками закреплённых Supabase Swift 2.55.6 и GoogleSignIn 8.0.0.
