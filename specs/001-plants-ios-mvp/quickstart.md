# Quickstart & Validation: Narat iOS MVP

**Пересмотр 2026-11-08.** Это план проверок, не отчёт о выполнении. Старые V/NR/KB списки заменены текущей матрицей ниже; они не являются release gates снятых функций. Spec/plan/tasks описывают целевое поведение; код и schemas проходят T155, модель планов ждёт T156. Исторические результаты — docs/handoff_status.md и отчёты validation.

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
6. Партии подтверждённых фактов ухода и отдельный выпуск протоколов проблем по SC-016, права доноров/credits и Golden Records PL/EN;
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

Задать `PLANTS_SIMULATOR_UDID` действительным ID из вывода, затем выполнить оба языка:

```sh
xcodebuild -project ios/Plants.xcodeproj -scheme Plants -destination "platform=iOS Simulator,id=${PLANTS_SIMULATOR_UDID}" -testLanguage pl -testRegion PL test
xcodebuild -project ios/Plants.xcodeproj -scheme Plants -destination "platform=iOS Simulator,id=${PLANTS_SIMULATOR_UDID}" -testLanguage en -testRegion PL test
```

Схема Plants должна содержать unit/UI test targets и локальную StoreKit configuration
для тестового режима. Учебные покупки/fixture entitlements не дают production доступ.
Native Apple/Google sign-in и съёмка фото дополнительно проверяются на реальном устройстве.

## Текущая матрица приёмки

Все пользовательские проверки — EN/PL. Каждая запись результата указывает версии, набор данных, фактическую команду/маршрут, PASS/FAIL/не проверено и границу fixtures/live.

| ID | Проверка | Критерий |
|---|---|---|
| V01 | Первая помощь | Фото → недостающие три базовых сведения → анализ → результат без login/paywall; исходное unknown сохраняется |
| V02 | Повторная диагностика | Новое фото того же экземпляра с его фактической историей; вопросов нет даже при пустом журнале |
| V03 | Нет post-analysis опроса | Никакого disambiguation/threshold/answer-weight пути; неоднозначность не превращается в лечение |
| V04 | Starter и месяцы | Starter ID/diagnosis отдельны; Free=3/paid=100 от регистрации, первый период сразу, без reset на purchase/trial/restore/expiry |
| V05 | Конкурентная квота | Реально одновременные запросы на последнюю попытку; reserve/success/error/replay и граница короткого месяца |
| V06 | Каталог и коллекция | Каталог без фото/опроса/полной KB; поиск, save/read/restart; Free четвёртое отклонено, paid unlimited, replay не дубликат |
| V07 | Гостевое сохранение | До семи дней claim с исходными данными; гонка cleanup/commit и media ownership; после срока обычный новый flow без TTL-экрана/fallback/скрытого AI |
| V08 | Оплата | Два продукта, eligibility/trial/pending/cancel/restore/ownership, факт магазина и возврат к запрошенному действию |
| V09 | Окончание подписки | Все автоматические care tasks/reminders остановлены; данные/старые планы читаются, ручной care/undo/correct_date не создаёт продолжение |
| V10 | Применимость | Исправление вида/условий сохраняет исходный анализ; неподходящие будущие задачи/reminders paused, без нейтральных напоминаний |
| V11 | Дневник/outbox | Disk restart, lost response, replay, undo/backdate, стабильная история; pending не объявляется confirmed |
| V12 | Напоминания | Default/выбранный час, timezone/DST, отмена/перенос/logout/known offline expiry, без дублей |
| V13 | Права/удаление | Аккаунт B не видит A, private Storage/RPC grants, account/plant delete, фото и notifications не раскрываются |
| V14 | База | Частичные пригодные факты и фактическое покрытие; нет minimum count для видов/проблем/источников; provenance/rights/применимость/EN-PL |
| V15 | Средства и safety | Действующее вещество только по данным/применимости, без SKU/магазинов/таймера отзыва; unknown safety не безопасно |
| V16 | Базовые события | Только enum FR-051, dedup/server purchase, без приватного содержимого; сбой не блокирует пользователя |
| V17 | Фото/динамика | Реальные camera/gallery/контрольное фото того же экземпляра, отдельно upload/ownership и paid analysis; нет camera-light функции |
| V18 | Совместимость | Машинные schemas/SQL/API/DTO, чистая установка и forward upgrade; история/фото/владельцы/расход сохранены |
| V19 | Модель плана | ОТЛОЖЕНО OPEN-PLAN / T156: сначала принять шаги/длительность/завершение/обновление, затем уточнить критерии |

## Качество и готовность

SC-001/007/012/013 — usability минимум 20 участников на язык с заранее заданными критериями. SC-003/004 — независимые reference cases, минимум 200 в общей выборке, задачи определимого вида/причины оцениваются отдельно; сохранённые численные цели качества не являются числом обязательных видов/протоколов. Источники/метки не создаются оцениваемой моделью. SC-002 — latency по оговорённым фото/сети и timeout; ошибки учитываются.

T092–T099 сохраняют отчёты фактических результатов. Build и fixtures не доказывают живой auth, покупки, provider accuracy, Storage или полный пользовательский сценарий. Полный MVP не принимается, пока OPEN-PLAN не решён и зависимые маршруты не проверены. Снятые камера света, отчёт, дополнительные вопросы и товарная актуализация не нужны для приёмки.
