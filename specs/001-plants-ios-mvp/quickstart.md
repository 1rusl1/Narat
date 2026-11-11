# Проверка простого MVP Narat

Редакция 2026-11-09. Это план проверок, не отчёт об их выполнении. [Spec](spec.md) задаёт критерии; целевые schemas/runtime ещё требуют T155/T157–T160.

## Prerequisites

1. macOS с выбранным Xcode, iOS Simulator runtime и физический iPhone с iOS 17+
   для камеры/фото/Apple Sign-In. Проверка камер — на младшем и старшем поддерживаемом устройстве.
2. Docker + Supabase CLI для локальной изолированной базы, Deno для серверных tests.
   Версии закрепить вместе с SDK lockfiles при создании scaffold.
3. Apple Developer App ID/capabilities и Google OAuth clients для приложения;
   Supabase providers и anonymous auth. Эти аккаунты здесь не создавались.
4. App Store Connect subscription group и два продукта польского магазина:
   месяц 49,99 zł без trial, год 199,99 zł с 7-дневным trial для eligible пользователей.
   Нужны eligible/ineligible Sandbox testers, Apple API credentials и root certificates.
   Квартального продукта в MVP нет. Локальная StoreKit configuration отделена от production;
   ускоренное время Sandbox фиксируется в отчёте, а не принимается за семь реальных суток.
5. Server secrets: Anthropic API key, Apple key/issuer/app identifiers, privileged
   Supabase credentials и защищённые provider revocation credentials.
   В iOS bundle допустимы URL проекта и publishable key, но не service-role/AI/Apple private keys.
6. Партии подтверждённых фактов ухода и отдельный выпуск протоколов проблем по SC-016, права доноров/credits и Golden Records EN;
   отдельная заранее размеченная eval-выборка без неразрешённых фото.

## Локальная среда после реализации scaffold

Из корня проекта, только для локальных тестовых данных:

```sh
supabase start
supabase db reset
supabase test db
supabase functions serve --env-file supabase/.env.local
```

Локальный `.env.local` создаётся при реализации и исключается из Git; значения
секретов не выводятся в отчёты. Нельзя подменять локальный fixture production key.
Database tests должны включать RLS и транзакционные команды ухода.

Отдельный терминал:

```sh
deno check --config supabase/functions/deno.json supabase/functions/plants-api/index.ts
deno test --allow-env --allow-net=127.0.0.1,localhost supabase/functions/
```

Обычные tests используют fixtures и локальные сервисы, не платного провайдера.
Совместимость Apple SignedDataVerifier проверяется дополнительно в точном Edge Runtime:
валидная и неверная цепочки, OCSP/network, JWS application identifiers и App Store API auth.
Успешная сборка TypeScript без этих проверок не закрывает G02.

## Сборка и UI tests после создания проекта

Сначала определить доступную destination:

```sh
xcodebuild -project ios/Plants.xcodeproj -scheme Plants -showdestinations
```

Задать `PLANTS_SIMULATOR_UDID` действительным ID из вывода, затем проверить английский интерфейс для польского региона. После среза T170 UI-тесты должны запускаться без выбора языка; прежняя двуязычная матрица не является условием выпуска.

```sh
xcodebuild -project ios/Plants.xcodeproj -scheme Plants -destination "platform=iOS Simulator,id=${PLANTS_SIMULATOR_UDID}" -testLanguage en -testRegion PL test
```

Схема Plants должна содержать unit/UI test targets и локальную StoreKit configuration
для тестового режима. Учебные покупки/fixture entitlements не дают production доступ.
Native Apple/Google sign-in и съёмка фото дополнительно проверяются на реальном устройстве.


## Сквозная приёмка

Первый живой прогон и его отличие от полной приёмки — в [критическом пути](critical-path.md).

Каждый маршрут MVP на английском: версии, набор/источник данных, реальные команды/шаги, PASS/FAIL/не проверено. Fixtures, Simulator и live явно разделены.

