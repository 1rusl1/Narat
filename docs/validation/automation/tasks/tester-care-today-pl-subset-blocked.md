# PL read subset — BLOCKED; mechanical selector candidate

Run tester-care-today-pl-invalidation-20261120-01, base0fdad76. Three files:
GuestCatalogueView, CatalogueUIFixtures, CatalogueSaveUITests. Developer3;
Reviewer1 found fingerprint/cancellation foreground gap, Developer3 fixed
previous != fingerprint || refreshOnForeground and invalidates advice before
publishing fingerprint. Reviewer2 CLI routing discovery403 returned no answer,
not semantic failure; bounded resume Reviewer3 PASS. Source unchanged on resume.

Actual final tests:368Swift/build/welcome/diff PASS139.644s; MCP PASS35.648s.
PL named UI FAIL62.13s BEFORE first care intent: exact Source ID exposed by
SwiftUI as Button, test queried app.links and XCTest reported automation type
mismatch. No QA, no subset acceptance. Original FAIL report retained at
runs/q-74aff7f015d7427cfdc67490/summary.json and original orchestrator state.

Controller candidate fixes ONLY the two source queries in the new UI test:
exact same identifier via descendants(.any).firstMatch, including negative
next.source assertion. Date/source/operation/body/commit assertions unchanged.
No production change for selector repair. Fresh FULL candidate_base acceptance
of entire C2 from ae74b52 follows with actual old13+PL, Swift/MCP/automation,
high Review/QA. Existing C2 and PL subset BLOCKED remain recorded.
