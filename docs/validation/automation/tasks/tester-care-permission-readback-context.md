# Permission readback regression — tests only

Controller-authored candidate, Developer0; parent explicitly authorized exactly two tests after ordinary real-OS permission readback showed first notDetermined then authorized. No product/PBX/helper change. Base8e39238. Existing Fake.onAuthorization/onPermission model deterministic sequences only; these tests are not actual OS/delivery evidence. All previous423 Swift assertions remain unchanged.

Test1: after prompt first readND, Pass read authorized; same pass arms one occurrence while published worker.authorization remainsND. Explicit retry updates presentation, no second add/prompt. Test2: both postreadsND leads zero arms, requestingfalse, failedfalse/deferredfalse; later independent OS-state change causes no read/add without trigger; one retry arms original future occurrence, subsequent retry does not duplicate/prompt. This documents current behavior, does not repair permission UX.

Required fresh fullSwift425/build/welcome +diff, highReviewQA. MCP/UI/backend omitted because product unchanged. Same routing/budgets/900s. Freshusage before Review/QA; hard95/noreset, no new Developer. Settings/delegate/actual closed-app delivery and parent tasks stay open.

Initial preflight exit2 before checks/roles: criterion marked fixture but existing ios-tests evidence mode is local. Manifest corrected to local; fake-OS limitation unchanged, no test/product change.

Run01 BLOCKED actual ios-tests compile FAIL19.080s: new tests referenced private Scheduler.plan. After terminal child, controller replaced exactly two references with existing reminderPlan(input.state); no production visibility/helper change. New tests also avoid implementation-mirroring total authorization-read counts: retain programmed post-prompt sequence and captured no-trigger read baseline, plus observable identity/prompt/add/status results. All earlier423 assertions untouched. Fresh run02 required; no Developer call.

Accepted fresh run02 `8086558453d17a2c488660053cecfb180b9a4866`:425tests (422XCTest+3SwiftTesting)/build/welcome144.565s,diff0.024s,Review51.589s,QA79.868s allPASS. Developer0. Both newtests0.051/0.047s. No actual System scheduling/delivery assertion; earlier423 fileprefix byte-equal8e. BothND behavior is a documented limitation, no production repair. Actualusage93/7/noreset; next parent technical checkpoint.
