# Что осталось до запуска Narat — 9 ноября 2026

Проверен локальный HEAD `587eae9`, действующие spec/tasks/quickstart и код. Это оценка готовности, без реализации, deploy и проверки состояния production. Проект пока не готов к публичному запуску: основной пользовательский маршрут ещё не подключён целиком.

## Подтверждённая основа

- SwiftUI-проект, подготовка фото, нативные auth-компоненты, локальное хранение/outbox и API-клиент уже существуют. Каталог позволяет просматривать карточки через Supabase RPC, но не сохраняет экземпляр растения.
- Серверный T161 принят локально: Free collection cap=3, paid без лимита коллекции, retirement Free-мест. Часть упрощения DTO/контрактов и клиентский срез T168 приняты. Родители T155/T157–T160 и полная T168 открыты.
- В tasks: 14 отмечены, 137 открыты; T172–T174 — необязательные комнаты. Число задач не является процентом готовности и включает пересекающиеся работы/приёмки.
- По предыдущим отчётам: PostgreSQL/pgTAP, 259 Deno fixtures, 29 PlantsTests и локальный Simulator smoke PASS. Эти suites в текущем обзоре заново не запускались целиком; live фото→уход ими не подтверждён.

## Шесть блоков до запуска

| Блок | Что ещё требуется | Основные задачи |
| --- | --- | --- |
| Сохранение и синхронизация | Подключить настоящие API adapters и commands/sync; коллекцию, карточку и подтверждённое сохранение из каталога/результата. Довести Free cap на клиенте, pending/retry/restart и owner isolation; исправить положительный guest claim и семидневную очистку. | T019, T040–T049, T149–T151, T154, T162, T166 |
| Фото и анализ | Соединить camera/gallery→upload→job→worker→provider→результат, независимый identification/unknown, возврат при ошибке и единый результат с сохранением. Завершить новый основной вход и manual/unknown inputs. | T005, T029–T039, T100/T101, T153, T157, T168–T170 |
| Данные и рекомендации | Завершить редактуру каталога, EN/PL и медиа; опубликовать небольшую проверенную партию компактных карточек с происхождением/правами/применимостью. Подключить resolver и простой PlanService. Количество видов не заменяет пригодность советов. | T021, T092, T108–T120, T148, T055/T056, T167 |
| Повседневный уход | Карточка, Today, журнал/фото/правки, record/undo/backdate и следующая проверка; базовые повторы и один контроль первой помощи, reminders/пауза. Исправить несогласованные premium SQL consumers и полную остановку автоматики после expiry. | T018, T051, T061–T081, T127–T137, T139, T160/T164/T171 |
| Доступ и покупки | Общий месячный период от регистрации, два starter, Free=3/paid=100 анализов без повторной выдачи расхода; StoreKitService/paywall, Apple server verification/webhook/reconciliation, restore/trial/pending/cancel и Sandbox приёмка. | T007/T012/T013, T020/T028/T030/T036, T050–T060, T132–T134, T163/T165 |
| Безопасность и выпуск | Профиль/выход/удаление, RLS/Storage/A-B; живые auth/Storage/AI/StoreKit и физическая камера. Довести CI, UX/EN-PL, заранее заданный reference eval, замеры задержки и итоговую матрицу. Подготовить release archive/signing, иконку, актуальные скриншоты и материалы магазина; публикационная готовность не проверена. | T006/T015/T016, T082–T086, T093–T099, T103–T106, T118/T146/T154 |

## Прямые доказательства блокеров

- `ios/Plants/Features/Analysis/AnalysisFlowModel.swift`: `submitAnalysis` всегда выставляет `analysis.error.unavailable`; upload/jobs/provider не вызываются.
- `supabase/functions/plants-api/index.ts`: штатный `Deno.serve(createPlantsApiHandler())` не передаёт adapters для installations/access/media/jobs. `/sync` и `/commands` без handlers возвращают 503; basic-care/claim/catalogue модули в router не подключены. Наличие отдельных модулей не означает работающий HTTP-маршрут.
- В `ios/Plants/Features/` есть только analysis/onboarding/catalogue; пользовательские collection/card/care/profile/paywall экраны ещё не реализованы. Catalogue selection сохраняет выбранный ID в UserDefaults, не экземпляр на сервере.
- Нет `AppleBilling.ts`, `plants-api/billing.ts`, `billing-webhook/index.ts`; StoreKit-конфигурация не подтверждает покупку. `deno task check` также ссылается на отсутствующие billing-webhook/maintenance entrypoints; сама команда в этом обзоре не запускалась.
- В `.github/workflows/validate.yml` нет SQL job, iOS выполняет `build-for-testing` без запуска PL/EN tests. `AppIcon.appiconset/Contents.json` не содержит файла иконки. Новые ASO-изображения по handoff ещё не приняты.
- В handoff зафиксирован premium baseline gap: `can_owner_schedule_rule` использует отсутствующие в схеме поля `care_plans.applicability_status/chemical_must_revalidate_after`; перед T164/T167/T171 нужна реализация и отдельная проверка этой ветки.

## Фактически выполненные проверки обзора

- Чтение текущих Swift/TS/SQL/CI, инвентаризация файлов, сверка handoff/tasks и подсчёт checkbox: 14/137.
- `cd supabase/functions && deno test --cached-only --allow-env --allow-read --allow-net=127.0.0.1,localhost _shared/tests/persistence_unavailable_test.ts`: **15 PASS, 0 failed**. Это fixtures: подтверждён корректный отказ 503 и делегирование явно переданным handlers, не работающая persistence.
- `git diff --check`: PASS после обновления документов.
- Новые SQL, iOS/Simulator, live Supabase/Auth/Storage/AI/StoreKit, физический iPhone, качество данных и состояние App Store Connect в этом обзоре не проверялись. Никакие продуктовые checkbox не закрыты.

## Следующий шаг

Подготовить ограниченный пакет T162 на принятом T161. Поскольку рабочего сохранения ещё нет, явно выделить нужный фундамент T019/T044–T048: настоящий command/sync adapter → repository → минимальные коллекция/карточка/сохранение из каталога. Затем принять cap до операции и server rejection, legacy decode, pending/retry/restart и A/B. Не закрывать T162 одним удалением DTO. Реальный test backend проверять отдельным интеграционным прогоном.

После этого T163 → T166 и оставшаяся T168 → T170/реальный фотоанализ; данные/карточки готовить отдельным ограниченным пакетом. T164/T165/T167/T169 → T171 завершают простой уход; StoreKit и публичная приёмка остаются обязательными для заявленного платного MVP. Комнаты T172–T174 запуск не блокируют. Это порядок поставки, а не разрешение запускать всю очередь в этом обзоре.
