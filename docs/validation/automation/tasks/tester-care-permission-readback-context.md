# Permission readback regression — tests only

Controller-authored candidate, Developer0; parent explicitly authorized exactly two tests after ordinary real-OS permission readback showed first notDetermined then authorized. No product/PBX/helper change. Base8e39238. Existing Fake.onAuthorization/onPermission model deterministic sequences only; these tests are not actual OS/delivery evidence. All previous423 Swift assertions remain unchanged.

Test1: after prompt first readND, Pass read authorized; same pass arms one occurrence while published worker.authorization remainsND. Explicit retry updates presentation, no second add/prompt. Test2: both postreadsND leads zero arms, requestingfalse, failedfalse/deferredfalse; later independent OS-state change causes no read/add without trigger; one retry arms original future occurrence, subsequent retry does not duplicate/prompt. This documents current behavior, does not repair permission UX.

Required fresh fullSwift425/build/welcome +diff, highReviewQA. MCP/UI/backend omitted because product unchanged. Same routing/budgets/900s. Freshusage before Review/QA; hard95/noreset, no new Developer. Settings/delegate/actual closed-app delivery and parent tasks stay open.

Initial preflight exit2 before checks/roles: criterion marked fixture but existing ios-tests evidence mode is local. Manifest corrected to local; fake-OS limitation unchanged, no test/product change.
