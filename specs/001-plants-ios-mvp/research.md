# Research: Plants iOS MVP

**Date**: 2026-11-01 · **Input**: [spec.md](spec.md) от 2026-10-30, конституция v3.0.0. Сохранённые ссылки предыдущего исследования не означают повторную live-проверку SDK/сервисов.
Исследование определяет решения для плана. Импорта каталога, вызовов платной модели,
настройки аккаунтов, развёртывания и измерений качества приложения ещё не было.

## R01 — Нативный клиент и локальные данные

**Decision**: iPhone, iOS 17+, Swift 6 language mode, SwiftUI + Observation;
модели состояния экранов и независимые доменные операции, репозитории данных.
SwiftData хранит кеш, локальные фото и устойчивую очередь операций; PostgreSQL —
подтверждённое состояние. Один ModelActor сериализует локальные изменения;
передача между акторами через Sendable-значения, а не объекты ModelContext.

**Rationale**: согласованный стек поддерживает локальную работу и явную синхронизацию.
iOS 17 — выбранная нижняя граница из-за SwiftData, не требование использовать новые API
без проверок доступности. На этом Mac обнаружен Xcode 26.3, build 17C529.
Версии SPM и серверных пакетов закрепляются lockfile при создании проекта.

**Alternatives considered**: CloudKit не выбран — нужен согласованный Supabase backend;
добавление отдельной базы на клиенте сверх SwiftData не требуется.

