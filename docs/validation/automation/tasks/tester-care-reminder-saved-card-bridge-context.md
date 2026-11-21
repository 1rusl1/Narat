# M2c: actual analysis SaveView bridge, native first-settle and explicit SavedCard read completion

Base 28ce549eb1ba2a9bd778304e845a39a994071ae3, M2b accepted as Model/ordinary-create foundation only. Its actual analysis manual SaveView callback and passive restore/retry latefullread gap were explicitly identified before wholeB; do not claim fullpostsave user path alreadyready.
Write sevenexistingfiles only: PreliminaryResultView / CatalogueSaveModel / CatalogueSaveView / GuestCatalogueView / ModelTests / ConnectionTests / WireTests. No PBX/newfiles, AI/provider/backend/deploy/schema/queue/sourcecalendar/PLwrite expansion. Target compact<=350-400lines incl meaningful tests, reuse existing fixtures. Files already EXIST: unifieddiff PROGRAMMATICALLY from actual lane bytes/difflib, never /dev/null/guessedhunks. Fixed models900/routes/budgets/hard50soft48/noreset.

Parent decisions override proposal ambiguity: read completion is permitted after the SPECIFIC actually awaited/joined SavedCard read success OR same-scope failure, including failure AFTER canonical publish; captured original SDK/modellease/UIlocale/ticket/currentread/!cancel. It is READ intent, NOT mutationACK and never inferred from .saved/.loaded. Root existing coalescer remains sole fetch; no canonical/advice/statusobserver/TTL/poll. Existing mutation settle remains separate and does NOT pass new read completion (no duplicates). JOIN actual detailsTask even though raw loadCard returnsbusy. No late secondfullread after native callback: pass includeManual policy beforefirst native model.save/settle.

Both actual ENmanual SaveView paths are PreliminaryResultView83/194; pass frozen original languageStore/currentLocale closure to BOTH, never constanttrue or recapturelocaleafterawait. Preserve EN-only manual controls, no new AI or diagnosis behavior. DEBUGstaging Root346-355 remains explicit old boundary, not new ordinary proof.
Native integration must prove manualphase ready/pending BEFOREadopt (.loadedskip) and atmostone details fullread +onecompletion, all original guestinput/body/SDKepoch/nativeAuth/cancelguards. SourcePrelim4existingUI tests onlyrender, not submit/watering. Their dedicated gate hash 053b5255722f5afad149e56c6efe966cbb5b87c49eb363527c949544c1a31069 syntax/help+9validation checks PASS, not AppUI proof; now actual4 must pass.

Newread regression uses SAME production helper and realStore/Repo, not test-only copiedalgorithm: restored.saved with no newPOST/UUID, start/join held canonicalfullread, independently earlyoverviewvalid, release success OR partialfailure AFTERgenrotation, callbackonceaftersettle (neverearlybusyreturn), bounded existing external reconcile/read -> finalfreshalignedcache+eligibleplan. Cover failure-beforecommit too where useful. Cancellation/disappear/ticket/sdkrefresh/ABA/localechange0callback; no passive status/witnesswithoutactualawait. Existing M2b heldtransport and helpers reuse. Newfixtures explicitpermanentJWT/monotonicwatermarks, oldassertions/defaults/guards notweakened.

After M2c actual fullSwift/build/welcome/149/diff/unchanged8+strictledgers/new4render/MCP/highReviewQA, wholeB remainsrequired old13care/Today/PL/7metadata and entireunionbase80e; thenrouting/SystemSDKclosedappdeliverytap/finalsigning. Ordinaryunmaskedchain: G1Systempending -> G2cardopenNEWcoherentgen+currentARMED -> NOSettings/Home -> background/terminate ->actualdelivery/tap, G3settings AFTERdelivery separate. Lawful receipted Settings rearm not itselfFAIL. No newlive claims/parentsclose; technical only/externalphysicaldeferred.

Below exact read-only grounded seam checklist (line numbers from M2b; adapt by rg, not guessed offsets):

## Реальный порядок чтения

