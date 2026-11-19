# Исходное состояние версии ухода — 19 ноября 2026

Основа: commit 3444be7; работа в codex/tester-care-20261119. Это проверка
текущего кода и локальных fixtures, не новая живая приёмка staging/iPhone.

## Что переиспользуем

- CatalogueCollectionCardView содержит журнал полива, правку даты, отмену,
  enable/refresh базового ухода, обычную проверку грунта и её отмену.
  Запись нового полива пока доступна только в post-save, не в открытой из
  коллекции карточке; это первый пакет завершения цикла.
- CollectionRepository/LocalStore сохраняют точный outbox и receipts на диске;
  CollectionWireTests покрывают loss/restart/replay, owner boundaries и
  каноническое подтверждение этих операций.
- Первая помощь, ручное наблюдение и optional photo уже имеют API/Storage,
  owner sync, клиентский outbox, UI и tests. Они не требуют второго AI.
- Принятые V11/V19 отчёты подтверждают отдельные живые срезы. Клиентский expiry
  и cold restart ранее проверены с synthetic paid сроком; это не StoreKit.
- Час напоминаний хранится через profile.update. Существует только отдельный
  TrialReminderScheduler; care ReminderScheduler и экран Today отсутствуют.

## Фактические разрывы и следующий пакет

1. Не объявлять B01–B05/B07 готовыми заново по файлам или unit tests:
   требуется пройти матрицу на актуальной Free-сборке и сопоставить версии
   staging. Этот обзор живой доступ/миграции не изменяет.
2. Сначала добавить owner-scoped запись полива для существующего растения
   через нынешний durable outbox, без create-confirmation и routine gating.
   Затем довести общий reconnect/foreground drain: сейчас автоматически
   повторяются не все pending care-команды.
3. До «Сегодня» и notifications нужен единый typed owner read-model текущих
   задач. Сейчас next_check/routine_check читаются при открытии конкретной
   карточки через GET recommendation, а sync care_tasks сам по себе не
   удостоверяет актуальность применимого правила. Массовый список не должен
   порождать отдельные расчёты интервалов или GET каждой карточки.
4. Разработать минимальную каноническую проекцию для списка и связать её с
   care revision, active rule, due local date, pause/deletion/expiry и owner.
   Карточка/Today/notifications должны использовать одну семантику.
5. Затем добавить Today (today/overdue/next/empty/offline/error), reuse
   существующих команд, обновление после record/correct/undo/refresh.
6. Затем care planner → OS reconciliation → consent/settings/deep link;
   проверить cancellation/logout/expiry и реальную доставку iPhone.

Справочный полив каталога не является автоматическим care profile.
606/606 watering records и genus/group matching не разрешают превращать
seasonal watering interval в check interval без принятого правила.
Новые источники/рекомендации, purchases, auth/delete-account вне пакета.

## Проверки и ограничения

Run `tester-care-baseline-20261119-02` принят в `ecd5ab0`: 149 automation,
436 Deno, 312 Swift, один welcome, MCP smoke и 7 EN care UI — PASS;
Reviewer/QA — PASS. Отдельно живой read-only HTTP: auth, /me и /sync 200,
постоянный Free-профиль, пустая коллекция, час 9. Записи ухода не создавались.
Это обновление фактического baseline; полный B01–B11 всё ещё открыт.

Результаты baseline-run фиксируются оркестратором отдельно в task report
и handoff. До завершения run этот документ не заявляет PASS тестов.
В baseline входят полный PlantsTests, обычный Simulator smoke, Deno suite
и выбранные EN XCUITest текущего ухода. Это fixtures/local, не live.
Все B01–B11 и родительские T160/T171/T098 остаются открытыми.

## Найденный и исправляемый блокер инфраструктуры

Первый baseline run `tester-care-baseline-20261119-01` получил 436 Deno PASS,
но остановился на `ios-tests`: doctor выбирал удалённый welcome-test.
`xcodebuild` завершился с 0, а xcresult содержал 0 tests; строгий gate
корректно вернул FAIL. Unit и следующий UI ещё не запускались.

Контроллер исправил только защищённые automation paths: doctor теперь
выбирает существующий `testOrdinaryLaunchShowsPhotoAndCollectionRoutes`;
MCP smoke открывает доступный каталог с обычного homepage без backend и
проверяет штатное error/back состояние. Проверки количества/skips и
изоляция backend сохранены. До независимой приёмки это кандидат, не PASS.
Локальные 149 automation tests прошли; новый baseline повторит все gates.

## Принятый baseline и конкретный продуктовый gap

`tester-care-baseline-20261119-02` принят независимыми Review/QA и опубликован
в `ecd5ab0`: 149 automation, 436 Deno, 312 Swift (309 XCTest + 3 Swift Testing),
один ordinary welcome, MCP navigation/screenshots и семь EN care UI PASS.

Отдельный read-only HTTP на staging: вход постоянной dedicated Free-учётки,
Auth user, /me и /sync вернули 200; entitlement=null, коллекция пуста, час 9.
Без создания растений, AI, покупок или deploy. Обезличенный отчёт рядом:
`tester-care-live-baseline-2026-11-19.json`. Это не B01 и не iPhone-сценарий.

Проверка фактических действий выявила пропуск: после повторного открытия
карточки коллекции нельзя записать новый полив. Record watering есть только
в post-save CatalogueSaveView. Repository.enqueueWateringEdit(.record)
возвращает invalidRequest; submitManualWatering требует create-confirmation.
Первый implementation пакет добавляет existing-card manual record на
существующем outbox, затем UI и явное canonical подтверждение.

Второй пропуск: reconnect/foreground в карточке сейчас автоматически
повторяет лишь manual correction/undo. Для прочего pending care нужен общий
owner-bound drain/reconcile с обновлением журнала и дат, без второго outbox.
Агрегат Today следует после закрытия этих разрывов этапа 1.
