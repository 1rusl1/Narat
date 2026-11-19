# Этап 1: живой online цикл текущего ухода

19 ноября 2026. **PASS в указанном scope:** ordinary signed EN Release,
существующая тестовая Free-учётка, живой staging и отдельный owned Simulator.
Физический iPhone и реальное отключение сети этим прогоном не проверялись.

Исходник сборки `df71eb52d592037a4db8e2cf04d8bc02af3f2071` побайтно равен
принятому `b7845a88c1bebcb47e3088802f6df25242b8a88e` во всём дереве `ios`.
Подпись, staging host, исключение DEBUG fixtures и совпадение установленного
и собранного executable проверены. SHA256 executable:
`a81670ea4f4b2f54490eb2386a5aa0a243121512accf41a360c30d7a23cbc87f`.

## Фактический результат

Использована прежняя HTTP-created Monstera без локальной create-квитанции.
В начале у неё был один voided полив из предыдущей проверки, включённый
базовый уход, medium light и отсутствие активного факта/следующей даты.
Существующий опубликованный интервал проверки — 7 дней. Новые интервалы,
источники, диагнозы, покупки и entitlement не создавались.

| Действие в обычном UI | Канонический результат GET/sync и UI |
| --- | --- |
| Record watering, 19 ноября; cold reopen | Новый water fact, следующая проверка 26 ноября |
| Исправить дату на 12 ноября | Та же entry/operation identity; проверка сегодня, 19 ноября |
| Mark soil checked | Отдельный check_soil fact; следующий контроль 26 ноября |
| Undo soil check | Факт voided; дата вернулась на 19 ноября |
| Исправить полив на 18 ноября | Исходная identity сохранена; следующая дата 25 ноября |
| Light medium → low | care_revision=2; календарь снят, история сохранена |
| Второй ручной полив при low | Второй намеренный water fact; календарь не возобновился |
| Light low → medium | care_revision=3; календарь по-прежнему на паузе |
| Явно Update care recommendation | Применимое правило вернуло 26 ноября по новому поливу |
| Undo второго полива | Дата вернулась на 25 ноября по первому активному факту |
| Undo первого полива; cold reopen | Оба новых water и routine fact voided; next_check/routine_check=null |

Итого: **2 намеренные новые записи water и 1 check_soil**, три разных operation ID.
Это не три попытки одного действия. Все три в конце отменены; прежние entry,
reversal и analysis rows остались неизменными. История после cold содержит
предыдущий полив и все новые факты, включая отменённую проверку грунта.
Root просмотрел PNG ручной записи на паузе, явного refresh и итоговой cold-истории.

## Проверки и восстановление harness

- [Принятый технический пакет](automation/tasks/tester-care-owner-reconcile-recovery-acceptance.md):
  327 Swift (324 XCTest+3 Swift Testing), 149 automation, ordinary welcome1,
  MCP, 13 EN UI, exact fixture ledger4POST/1commit, Review/QA — PASS.
  Это отдельные fixtures; они не заменяют этот живой online прогон.
- Обычный `xcodebuild` Release выполнялся из frozen checkout через общий
  Xcode/Simulator resource lock, с ad-hoc подписью и без fixture launch arguments.
- Первый UI-harness остановился до Confirm: новых фактов не было. Исправлено
  только ограниченное ожидание/повтор открытия диалога, без повторных Confirm.
- После пяти выполненных действий harness не нашёл дальнюю кнопку света:
  AX snapshot отбрасывает offscreen controls. Затем понадобилось повторно
  открыть native dialog в текущем UI-сеансе. Первый FAIL и checkpoints сохранены.
- Контроллер перечитал GET/sync, проверил точную фактическую остановку и продолжил
  **только step08 и оставшиеся действия**. Ранее выполненные записи/исправления/
  routine не повторялись. Исправлены только private scroll/dialog helpers;
  продуктовый исходник во время прогона не менялся.
- Финальный resume exit0, checkpoint PASS/inflight=null, все HTTP/UI assertions
  и проверки identity/сохранности прежней истории прошли.

Private helpers: `/private/tmp/narat-tester-care-wiring-live{,-driver}.py` и
`/private/tmp/narat-tester-care-wiring-live-resume-conditions.py`. Данные доступа,
raw logs, checkpoints и 16 основных PNG остаются вне git в
`/private/tmp/narat-tester-care-wiring-live-evidence-20261119/`.
[Sanitized JSON](tester-care-stage1-live-2026-11-19.json) содержит только результаты,
test IDs и SHA256 кадров. Паролей, bearer/service keys и SDK session в нём нет.

Signed app сохранён в `signed-release-df71eb52d592/Plants.app` того же каталога.
После codesign/SHA проверки удалён только наш воспроизводимый derived-data
каталог; build log, исходник, app, screenshots и общие caches сохранены.

## Ограничения и следующий этап

Это техническая и живая **online** приёмка существующего цикла. Реальный radio
offline/reconnect на iPhone и доставка OS notifications ещё открыты. Текущие
UI source-withdrawal/expiry доказаны fixtures, не live изменением общей KB.
First-aid API/Storage прежних этапов использовали маркированный диагноз/
контроль без опубликованной даты; новый обычный положительный диагноз здесь
не создавался. При отсутствии основания даты приложение не выдумывает контроль.

Полные T065 и B01–B11 не закрыты. Следующий этап — owner care overview и «Сегодня»
на тех же подтверждённых данных; затем care reminders и физическая приёмка.
Для безопасной выкладки выбран отдельный additive Edge slug `care-overview`:
существующие plants-api33, worker и account-delete routes не перевыкладываются.
