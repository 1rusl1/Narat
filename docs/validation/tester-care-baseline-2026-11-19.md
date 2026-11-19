# Исходное состояние версии ухода — 19 ноября 2026

Основа: commit 3444be7; работа в codex/tester-care-20261119. Это проверка
текущего кода и локальных fixtures, не новая живая приёмка staging/iPhone.

## Что переиспользуем

- CatalogueCollectionCardView содержит полив, журнал, правку даты, отмену,
  enable/refresh базового ухода, обычную проверку грунта и её отмену.
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
2. До «Сегодня» и notifications нужен единый typed owner read-model текущих
   задач. Сейчас next_check/routine_check читаются при открытии конкретной
   карточки через GET recommendation, а sync care_tasks сам по себе не
   удостоверяет актуальность применимого правила. Массовый список не должен
   порождать отдельные расчёты интервалов или GET каждой карточки.
3. Разработать минимальную каноническую проекцию для списка и связать её с
   care revision, active rule, due local date, pause/deletion/expiry и owner.
   Карточка/Today/notifications должны использовать одну семантику.
4. Затем добавить Today (today/overdue/next/empty/offline/error), reuse
   существующих команд, обновление после record/correct/undo/refresh.
5. Затем care planner → OS reconciliation → consent/settings/deep link;
   проверить cancellation/logout/expiry и реальную доставку iPhone.

Справочный полив каталога не является автоматическим care profile.
606/606 watering records и genus/group matching не разрешают превращать
seasonal watering interval в check interval без принятого правила.
Новые источники/рекомендации, purchases, auth/delete-account вне пакета.

## Проверки и ограничения

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