| ID | Маршрут | Что проверить |
| --- | --- | --- |
| V01 | Фото → результат | Главное «Проверить растение», недостающие базовые условия, один реальный анализ с видом/проблемой/healthy/unknown, действие/основание до входа. |
| V02 | Повторная диагностика | Новое фото того же растения, текущие условия и фактический журнал, без вопросов/AI-сравнения. |
| V03 | Ограничение/ошибка | Непригодное фото/invalid ID/отказ провайдера, ввод сохранён, нет выдуманного лечения, нет post-analysis опроса. |
| V04 | Starter/месяцы | Два starter, Free=3/paid=100 от регистрации, первый/короткий месяц, без reset при purchase/trial/restore/expiry. |
| V05 | Квоты/конкурентность | Реальные одновременные запросы на последний остаток, reserve/success/failure/replay, нет двойного расхода. |
| V06 | Каталог → коллекция | Без фото/опроса/полной KB, плоская коллекция, save/read/restart/retry; Free cap/paid unlimited и одновременное добавление. |
| V07 | Guest → аккаунт | Claim до семи дней и cleanup race; после срока нет TTL-экрана/fallback/скрытого AI. Фото/владельцы/расход сохранены. |
| V08 | Подписка | Два продукта, фактические цена/даты/eligibility, pending/cancel/restore, ownership, возврат к запросу. Нет продажи отсутствующего материала. |
| V09 | Expiry | Все автоматические care reminders/tasks остановлены; чтение/ручной журнал/undo/correct_date доступны, не снимают паузу. |
| V10 | Правка/актуальность | История/исходный анализ не меняются, неподходящее будущее paused; явное обновление только из пригодных данных, без AI. |
| V11 | Уход → журнал | Включение не выполнение; record/undo/backdate/offline/restart/lost response, одна запись и допустимая следующая проверка с коротким основанием. |
| V12 | Care/trial reminders | Местный час/DST/стабильные IDs, перенос/отмена/logout/known expiry offline; trial opt-in по verified дате без server claim. |
| V13 | Приватность/удаление | API/Storage/local A-B isolation, profile/plant/account deletion, отказ в разрешении не блокирует независимое. |
| V14 | База | Ручные проверенные карточки, частичное покрытие, права/применимость/EN/версия, atomic publish/rollback; без полного профиля и минимального охвата. |
| V15 | Безопасность рекомендаций | Unknown safety не безопасно, вещество только при данных/условиях, сложное неподдерживаемое лечение не упрощено опасно; нет товаров/таймеров. |
| V16 | События | Enum/privacy/event_id dedup, server purchase/restore, потеря client event не блокирует продукт; отдельного durable analytics outbox нет. |
| V17 | Фото/карточка | Camera/gallery/контрольное фото и просмотр прежних, ownership/сохранность; без export/main-picker/специального сравнения. |
| V18 | Upgrade | Совместимые machine schemas/API/DTO, clean+forward upgrade, старые фото/комнаты/результаты/расход сохранены, снятые команды не оживают. |
| V19 | Простые проверки | Применимое действие сейчас/условие/срок, обычный repeat по правилу и один контроль первой помощи. Undo снимает незавершённый контроль; нет стадий/выздоровления/слепого продления. |

## Ранние проверки и публичный выпуск

Сначала небольшой заранее выбранный набор случаев и качественные UX-прогоны на английском. Публикуются ограничения, исправляются блокирующие ошибки. Универсальные квоты 200 случаев и 20 участников на язык сняты.

Для публичного выпуска T118 **до eval** задаёт покрытие, размер/стратификацию и достаточность независимой reference-выборки. Цели SC-003/004 (85% вид, 80% причина, 90% пригодные действия/неопределённость) сохраняются; малая выборка не служит доказательством качества всего покрытия. Опасные рекомендации исправлены и повторно проверены. SC-002 измеряется на описанных условиях сети/фото.

T098/T099 не закрываются build/fixtures. Нужны реальные auth/camera/Storage/AI/StoreKit и пользовательские маршруты. Сложные лечебные цепочки, комнаты и AI-динамика — не release gates; принятый простой формат проверяется V11/V19. ASO должен описывать только доступные функции, архивные макеты не доказательство реализации.
