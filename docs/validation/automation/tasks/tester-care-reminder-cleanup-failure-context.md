# R2b2 remaining cleanup audit — unaccepted whole worker

Whole run tester-care-reminder-worker-union-20261120-02 BLOCKED Reviewer1 semantic FAIL84.327s. Actual Swift410/build/welcome PASS114.913, automation149 PASS49.153, diff PASS. NoQA/MCP. Original union01 CoreSimulator Dead/temp XCTest bundle load FAIL beforetests preserved; ownapp reinstalled underresourcelease, identicalcode02 passedtests. No globalreset/dataerase/sourcefix.

Actual Reviewer finding:

[P1] ios/Plants/Integrations/Notifications/CareReminderScheduler.swift:127–146: cleanup сохраняет blockers только при input.state != nil. При известном владельце, state=nil и optedIn=false собственный canonical raw ID с route=nil и без receipt удаляется напрямую, без blockIdentifier. Последующий update с восстановленным состоянием и optedIn=true видит пустой ledger/inventory и снова вызывает add для того же ID. Сохраняйте owner-bound blocker до удаления также при неизвестной projection, без чтения чужого ledger и выдуманных дат. Добавьте регрессию: unknown-state opt-out → cleanup → disk restart → восстановление eligibility → ноль add; отказ сохранения должен предотвращать удаление.

Independent parent source audit (not yet tested): Pass.run beginCareReminderReceipts precedes inventory/foreigncleanup. FreshknownB/state=nil +corruptB/emptyB savefail abortsbefore removingforeignA. Worker.cleanup throwson cancellationreconcile.failed before rawfallbackOSremove, so explicitoptout/latchedownerchange mayleaveknownalerts evenwithvalidSDKscope. Safe foreign removal mustnotrequirecurrentowner metadata; neverreadforeignledger orcreatefalsecancelproof.

Boundary: normal untrustedowncanonical identity (including nilprojectionoptout currentvalidlease) needsdurableblockedIdentifier BEFOREremove; storagefail retainsambiguousownrequest+failure. Foreign strictIDs and trusted/known explicitprivacycleanup canremoveowncareprefix independentlyofmetadatafailure; diagnosticsremainfailed andoldpersistedarmed/prepared are notrewrittenas cancelled. LatermissingOS normalizesuncertain. Corruptbytes untouched. No newpersistence/framework orOS+SQLatomicity claim.

Both findings must be evaluated together. Exact source changes through Developer only, then realgates/ReviewQA andfresh wholeunion fromdfe beforeRoot. Runtime/UI/phone/actualOS remainpending, parentsopen.


Clarification before fresh run02: valid OS route + NO persisted Entry is also UNKNOWN. It must recordUnknown(terminal) before nilprojectionoptout removal; routeNil canonical records blockedIdentifier. Savefailure protects both ambiguous own variants. Only actually known persisted receipt or strict foreign-owner identity grants metadata-independent privacycleanup. Explicit true logout can remove ownnamespace without invalid SDK ledger reads, but no falseproof/addauthority.

cleanup-failure run01 interrupted deliberately at read stage when this clarification arrived after prepare/start. Owned controller SIGINT triggered normal child-group cleanup; process exit130/WAITING, noappliedsource/QA/PASS. Saved raw/process evidence retained; fresh run02 has corrected contract, same models900/budgets. No source rewrite was requested by unfinished call.
