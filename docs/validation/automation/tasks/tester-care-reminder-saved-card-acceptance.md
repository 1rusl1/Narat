# SavedCard M2c full UNION acceptance

## Мосты SavedCard M2c приняты; подготовлена общая приёмка B — 21 ноября 2026

Принят/pushed `4f002ca2969481bf81c5f3a0d6cf310870349c13`. Изменены PreliminaryResultView.swift,
CatalogueSaveModel.swift, CatalogueSaveView.swift, GuestCatalogueView.swift,
CatalogueConnectionTests.swift, CollectionWireTests.swift и PlantsUITests.swift (ровно6строк keepAlways attachments, assertions unchanged). Оба реальных Preliminary SaveView
передают frozen languageStore guard. Native includeManual передаётся ДО первого save/settle;
loaded-adopt сохраняет ready/pending без позднего второго fullread. Restore и explicit details retry
используют отдельный readCard: actual await/JOIN detailsTask до success ИЛИ failure,
original SDK/model lease/UI locale/ticket/target identity; это UI READ intent, не mutationACK.
Mutation settle не получает read callback и не дублирует событие; Root coalescer — единственный инициатор bounded refresh operation (внутри допустимы ≤2 GET и один align).

Реальные проверки PASS: 465 Swift (462 XCTest), missing0,
build/welcome 125.472с;149 automation 46.053с;
diff 0.02с;8 consentUI+strict fakeOS/server ledgers
602.106с;4 existing EN/PL result presentationUI
60.03с;MCP 30.132с.
Developer0 в этой read-only UNION приёмке. Real provenance: исторические M2c465.925+102.173+116.934(empty patch), UIhelper51.995с. high Review 176.286с и QA
214.518с semanticPASS. Четыре presentationUI доказывают render,
НЕ submit/полив/новый AI; native и read settlement проверены realSDK/Store + scriptedtransport.

Четыре реальных per-exact-test PNG экспортированы и строго проверены: actualtestIdentifier/URL,
nameprefix/device/nonfailure, nonempty decoded PNG/CRC/IDAT, unique paths/hashes, noforeigncase.
- testDiagnosisSavePresentationEnglish: `/private/tmp/narat-tester-care-20261119/docs/validation/automation/runs/q-4d459187e8c4399c2af33c31/attachments/3920D6A6-AE8B-4C14-B17C-B4D3DA6D1643.png`, SHA256 c5cca8cb428a7c3db893d25809c497b94cc994f5bcd36b55572d77b318e36463
- testDiagnosisSavePresentationPolish: `/private/tmp/narat-tester-care-20261119/docs/validation/automation/runs/q-4d459187e8c4399c2af33c31/attachments/4B454AD4-9CAB-40B0-BAA3-8185C0A28417.png`, SHA256 2e49b94b5532dda7e5d8872105fee8a97a17c1854c92b784ea3cc4e45294747d
- testIdentificationSavePresentationEnglish: `/private/tmp/narat-tester-care-20261119/docs/validation/automation/runs/q-4d459187e8c4399c2af33c31/attachments/D4D0CAF2-42E7-403E-B71C-DBD26DA71897.png`, SHA256 e4309fcc9fdaf71a95cb8af622d3ee39fbb5bf3aa7c48334ccffa9d0464318ba
- testIdentificationSavePresentationPolish: `/private/tmp/narat-tester-care-20261119/docs/validation/automation/runs/q-4d459187e8c4399c2af33c31/attachments/0B505074-F175-43CA-BF38-825B59757456.png`, SHA256 db1ae82743a29c691760924b4326325b5dc3ebcfa2a6edb33bb3aa905c555052

История original M2c BLOCKED сохранена: Review140.200с FAIL из-за пустого manifestattachments,
QA0. Контроллер НЕ исправлял старый verdict. Новый4gate hardened,1positive+19negative validator
cases PASS; UIhelper написан реальным отдельным Developer51.995с. Owncontroller остановлен
exit130 в automation window ДОios/Xcode/Simulator: WAITING/checks,UNACCEPTED_STOPPED,
no_ios_check_started=true. Новый readonly кандидат полностью сравнивался с c590,all7source,
Developer0; это не fake DeveloperPASS. Прежние8UI/gate hashes неизменны.

История FAIL сохранена: firstSwift176.296с/88assertions ОДНОГО нового tabletest,
Dev2 исправил только новые initial/receipt/overview watermarks и усилил early-state assertions.
SecondSwift146.869с снова указал старые source-line positions; Dev3 semanticPASS116.934с
с ПУСТЫМ patch. Обычный следующий ios-gate на том же corrected source прошёл106.533с.
Controller не создавал новый DD, не делал reinstall/globalreset; точная infra-причина не установлена,
oldline mismatch — только indicator. Никакого приписанного Dev3 codefix/retroPASS.

Подготовлен wholeB read-only candidate_base80e, Developer0: полный UNION B1/B2/hooks/M1/M2,
все delta paths; старые care13/Today/readonly/PL,7 existing metadataUI,4 result render,
8 consent+ledgers/fullSwift149MCP/diff/highReviewQA. Новый metadata gate проверен syntax/help
и9 synthetic validation groups; actual7 ещё предстоит. Все прежние config routes/models900/
budgets/checks/stages сохранены; добавлен только metadata unitcheck к M2c config.
Далее delegate/currentOccurrences/strict early native isolation, ordinary SDK/System
unmasked G1pending→G2card NEWcoherentARMED→БЕЗSettings/Home→closed delivery/tap,
G3settings после delivery отдельно, затем final signed source. Старый ordinary56d/rawadapter
не переносится на новый код. T075/T077/T080/T098 открыты, technical only/externalphysical отложены,
PBX0/root user3 не тронуты; hard50/soft48/reset запрещён. Следующий шаг — wholeB checks/ReviewQA.
