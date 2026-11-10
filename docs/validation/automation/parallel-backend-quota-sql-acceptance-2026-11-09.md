# T163 / B1 SQL — accepted bounded server package

Accepted/pushed through `a367d0b`, branch codex/plants-backend. No deploy, no
product parent closure. Existing collection-http wire/Swift unchanged by B.

| Migration | Accepted SHA | Scope |
| --- | --- | --- |
| 005_registration_quotas |21ee7a7|Permanent registration anchor/UTC windows; legacy NULL until evidence|
| 006_registration_ledger |e6b1f7c|Shared usage, idempotent known-job import, residual uncertainty|
| 007_registration_state_guard |a04794c|Unresolved permanent cannot revert to guest/reanchor|
| 008_quota_reservation |141d548|Free3/paid100, starters, atomic owner lock/replay|
| 009_quota_settlement |42ed071|Exactly-once original-period consume/release, old leases|
| 010_installation_quota_bind |a367d0b|OR markers, credential-owner linkage, live/terminal pointers|

Real local PostgreSQL17/pgTAP, private temp clusters/sockets, synthetic identities:

- `python3 tools/automation/parallel_backend_quota_gate.py --bind` PASS clean and
  seeded upgrade: **384 pgTAP each** (55anchor+49ledger+78reserve+89finalize+113bind),
  12UTC boundary/leap/TZ cases each; all preexisting public rows byte-equal across
  forward upgrade. Six rounds observe20 separate psql connections waiting on a
  held owner lock before release. Each round starts with99 actual RPC admit+
  finalize calls on synthetic jobs; distinct IDs/same-job replay/technical failure,
  one last-slot ledger row and terminal settlement/replay exactly once.
- `python3 tools/automation/parallel_backend_quota_gate.py --anchors --legacy-guard --cap-regression`
  PASS clean/upgrade55+131pgTAP each, four real T161 owner-lock races. Shared old
  t161 runner remains unchanged; its strict table-key equality FAIL on added
  tables is documented separately and never called PASS.
- Deno336 fixtures, deno-check,115automation fixtures, diff-check PASS.
- Independent Developer/Reviewer/QA: finalize1/1/1; binding3/2/1. Binding Review
  found premature consumption from reserved+succeeded before a non-billable
  settlement. Fixed: only quota_state consumed confirms expense; reserved success
  retains blocking pointer until009 decides. New regression covers nonbillable
  release/rebind/retry. One repair returned add-file patch for existing candidate,
  safely rejected; final patch and113tests passed. No source state rewritten.

Reports: `docs/validation/automation/tasks/parallel-backend-t163-{finalize-only,bind-only}.md`.
Final raw evidence: ignored run05 directory
`docs/validation/automation/runs/orchestrator-parallel-backend-quota-sql-20261109-05/parallel-backend-t163-bind-only/check-12-parallel-backend-quota-bind/stdout.log`.
Per-check argv/status/elapsed and role/publish data in state.json/task reports.
Old timeout01/02/04, malformed fingerprint03 and its exact recovery remain recorded.
No token savings/usage scope claimed.

Limits: no live Auth/Supabase/Storage/provider/StoreKit; no B Swift/Simulator run.
User approved unknown legacy registration monthly fail-closed until verified Auth
import. Unknown current historical spend also blocks; original counters/leases/
receipts remain. No live source for remediation imported. Positive guest transfer/
media (T166), real job/worker pipeline (T153), API B2 and clientT036 are separate.
Current TS AnalysisAccess still has old local forecast and access/installations
adapters are injection-only. This package does not make them operational.

Next: separate bounded B2 manifest/gates, real authoritative SQL access snapshot
and credential RPCs/production HTTP adapters, canonical EN/PL mappings/fixtures.
[Wire proposal](../../../specs/001-plants-ios-mvp/contracts/monthly-access-http.md).