Источники: [SwiftData](https://developer.apple.com/documentation/swiftdata/),
[ModelActor](https://developer.apple.com/documentation/swiftdata/modelactor),
[Xcode requirements](https://developer.apple.com/xcode/system-requirements).

## R02 — Операции ухода и согласованная синхронизация

**Decision**: UUID операции создаётся до сети и вместе с намерением хранится в LocalOutbox. PostgreSQL применяет команду в одной транзакции: owner lock, operation_receipts, текущие данные, запись ухода/отмены, пересчёт задач и ответ. Receipt + payload_hash обеспечивают replay без дублей. Care-команды не отклоняются из-за старой revision и не требуют диалогов конфликта, если растение не удалено и данные валидны.

Delta читается напрямую по updated_at/deleted_at. Все writers одного owner сериализуются строкой profiles и повышают монотонную updated_at; GET /sync фиксирует её как until. Пагинация использует (updated_at, entity_type, id), а since обновляется только после последней страницы. Tombstones сохраняются до удаления аккаунта, outbox переживает полную перезагрузку кеша. Отдельные серверные журналы изменений и event-sourcing не используются.

**Rationale**: одна транзакция сохраняет согласованность журнала/задач, row locks и watermark предотвращают потерю позднего commit. Нужна история ухода и отмен, но не инфраструктура воспроизведения всего состояния из событий. Разные команды одного task возвращают один активный entry; самостоятельные записи имеют разные operation IDs.

**Alternatives considered**: прямые клиентские writes нескольких таблиц, отдельная дублирующая лента изменений и блокирующее ручное разрешение конфликтов ухода исключены.

Источник: [Supabase database functions](https://supabase.com/docs/guides/database/functions).
Точная семантика команд — [contracts/sync.md](contracts/sync.md).

## R03 — Доступ, фото и удаление

**Decision**: RLS на всех пользовательских таблицах и Storage policies на приватных
фото; проверка active account при каждом доступе. Owner UUID берётся из verified JWT,
а не из тела команды. Клиент не получает service-role key. Edge обрабатывает внешние
интеграции; привилегированные RPC имеют закрытые grants, фиксированный search_path
и явную проверку scope. Платные тела планов не входят в бесплатные проекции.

Собственные фото: приватные нормализованные дневниковые варианты и AI-производные;
необработанный оригинал может храниться локально (R08). Подписанные
ссылки выдаются на 60 секунд, не пишутся в логи. Передача между Storage и PostgreSQL
не объявляется общей транзакцией: загрузка, подтверждение и очистка имеют отдельные
идемпотентные состояния. Удаление сначала отзывает доступ и локальные уведомления,
затем удаляет объекты и записи; незавершённая очистка повторяется. Ранее выданная
ссылка может жить до своего TTL; статус удаления не сообщает о полной очистке до её завершения.

**Rationale**: публичная ссылка и простой JWT decode не защищают личную коллекцию.
После удаления Auth user старый JWT может ещё существовать; active-account gate
предотвращает доступ. Гостевые незаявленные результаты и фото очищаются через 24 часа;
постоянная история хранится до удаления владельцем. Operation_receipts хранится до удаления аккаунта.

**Alternatives considered**: публичный bucket личных фото и прямые ссылки модели без
ограниченного времени действия не выбраны.

Источники: [RLS](https://supabase.com/docs/guides/database/postgres/row-level-security),
[private buckets](https://supabase.com/docs/guides/storage/buckets/fundamentals),
[managing user data](https://supabase.com/docs/guides/auth/managing-user-data).

## R04 — Вход и сохранение гостевого результата

**Decision**: AuthenticationServices для Apple, GoogleSignIn для Google;
Supabase Swift signInWithIdToken создаёт постоянную сессию. До входа — техническая
anonymous Supabase session без дополнительного пользовательского шага.
Гостевой результат сохраняется через отдельный claim, одинаковый для нового
и существующего аккаунта. До смены сессии сервер выдаёт ограниченный claim proof;
после входа постоянный verified JWT и этот proof разрешают перенос конкретного draft.
Proof одноразовый, хранится сервером как hash, срок 15 минут; replay допускается
только как повтор той же операции тем же владельцем. Отмена входа не стирает draft.
До завершения claim отдельный гостевой credential остаётся в Keychain для безопасного
повторного получения proof в пределах TTL draft. Apple authorization code обменивается
сервером; credential для будущего revoke хранится отдельно и отзывается при удалении.

До входа локально сохраняются GuestDraftCache и подписанная сервером analysis_receipt,
связывающая job, установку, locale и хеши фото/исходного snapshot/предварительного результата.
После 24ч серверный draft может исчезнуть, локальный кеш — нет: plant.create восстанавливает
результат под permanent owner после проверки подписи и credential, без нового ИИ/квоты.
Origin draft ID дедуплицирует этот путь и claim. Кеш не считается доверенным только потому,
что получен с клиента; неполный кеш имеет явный путь сохранения доступных данных без диагноза.
Overrides применяются после проверки исходного контекста; новая комната необязательна.
Изменённые вид/условия создают snapshot версии 2, care_revision = 2 и stale исходный анализ.

Фото переносятся двухфазно: приватная staging copy → атомарная публикация metadata
новому владельцу → очистка старых объектов. До публикации ни чужие фото, ни половина
экземпляра не показываются. Claim ID гарантирует один новый экземпляр; совпадение
вида не объединяет разные растения.

**Rationale**: native sign-in не гарантирует сохранение anonymous UID. Swift linkIdentity
через OAuth и конфликты уже существующих identity не покрывают все наши сценарии.
Простой anonymous_user_id из тела запроса недостаточен для доказательства владения.

**Alternatives considered**: универсальная автоматическая привязка identity без
дополнительного claim отвергнута; guest-only локальное хранение усложнило бы контроль
стоимости и безопасную передачу результата.

Источники: [Apple auth](https://supabase.com/docs/guides/auth/social-login/auth-apple),
[Google auth](https://supabase.com/docs/guides/auth/social-login/auth-google),
[Swift token exchange](https://supabase.com/docs/reference/swift/auth-signinwithidtoken),
[anonymous sign-ins](https://supabase.com/docs/guides/auth/auth-anonymous),
[Swift identity linking](https://supabase.com/docs/reference/swift/auth-linkidentity).

## R05 — Подписки и принадлежность покупки

**Decision**: StoreKit 2, одна subscription group с двумя периодами: month/year. Покупка после
постоянного входа; сервер выдаёт стабильный appAccountToken UUID. Пара
(environment, originalTransactionId) принадлежит одному app account. Клиентские
Transaction.updates/currentEntitlements улучшают интерфейс, но платные серверные
операции разрешает серверный entitlement. Restore не переносит покупку между
аккаунтами автоматически; конфликт предлагает вход в исходный аккаунт без раскрытия данных.

Доступ: active и подтверждённый grace период; отключение автопродления не закрывает
уже оплаченный период. Expired/revoked и billing retry после grace не дают нового
платного плана. Сохранённые задачи и бесплатный журнал доступны независимо.
Ранее полученное тело хранится в PlanHistoryCache и остаётся читаемым после expiry/refund; актуальность/отзыв инструкций проверяются отдельно. Новые full планы требуют paid access, включая действующий trial.

Notifications V2 проверяются, надёжно сохраняются и дедуплицируются по notificationUUID.
После события выполняется сверка текущих статусов, поэтому позднее событие не
откатывает более новое состояние. Периодическая сверка восстанавливает пропуски.

**Rationale**: срок expiresDate сам по себе не описывает grace/refund; скрытый клиентский
paywall не защищает полный план. Изменение appAccountToken не считается разрешением
переносить чужую подписку.

**Alternatives considered**: RevenueCat добавил бы поставщика и платёжную зависимость;
в MVP используется согласованный StoreKit + Apple Server API.

Источники: [currentEntitlements](https://developer.apple.com/documentation/storekit/transaction/currententitlements),
[app account token](https://developer.apple.com/documentation/appstoreserverapi/set-app-account-token),
[notification delivery](https://developer.apple.com/documentation/appstoreservernotifications/responding-to-app-store-server-notifications).

## R06 — Проверка JWS в Edge Runtime

**Decision**: официальный @apple/app-store-server-library, включая SignedDataVerifier,
через npm в Supabase Edge Functions. Проверяются цепочка Apple roots, подписи внешнего
и вложенных JWS, environment, bundle ID, production appAppleId и allowlist продуктов.

**Rationale**: Supabase поддерживает npm и Node APIs; Apple документирует Node library,
но не гарантирует Deno. Это выбранный путь с обязательным ранним compatibility test,
а не утверждение о выполненном тесте. До приёмки платежей проверить в точной версии
Edge Runtime crypto/X509, network/OCSP, ошибочные цепочки и Server API JWT.
При несовместимости этап платежей останавливается до поправки плана; простой decode
JWS и обход подписи запрещены. Другой server runtime не вводится молча.

**Alternatives considered**: самописная криптографическая проверка не выбрана;
отдельный Node backend требует отдельного согласованного архитектурного решения.

Источники: [официальная Apple library](https://github.com/apple/app-store-server-library-node),
[Supabase dependencies](https://supabase.com/docs/guides/functions/dependencies).

## R07 — Runtime Vision: классификация, без генерации советов

**Decision (2026-10-25)**: существующий серверный AnthropicAdapter возвращает только
структурированную классификацию по [schema 3.0](contracts/ai-result.schema.json):
plant_id, до двух condition IDs с confidence, visual_markers/ограничения, follow-up comparison.
Все ID принадлежат pinned опубликованному KB release. Unknown/out-of-scope допустимы;
confidence не объявляется измеренной вероятностью. Plan не является режимом провайдера.

ProtocolResolver формирует PreliminaryAnalysis из наблюдений и готовых протоколов.
Обычный/recovery FullPlan формируется детерминированно из базы. Источники/продукты
модель не придумывает и не выбирает вне базы. Стоп/отказ/обрезка и неверные ID —
ошибка, не успешный расход пользовательской попытки. Точный output adapter проверяется G02.

**Rationale**: уменьшение генеративного риска, задержки и runtime токенов.
Это архитектурное решение, не измеренная точность или стоимость. Детали — R18.

## R08 — Фото, таймауты, стоимость и фоновые задания

**Decision**: дневниковое изображение сохраняется; клиент готовит JPEG для анализа, нормализует
ориентацию, убирает EXIF и начинает с длинной стороны 1568 px. На eval сравнить 2576 px,
особенно для мелких повреждений. Исходники больше 10 МБ не отклоняются: ImageIO downsampling,
нормализация и адаптивное сжатие выполняются до upload. Облачный дневниковый вариант
ограничен 10 МБ; AI derivative должен укладываться также в предел провайдера после base64.
Необработанный оригинал может оставаться локально; original_key — подготовленный дневниковый
вариант. Отказ подготовки только для повреждённого/нечитаемого файла, не из-за размера;
отказ доступа/сети — отдельная повторяемая техническая ошибка. Edge не перекодирует большие фото.

Задание сохраняется в analysis_jobs до ответа 202. Запуск Edge worker через pg_net
после commit, waitUntil — ускорение, а не единственное хранилище работы.
Reconciler через Cron раз в 10 секунд подбирает queued jobs и закрывает просроченные.
Lease и attempt token не дают двум результатам одновременно опубликоваться.
SDK maxRetries=0, provider timeout 40 секунд, общий job deadline 55 секунд;
provider timeout дополнительно ограничивается оставшимся deadline с запасом на публикацию;
job без достаточного времени в очереди закрывается, а не запускает заведомо поздний запрос.
интерфейс сообщает о неуспехе к 60 секундам. Начальный max_tokens=4096,
adaptive thinking + effort=medium; low сравнивается на eval. Эти значения — параметры
первого прототипа, не доказательство достижения p95 30 секунд.

Повтор клиентского запроса возвращает job; после неоднозначного provider timeout
автоматического повторного платного вызова нет. Exactly-once публикация результата
обеспечивается нами, exactly-once списание провайдера не обещается. Сохраняются usage,
latency и версии; глобальный лимит расходов и concurrency защищают от неконтролируемого
роста. Личные фото, токены и внутренние рассуждения в telemetry не пишутся.

**Alternatives considered**: длинный запрос из UI, неограниченные SDK retries и
единственная недолговечная background promise отвергнуты.

Источники: [Anthropic vision](https://platform.claude.com/docs/en/build-with-claude/vision),
[TypeScript SDK](https://platform.claude.com/docs/en/cli-sdks-libraries/sdks/typescript),
[effort](https://platform.claude.com/docs/en/build-with-claude/effort),
[Edge background tasks](https://supabase.com/docs/guides/functions/background-tasks),
[scheduling functions](https://supabase.com/docs/guides/functions/schedule-functions).

## R09 — Каталог, имена и иллюстрации

**Decision (обновлено 2026-10-25)**: seed 300 видов нормализуется через Perenual/RHS/NC State
с дополнительной сверкой WFO, Wikidata PL/EN names и
индивидуально одобренных Commons images в PostgreSQL. Внутренний taxon UUID стабилен;
внешние IDs и redirects хранятся отдельно, cultivar — квалификатор/alias, не новый вид.
WFO ID связывается с Wikidata P7715; точное научное имя проверяется с рангом/семейством.
Неоднозначный match требует редакционного разрешения, не fuzzy auto-merge.

WFO CC0 относится к backbone. Для первого импорта выбран проверенный релиз 2026-06
(DOI 10.5281/zenodo.20782718); фиксируются hash и версия. Wikidata structured data — CC0,
но P18 не даёт лицензию фото, label не всегда обиходное имя. Сохраняются revision IDs.
Commons: file ID/version/hash, original URL, автор, license URL, attribution и изменения;
предпочтительны CC0/public domain/CC BY, CC BY-SA — только при выполнении условий.
HTML из metadata очищается. Нет достоверного PL/EN имени — научный fallback.

**Rationale**: локальный versioned subset обеспечивает кеш и управляемые исправления.
Импорт проходит staging/diff/review/publish; новые релизы проверяются ежеквартально,
существующий каталог не меняется без публикации и не стирает историю.

**Alternatives considered**: live API при каждом открытии карточки не выбран.
Trefle CC BY 4.0 для своих данных полезен как резерв; upstream лицензируется отдельно.
OpenPlantbook не выбран до подтверждения прав на облачные данные; MIT клиентского
SDK не означает MIT на базу.

Источники: [WFO release](https://zenodo.org/records/20782718),
[WFO downloads](https://www.worldfloraonline.org/downloadData),
[Wikidata access](https://www.wikidata.org/wiki/Wikidata:Data_access),
[P7715](https://www.wikidata.org/wiki/Property:P7715),
[Commons reuse](https://commons.wikimedia.org/wiki/Commons:Reusing_content_outside_Wikimedia),
[image metadata](https://www.mediawiki.org/wiki/API:Imageinfo),
[Trefle terms](https://trefle.io/terms), [OpenPlantbook](https://open.plantbook.io/docs/).

## R10 — Источники ухода, safety и товары PL

**Decision (2026-10-25)**: собственные EN/PL Golden Records синтезируются офлайн
из разрешённых независимых источников с field_evidence и guardrails, без обязательного
специалиста. Доноры и 4 этапа — [knowledge-base-pipeline.md](knowledge-base-pipeline.md).
ASPCA safety cat/dog входит в профиль; unknown при отсутствии сведений/прав,
severity не додумывается. Публичная страница не является открытой лицензией.

Реестр MRiRW и актуальная этикетка проверяют разрешённое применение продукта;
Allegro/Castorama/Leroy Merlin — наличие предложения, не регуляторное разрешение.
Проверка <=30 дней, известный отзыв действует немедленно; бренд/вещество из задания —
кандидат, не одобренный товар. Неизвестная допустимость исключает рекомендацию.

**Rationale**: формальные проверки и сопоставление источников заменяют обязательное
участие специалиста в MVP, но не доказывают экспертную точность.

Источники: [Perenual API](https://perenual.com/docs/api),
[NC State example](https://plants.ces.ncsu.edu/plants/monstera-deliciosa/),
[ASPCA terms](https://www.aspca.org/about-us/legal-information),
[MRiRW registry and labels](https://www.gov.pl/web/rolnictwo/wyszukiwarka-srodkow-ochrony-roslin).
Проверено наличие страниц 2026-10-25; полный rights audit и импорт не выполнялись.

## R11 — PL/EN и напоминания

**Decision**: String Catalogs для UI и шаблонов уведомлений, stable codes для действий
и ошибок; preference определяется до входа и сохраняется. Каталог поддерживает PL/EN
и научные имена. Анализ/план хранит locale snapshot; смена языка не запускает анализ.
Исторические тексты остаются на языке создания. Перевыставляются только будущие
локальные уведомления с текущим языком и датами; чужие и отменённые уведомления удаляются.
Час задаётся profiles.reminder_hour_local (INT 0..23, default 9): 09:00 по местному
времени устройства, с редактированием в профиле. Час/timezone перестраивают будущие IDs,
без повторов доставленных уведомлений. Open и needs_review участвуют; для needs_review
нейтральный текст объясняет пересмотр, не выдаёт старый план за актуальный.
Окно ближайших 30 уведомлений пополняется при foreground и разрешённом background refresh;
точная доставка при выключенном устройстве/отозванных разрешениях не обещается.

**Rationale**: текст AI и язык интерфейса имеют разные жизненные циклы;
ограниченное локальное расписание не требует отдельной push-инфраструктуры в MVP.

**Alternatives considered**: машинный перевод всей истории при каждом переключении
и APNs backend на старте не выбраны.

Источники: [String Catalogs](https://developer.apple.com/documentation/xcode/localizing-and-varying-text-with-a-string-catalog),
[UserNotifications](https://developer.apple.com/documentation/usernotifications/),
[multilingual evaluation](https://platform.claude.com/docs/en/build-with-claude/multilingual-support).

## R12 — Приблизительная подсказка освещения

**Decision**: AVFoundation, задняя широкоугольная камера, выключенные flash/torch,
несколько стабильных кадров с параметрами экспозиции и признаками яркости.
Категории low/bright_indirect/unknown калибруются на физических iPhone;
это текущая качественная подсказка, не суточный режим и не lux/PPFD.
До замера показывается короткая подсказка по положению камеры. LightSource различает
manual/camera_estimate/unknown; подтверждение хранится в light_confirmed.
Ответ об обычном освещении пользователь подтверждает вручную. «Прямое солнце»
не устанавливается автоматически по одной экспозиции. При нестабильной сцене — unknown.

**Rationale**: экспозиция зависит от отражения, направления и камеры, а не только
от падающего света. Обязателен ранний физический прототип; FR-034 не исключается молча.
При непригодной точности требуется пересмотр спецификации до выпуска.

**Alternatives considered**: ARKit ambientIntensity не выбран как ботанический люксметр.

Источники: [capture exposure](https://developer.apple.com/documentation/avfoundation/capture-device-exposure),
[isAdjustingExposure](https://developer.apple.com/documentation/avfoundation/avcapturedevice/isadjustingexposure),
[ARLightEstimate](https://developer.apple.com/documentation/arkit/arlightestimate/ambientintensity).

## R13 — Проверки и готовность внешних зависимостей

**Decision**: Swift Testing для доменных/репозиторных проверок, XCUITest для основных
путей PL/EN, pgTAP для транзакций и RLS, Deno tests для контрактов/адаптеров;
StoreKit Testing, затем Sandbox для настоящих состояний подписки.
Качество ИИ измеряется на одной заранее размеченной выборке отдельно по каждому языку;
reference-based пороговые SC-003/004 не заменяются самооценкой модели;
обязательного специалиста нет, метки фиксируются по независимым источникам до запуска. Производительность — SC-002,
при неудаче изменяются параметры того же провайдера и повторяется проверка.

**Rationale**: доступны структура требований и выбранные решения, но ещё не готовые
app, каталог, credentials, fixtures или результаты eval. Это зависимости реализации,
не открытые архитектурные решения. Нужно настроить Apple/Google/Supabase, продукты,
корни Apple, ключи в server secrets и оба редакционных набора. Вопросов, требующих
нового пользовательского выбора для составления плана, не осталось.

На этом хосте simctl не получил доступ к CoreSimulatorService; список runtimes
и запуск simulator не подтверждены. Сборка приложения и живые интеграционные тесты
не выполнялись. Проверка окружения и physical-device прототип входят в начало реализации.

**Alternatives considered**: утверждать готовность по одному валидному JSON,
мокам подписки или успешному чтению документации недостаточно.

Источники: [StoreKit testing](https://developer.apple.com/documentation/xcode/setting-up-storekit-testing-in-xcode),
[account deletion](https://developer.apple.com/support/offering-account-deletion-in-your-app/).

## R14 — Starter, Free/Paid monthly и бюджет (обновлено 2026-11-01)

**Decision**: installation_access с независимыми starter ID/diagnosis, такие же маркеры profiles,
monthly_quotas с quota_kind free_monthly/paid_monthly и provider_daily_budget. Резерв в analysis_jobs,
термин trial только для подписки. Атомарный алгоритм, bind/OR и поля — [data-model](data-model.md#4-подписки-стартовые-и-месячные-квоты).

При Free сначала starter нужного режима, затем одна месячная попытка UTC с месяца после первого
успешного starter. Без starter success (даже после paid) Free-месяц ещё не начинается. Starter не сгорает;
Free не накапливается. При paid access только 100 за месячное окно от первого предоставления доступа,
включая trial; trial→paid/restore/смена тарифа не пополняют остаток. Running job остаётся в исходном
источнике/периоде, failure освобождает резерв, paid expiry до commit не переключает его на Free.
Успешный unknown расходует попытку. Bind ждёт live starter jobs и объединяет расход по режимам
и earliest success; TTL/logout не обнуляют права. До входа межустройственная уникальность неизвестна.

Provider cap/leases<=10/maxRetries=0 сохраняются; network вне locks. Стоимость ошибок включается
в расходы при отсутствии расхода продуктовой квоты; неизвестный usage/cost обозначается unknown.

**Rationale**: спецификация FR-005/017/065 и A-013, сериализация без отдельных reservation tables.
**Alternatives considered**: общий starter, Free от регистрации/expiry, суммирование Free+paid,
сброс при конверсии trial, перенос running job в новый месяц — противоречат принятой модели.

## R15 — Оба типа планов из Golden Records

**Decision (2026-10-25)**: `plant.create` допускает каталог без фото/анализа.
`mode=plan, plan_source=catalogue` использует PlantProfile; `plan_source=analysis` —
сохранённые наблюдения diagnosis/follow_up и применимый ConditionProfile на текущем
виде/условиях. Оба пути без LLM/provider budget/фотоквоты; full требует paid access, basic routine — Free-место либо paid access, с атомарной
публикацией plan/rules/tasks. Stale результат не переписывается; недостаток применимых
наблюдений даёт reassessment_required, не скрытый AI. Изменение care_revision до commit
даёт context_changed. Нет профиля — care_profile_unavailable до оплаты ради плана.

Release/protocol IDs, comparison_traits и photo_angle_hint берутся из базы.
Динамические проверки полива — SQL ScheduleCalculator по версионным коэффициентам,
истории и известным условиям; неизвестные параметры не угадываются.

**Rationale**: разделение классификации и назначения действий, отсутствие выдуманного
лечения, соблюдение коммерческой границы без дополнительной генерации советов.

## R16 — Доступ после подписки и граница генерации задач

**Decision (2026-11-01)**: право читать ранее полученный full план сохраняется после expiry/refund,
включая trial-планы. PlanHistoryCache owner-scoped, applicability/safety обязательны. Новые full планы
и premium occurrences требуют paid access. Basic care бесплатен для трёх выбранных экземпляров,
first_aid_control — один контроль без места; правила проверяются и в SQL/worker/offline replay.
Старые задачи/факты доступны. При исключении растения из Free-тройки его basic reminders выключаются,
история не удаляется; это отдельное правило A-014, не общая отмена старых premium задач при expiry.
Одно ближайшее occurrence на правило, forecast сам не создаёт task/reminder.

**Rationale**: непрерывный Free-путь и сохранность истории по конституции 3.0.0.
**Alternatives considered**: блокировка прежних планов, paid-only любые повторы, удаление задач и
бесконечный запас premium occurrences до expiry — исключены. Старые решения заменены в тексте.

Неприменимый план помечает незавершённые задачи needs_review, но не блокирует отметку
выполнения в один тап, приём отмены и локальные напоминания. Текст поясняет необходимость
пересмотра; следующий occurrence по неприменимым правилам не создаётся до нового плана.
Валидные care.record/care.undo применяются без блокирующих диалогов по текущим данным,
с сохранением фактов и объяснения расписания; deleted plant отклоняется явно.

ScheduleCalculator — DB-authoritative SQL-функция foundation. Она получает актуальные
reviewed rules/историю под общими блокировками и вызывается из транзакции US3 plan
publication и US4 care commands. Edge ScheduleCalculator.ts — только RPC adapter.
Первый water при неизвестной истории имеет condition_code = check_soil_first.
Резервы, параллельный bind и provider guard определены единообразно в R14 и data-model.md.


## R17 — Два намерения и персональный уход (решение 2026-10-22)

**Decision**: по прямому поручению владельца продукта оба намерения доступны с первого
экрана. Care разделяет intent и method; identification-only скан либо каталог →
подтверждение вида → три вопроса → вход/сохранение → персональный routine plan.
Problem сохраняет фото → три вопроса → первая помощь → recovery plan.
Identification использует классификационную схему 3.0, без diagnosis/comparison;
first_action/full_plan отсутствуют в provider schema;
раздельные starter identification/diagnosis, затем Free/Paid monthly определяются R14.
Обычный план по reviewed care_profile и условиям одинаков для скана и каталога,
имеет бесплатный basic уровень в пределах мест и full при paid access; не требует LLM/фотоквоты и не назначает лечение.
Неизвестный вид и отсутствие профиля объясняются до предложения покупки ради плана.

**Rationale**: нельзя исключать пользователей, пришедших за повседневным уходом.
Первые выборы, переключения и конверсия до покупки/плана измеряются по flow_id,
intent и method. Роутер отделён от ухода/хранения, поэтому будущее скрытие входа
не требует удаления коллекции и истории. Это отдельное продуктовое решение по данным,
не автоматический gate и не вывод о текущем спросе; измерений ещё нет.

**Alternatives considered**: каталог как вторичная кнопка при основном сценарии лечения
не решает задачу явного выбора намерения; диагностика вместо идентификации навязывает
проблему здоровому растению; автоматическое отключение ветки выходит за текущий объём.

## R18 — Hybrid AI + Golden Records (2026-10-25)

**Decision**: принят [knowledge-base-pipeline.md](knowledge-base-pipeline.md): 300 plant
profiles / 40 conditions, seed/taxonomy → multi-source Markdown → offline LLM synthesis
со схемами и guardrails → EN/PL + EU/PL product mapping. Runtime только классифицирует.
PlantProfile и дополненный ConditionProfile имеют канонические схемы в contracts/.
Source registry по каждому донору блокирует неразрешённый ingestion/LLM use; 3–4
независимых донора на запись, конфликты и неполное покрытие — карантин. Нет обязательного
специалиста; reference-based eval не называется экспертной сертификацией.

**Supersedes**: прежняя online генерация recovery/stale plan, provider budget для plan,
~200 видов и полный feature gate токсичности. Ни импорт, ни готовность лицензий,
ни фактическая регистрация препаратов, ни достижение SC-003/004 этим решением не утверждаются.

**Alternatives considered**: runtime создание лечения LLM, копирование сайтов без прав,
обязательный специалист на MVP и применение препарата по одному бренду исключены.

## R19 — Дополнение полным промптом: уточнение и лечебные шаги

**Decision**: ConditionProfile из полного текста заменяет самостоятельно дополненную
ConditionProtocol. Provider schema 3.0: plant_id, visual_markers, топ-2 с confidence.
Если top1<0.80 либо scores близки, 1–2 готовых вопроса Да/Нет; backend пересчитывает
решение без нового Vision/квоты. Начальный gap<0.10 и answer_weight=0.15 — инженерные
допущения release policy, а не измеренная калибровка. Skip/нет вопроса/противоречие
оставляют неопределённость. Исходный анализ immutable; decisions/answers/receipt отдельно.

Тип горшка и season override — необязательные поля онбординга; три базовых вопроса
сохраняются, прежнее исключение любых дополнительных вопросов заменено ограниченным
disambiguation flow. Поля лечения: contagious/urgency/duration, ordered phases,
interval_days/repeat_count и локализованные действия; active ingredients/eco — альтернативы.
Тексты/4 недели/7 дней/3 применения/препараты из примера не считаются проверенными данными.
SQL разворачивает schedule; repeat_count — total occurrences, start_offset отделён
от repeat spacing. Materialization/подписка/история и локальные reminders сохраняются.

**Supersedes**: draft топ-3 без confidence и отсутствие уточнений. Никаких новых
заявлений о текущей регистрации средств или эффективности примера не сделано.

## R20 — Narat: Free-путь, trial, отчёт и измерение (2026-11-01)

**Decision**: basic_care_memberships с free_slot 1..3 и стабильным enabled_at; выбор атомарен под
owner lock, expiry сохраняет выбранную тройку/первые три. Правила access_class разделяют basic,
first_aid_control и premium; full routine не дублирует базовые проверки. First aid хранит один контроль
на origin_analysis_id, из протокола без универсального срока; наблюдение/фото не требуют AI.
Recovery transition явный и проверяет текущее состояние; completion не доказывает выздоровление.

Два продукта, store eligibility и подтверждённые trial dates; opt-in reminder за 24ч. RequestedAction
сохраняет контекст покупки, отказ возвращает к Free; приложение не навязывает paywall при запуске.
Progress Report — бесплатная детерминированная проекция фактов за завершённый местный месяц.
Фото/отмены/исправления учитываются, upcoming отделены; кеш ключуется owner/month/timezone/locale/watermark.
Server notification claim owner+month без timezone исключает дубли на устройствах; UserNotifications
сохраняется без APNs backend. При неопределённой доставке предпочитается пропуск, не повтор.

Аналитика отделена от пользовательского отчёта: фиксированные клиентские события, подтверждённые
billing facts, provider usage/cost (включая ошибки), completed cohort windows и знаменатели; нет
приватного содержимого, выдуманного LTV или автоматического пересмотра Free-параметров.

**Rationale**: FR-015–023/051/065–068, A-013–016, NR-A1–10. Это дизайн по согласованной спецификации,
не повторная проверка текущих SDK/магазина; их live compatibility остаётся G02/G07.
**Alternatives considered**: отдельный сервер push, AI-отчёт, timezone в ключе notification,
генерация лечения по отметкам и сброс квоты при оплате — не нужны или противоречат требованиям.
