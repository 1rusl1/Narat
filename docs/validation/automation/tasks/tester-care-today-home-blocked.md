# C2 Today home — BLOCKED, partial candidate

Run tester-care-today-home-20261120-01, base ae74b52. Five Swift source candidate
files: PlantsApp, PlantsAPIClient, GuestCatalogueView, TodayHomeView,
CollectionWireTests. Not accepted, no final QA/live. 4 added calendar fixtures,
368Swift/build/welcome/diff last PASS98.701s. Developer3/Reviewer2. Developer1
fullpatch798.568s; Developer2 hunkrepair224.442s; Developer3 semanticrepair151.571s.

Review1: displaced successful publication local reread was blocked by old
known invalidation; PL recommendation load/display unreachable. Repaired.
Review2 still FAIL: PL excludes loadCare/loadPendingRoutine/loadBasicCareState,
routineBusy and canonical revision invalidation. A previous EN pending care
must suppress dates in PL without triggering writes from read methods.

Next: new narrow Guest read-only PL guard repair + dedicated isolated rendered
UI regression; preserve existing write/firstaid/analysis locale guards. Then
fresh complete candidate_base checks/Review/QA against ae74b52, not acceptance
of only the small repair. Home-return event to existing coalescer belongs to C3
before Today readiness. Full Today/iPhone/OS reminders remain open.

Unaccepted source patch SHA256: 6098d8a1ae6d51e99937f7c9538ed3afebc691c07da3dce46c0ff3ccd4da1b9a
Ignored archive: docs/validation/automation/runs/today-C2-blocked-source.patch.
