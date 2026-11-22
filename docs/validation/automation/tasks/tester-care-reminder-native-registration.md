# D2B early registration acceptance

## D2B ранняя native регистрация принята — 22 ноября 2026

Принят f12adfce93ea524af98cbbd58ff3ce5feb054281. CareReminderAppDelegate.swift, PlantsApp.swift и CollectionWireTests.swift:
192+/12-. Инертный AppDelegate владеет единственным Inbox и strong Bridge, синхронно
назначает weak UN delegate до didFinish return только после общего launch-policy.
Обе ветки App передают тот же Inbox вместе с существующим выбранным runtime; Root
сохраняет validated dedicated-fake exemption и общий guard также в Release. Старый
fixture unit адаптирован только к обязательному новому initializer и усилен проверками;
старые assertions/helper defaults не ослаблены, четыре новых launch/lifetime/cold теста.

Фактические PASS:482 Swift (479XCTest+3/missing0), diff-check 0.049с, automation-tests 43.914с, care-release-compile 99.345с, ios-tests 156.106с, tester-consent-ui 588.922с, tester-result-save-ui 59.093с, simulator-smoke 23.584с, tester-care-ui 495.104с, tester-today-ui 199.88с.
developer 201.789с, reviewer 98.107с, qa 147.501с; protocol+semantic PASS/findings0.
Release — actual compiler witness без backend/Google/sign/install/launch, НЕ ordinary SDK/live.
Старые13care/Today6/4ENPLrender и новые8consent выполнены с неизменёнными assertions/
strict ledgers. Inert/fake installer tests не равны actual OS launch/callback delivery.

Маршрут пока только удерживается Inbox: D3 immutable original SDK/lease/locale binding,
currentOccurrences/sourceDue/canonical target/one-shot и scoped foreground local read
ещё не подключены. Затем обязательны actual ordinary System/Scheduler/SDK closed-app
доставка+tap/known cleanup и latest signed artifact. ParentT075/T077/T080/T098 открыты;
technical only/physical+external отложены; hard50soft48/noreset. Root user3 не тронуты.