- `ios/Plants/Features/Catalogue/CatalogueSaveModel.swift:392–410`: save делает typed operation; только accepted + ненулевой operation completion вызывает settleCard, затем finishCompletion. Уже `.saved` возвращается сразу (395), это не новое чтение.
- `:412–431`: private settleCard JOIN-ит существующий detailsTask; public loadCard при detailsTask != nil сразу возвращается (419). Поэтому await loadCard само по себе не доказывает завершение чтения.
- `:435–483`: performCardLoad → repo.catalogueCard → validateAuthority/тот же confirmation → details.loaded → optional local diagnosis conditions → local manual history → optional pending manual command. details.loaded (451) ещё не конец чтения. При optional/history failure durable `.saved` сохраняется, history.unavailable; cancellation инвалидирует facade.
- `ios/Plants/Data/Repositories/CollectionRepository.swift:701–744`: catalogueCard проверяет original lease, owner/envelope/exact durable journal, делает performFullRefresh(725), затем читает canonical plant и проверяет species/photo/taxon. Outbox drain/нового owner lease здесь нет.
- `:1120–1132`: manualWateringHistory читает уже синхронизированный локальный journal; второго HTTP нет.

## Все реальные SaveView callsites

`ios/Plants/Features/Catalogue/CatalogueSaveView.swift`:

| Путь | Точное место | Минимальное действие M2c |
|---|---|---|
| synchronize restore | 610–674, loadIfSaved(restored)657 | Отдельный scoped UI-read completion после действительно settled чтения; success И non-cancelled failure. Capture SDK/ticket/locale ДО первого await synchronize/restore, не recapture нового scope после чтения. |
| save fallback | save734–795; loadIfSaved(target)794 только done==nil | Не делать из отсутствующего ACK completion новый ACK. Если actual fallback UI-read разрешён current-locale proof, он использует отдельный read completion; nil из stale/missing locale не обходить. |
| native adopt | signIn837–888, adopt891–910 | SDK после native exchange намеренно новый: брать только verified validated adopted expected (892–902), сохранять original UI ticket/locale. `.loaded` skip910 не означает новое чтение и не публикует UI-read event. `.idle`→loadIfSaved — actual UI read. |
| loadIfSaved | 923–925 | Общий вход для трёх случаев выше; не определять завершение по одному `.saved` или card.loaded. |
| details/history retries | buttons492/562/584 → loadDetails927–935 → loadCard933 | Захватить original target identity/SDK/ticket/UI locale перед Task, выполнить JOIN actual detailsTask, guarded completion после settle success/failure. Не разрешать stale retry публиковать в новый scope. |
| advice only | saved result task471; advice retry525 | Не присоединять новый completion: recommendation GET не canonical fullrefresh. |
| manual record/retry/undo | 723–731; model210–211 | Сохранять typed mutation completion. Mutation settle НЕ передаёт read completion: один callback после settled operation, без дубля. |

`isCurrent`606–608 уже проверяет active/revision/cancellation/scope/connection.snapshot. Existing operation helper711–721 дополнительно проверяет captured locale. Новый read callback должен проверять эти же authority boundaries и именно исходный model/read attempt; не заменять на текущий SDK/locale после await. Ошибка optional чтения не становится успехом save, но даёт один разрешённый revalidation signal. Cancellation/logout/ABA/смена locale/закрытие View — 0 signals.

## Minimal separate read seam (proposal)

1. Отдельный transient UI-read completion, не переиспользовать accepted-operation флаг/finishCompletion514. Никакой durable queue/schema/event observer.
2. Он присоединяется к actual detailsTask и ждёт полностью settled task. Не создавать второй fullrefresh; когда JOIN-ит существующий task, не публиковать преждевременно. Для одного UI read intent — максимум один completion.
3. После settled success И current-scope failure — тот же existing `connection.publishExplicitCareRead(expected:locale:isLocaleCurrent:)` (`GuestCatalogueView.swift:130`), с captured SDK/UI locale/ticket. Этот метод сам требует permanent authClassification. Не публиковать из `.saved`/`.loaded` observer, canonical stream, advice GET или ACK receipt alone.
4. Не вешать read completion на mutation settle: existing save/manual callbacks уже публикуют один explicit intent после settle. Не превращать failure/cancel в ACK.

