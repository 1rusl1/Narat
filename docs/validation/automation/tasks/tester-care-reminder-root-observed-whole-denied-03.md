# Observed WHOLE03: actual denied XCTest activation exception

22 ноября 2026. Run tester-care-reminder-root-observed-whole-20261122-03 BLOCKED/checks; actualdiff0.023/149automation44.468/Release70.664/494Swift129.114 PASS. Old8consent actual7PASS/1FAIL613.353с; new3routingV4 НЕвыполнены, Review0/QA0. Rawq-d11585e76f613b7c80d105bc и весь run сохранены, не превращены в PASS.

Exact failure: testReminderDeniedKeepsManualJournalAvailable, CatalogueSaveUITests.swift1878 reminderReach→element.isHittable: “Activation point invalid and no suggested hit points based on element frame”. Этот сценарий кнопку ухода НЕ нажимает: проверяет доступность/label/enabled/manualjournal; care write здесь не выполнялся.

Actual artifact audit: failure AX99BA9EEB-A4A2-4679-A894-2DC2B03C978C.txt показывает Fixture3card, Record watering Button frame{{16,585},{118.333,19.333}} внутри cardScrollView{{0,62},{402,812}}, Settings/unknownmodal отсутствует. Failure snapshotFC2F20E4-A505-4962-AD96-DBC3359783A5 — binaryNSKeyedArchive, НЕPNG; decoded targetnode1192: identifier collection.watering.record, enabled=true и тот же положительный frame.

MP4 27927645-33A3-4BE3-8126-24885BFC5709.mp4 только прочитан/декодирован AVFoundation под sharedresource; App/Simulator actions0. PrivatePNG narat-d3b-denied-final-20261122.png (42.615с), narat-denied-activation-42.8-20261122.png(actual42.778), narat-denied-activation-43.0-20261122.png(actual42.922) визуально осмотрены: Record синий/видимый/внутриviewport. Между ранним/поздними кадрами появляется Updatecare button и меняется layout. Это поддерживает transient native hittability/layout timing, но точная причина exception НЕустановлена; productdisabled/permissionbug НЕутверждается. Parent independently read AX/source and allowed ONE bounded same-source retry after this audit.

Source equality: production unchanged; narrowfixture newtimestamp ternary действует ТОЛЬКО mode.routing, denied сохраняет Self.time(0); entire previousUITestsource/helpers bytepreserved insert-only, newthird85lines only. V4/old8 gates/assertions unchanged.

Далее ОДИН freshObservedWHOLE04, те же7sourcebytes/basecc/all10/models900/highReviewQA; Developer0 (нет пустого fakeDeveloper), без manualreinstall/reset/DD/cachechanges. Если стабильный повтор — отдельныйactualnarrowDeveloperhelperrepair на фактической причине, не слепые повторы/ослабление assertions. Source остаётся непринятым/Rootcc; no ordinarySDKSystemlive/domainwrites/finalPersonal yet.
