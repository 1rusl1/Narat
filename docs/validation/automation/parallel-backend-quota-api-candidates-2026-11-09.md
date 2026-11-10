# B2 SQL11/12 — local candidates, independent acceptance pending

Base accepted runtime a367d0b; B1 summary bc6a879. Preparation/candidate011 5c0d32d
published in origin/codex/plants-backend. SQL12 is a new controller candidate.
Neither011 nor012 has independent Developer/Reviewer/QA acceptance yet.

- 011_installation_access_api.sql factors accepted010 normalization into a private
  helper, adds active anonymous/permanent hash registration and atomic UUID+hash
  credential proof for permanent bind. No migration-time data changes. Existing
  public bind policy/signature retained. 36new real-RPC pgTAP assertions.
- 012_analysis_access_snapshot.sql exposes one server-owned monthly pool plus two
  mode summaries. It uses actual registration/paid-access/window/ledger rules and
  the accepted008 history eligibility predicate, including old nonoverlap residue
  and delayed canonical reservations. Unknown legacy date/counts remain NULL;
  independent unused Free starter may still be allowed. GET never creates jobs
  or reserves/debits usage. 55new real-RPC pgTAP assertions compare with008.

Controller checks (synthetic identities/private PostgreSQL17 only):

- `python3 tools/automation/parallel_backend_quota_gate.py --bind --installations --access`
  PASS clean/upgrade **475pgTAP each** (55+49+78+89+113+36+55),12UTC cases,
  all preexisting public rows byte-equal across upgrade. Six rounds each start
  with99actual admit+finalize calls then20real simultaneously observed waiting
  connections, last-slot/replay/failure/exactly-once PASS.
  Evidence `/tmp/narat-b2-access-candidate-v3.log`.
- Initial snapshot fixture runs failed on an invalid monthly trial product and
  trial state. Corrected fixture: yearly product, state active, offer_kind trial.
  No product constraint was weakened. Earlier logs retained at
  `/tmp/narat-b2-access-candidate{,-v2}.log`.
- Separate `--anchors --legacy-guard --cap-regression` PASS clean/upgrade55+131
  pgTAP and4real T161 owner-lock races, original rows retained.
  Evidence `/tmp/narat-b2-candidate-cap.log`. Old shared t161 runner unchanged.
- Deno336/0failed, deno-check PASS. `/tmp/narat-b2-candidate-{deno,typecheck}.log`.
- Automation115 tests/OK (37.811s), `/tmp/narat-b2-candidate-automation.log`.

Bounded manifest `tools/automation/tasks.parallel-backend-quota-api.json`:011 then012.
Validate2/developer context/diff-check PASS. Protected controller gate adds
--installations/--access and requires matching migrations/tests; no skipped test
or baseline fallback. Branch config SHA256
`7b9b9b38d11cdc0227599a9b0b301c25472040280803cbc24394fd40c234e904`.
Only two check definitions added; routing/retry/budgets unchanged; publish only
origin/codex/plants-backend. Default main config not used.

Run06 **did not start**: automatic approval rejected executing the orchestrator,
reporting missing explicit trusted authorization for code transfer to configured
model providers and automatic changes/publication. No state/answer/acceptance
was fabricated. Inter-chat report to A was separately rejected for missing trusted
authorization to share internal technical details. User permissions were requested
asynchronously; no workaround/retry. Both are still pending at this checkpoint.

Next after authorization: new run-id parallel-backend-quota-api-sql-20261109-07,
explicit branch --config, same bounded manifest; independent acceptance of full
materialized011 and012. Then production access/installations HTTP adapters,
strict canonical DTO/ENPL mappings and protected real-client transport fixtures;
confirm additive wire with A. Existing TS forecast still old/injection-only and
is not operationally accepted. No live Auth/Supabase/Storage/provider/StoreKit,
no B Swift/Simulator, no worker/job dispatch or fullT163/T036 closure. Unknown
legacy registration monthly blocking is explicitly approved by user.