## Native first-settle manual policy

- `GuestCatalogueView.swift:677–680,754`: signInAndSave принимает только operation completion и вызывает model.save(completion:...), поэтому includeManualWateringActions остаётся default false (`SaveModel392`).
- `SaveView:219–220` содержит фактическую UI policy: EN + analysis identity/diagnosis/identification. Capture policy перед native Task837–847 и передать её через signInAndSave в ПЕРВЫЙ model.save; не пытаться исправлять после callback/adopt.
- При ненулевом completion native первый settle уже даёт `.loaded`; adopt910 пропустит повторный load. Даже если JOIN присоединяется к уже начатому detailsTask, его исходный includeManual флаг уже выбран. Отдельно доказать `.ready`/`.pending` manual phase при EN, а не только cardSummary.
- Native guards сохраняются: prepared guest SDK, exact immutable input/checkpoint/body, permitsNativeSignIn epoch, verified permanent SDK, cancellation/inputRetained. Никаких care writes из adopt/observer.

## Два Preliminary SaveView

- `ios/Plants/Features/Analysis/PreliminaryResultView.swift:83–93`: confirmed identification.
- `:194–202`: resolved diagnosis.
- Оба НЕ передают careReminderLocaleIsCurrent; default `{ false }` на SaveView193 отключает callback. `languageStore` реально @Bindable39–40, `isPolish`65.
- Передать closure, фиксирующий исходный `languageStore.currentLocale` и проверяющий ТОТ ЖЕ store/currentLocale при завершении, как existing ordinary catalogue path. Не constant true, не freshly recaptured locale после await. PL остаётся read-only для care writes.
- Другие constructors: ordinary `GuestCatalogueView.swift:3200–3203` уже передаёт locale guard. DEBUG staging resume `PlantsApp.swift:346–355` его не передаёт; это отдельный явный fixture/staging boundary, не обычный Preliminary путь. Не считать его автоматически покрытым M2c.

## Meaningful минимальные regression seams (без AI)

1. Extend `CollectionWireTests.testProductionSaveCompletionRepairsEarlyOverviewAfterLateCanonicalSettlement`14550: его CatalogueTransport.held уже удерживает actual details GET и есть early/final overview. Добавить отдельный restored-model/read retry вариант без command POST: callback отсутствует до release, после success/503 один, canonical generation aligned после final explicit read. Existing test пока доказывает operation completion, не UI read.
2. JOIN: при held detailsTask начать отдельный UI-read intent; callback не должен сработать от раннего busy-return loadCard; release → один callback, один fullrefresh. Optional history failure после loaded card тоже ждёт settle, не первую .loaded.
3. Existing restored canonical test `CollectionWireTests:3472` и staging restore7631: exact durable confirmation/operation восстановлены; read success/failure не создаёт POST/UUID и не меняет save truth. Уместный replay/no-writes seam.
4. Scope/locale fences: suspended read → SDK refresh/ABA, disappear/ticket replacement, locale EN→PL; late result даёт 0 callbacks и не revalidates новый owner. Tests используют scripted transport/real SDK helpers, без System/AI.
5. Native `CatalogueConnectionTests:1328` уже real SDK exchange + same operation/body + confirmed receipt; дополнить includeManual=true + completion actual card GET и assert manual phase `.ready`/`.pending` ДО adopt, один POST/один callback. Existing tests1452/1478/1504 переиспользуем для stale native/cancel guards. Diagnosis condition vectors2060 уже покрывают diagnosis/identification inputs без provider/AI requests.
6. Четыре `PlantsUITests:110–119`, helper181–208 — только presentation: existence/EN-PL labels/один species heading; Save НЕ нажимают, comment208 прямо исключает auth/save. Сохранить их как presentation evidence; они не доказывают full-save completion, read retry или native first-settle. Не выдавать новый core test за proof SwiftUI constructor wiring; два actual locale parameters нужны в code review + существующий presentation regression без расширения AI fixture.

Следующий шаг: controller отдельным M2c diff после M2b acceptance, затем meaningful core regressions + existing four presentation UI; реальные ordinary/System delivery gates остаются отдельными.
