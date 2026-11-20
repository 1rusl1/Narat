# Today C3b acceptance01 — BLOCKED

20 ноября2026. Exact candidate affff6b, HEAD69155c1, base4f4a348.
Read-only run tester-today-ui-acceptance-20261120-01: diff PASS0.025s,
149automation PASS46.597s, 374Swift (371XCTest+3)/build/welcome PASS173.761s.
Reviewer1 actual FAIL: TodayHomeView hides today.stale for readOnly +
revalidationRequired while calendar.status unavailable; model.hasError also
hides general status. Known obsolete schedule then looks like ordinary offline
cached schedule. Need explicit independent revalidation status and meaningful
regression of that combination. No MCP/old13/PL/new6/QA ran. No retroPASS.

Next narrow Developer View+Unit repair→checks/ReviewQA, then fresh whole
base4f4a acceptance of all5sourcefiles with old13+PL+new6/8ledgers. No root
merge or live/physical/reminders claims. Existing candidate remains unaccepted.
