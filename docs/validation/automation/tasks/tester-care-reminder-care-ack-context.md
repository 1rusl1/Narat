# Dataflow B: positive care ACK wakes existing scoped overview read

Base 20ec8baace2581c55a3c153da7e89e70d8eaf19d (set controller after A acceptance), A source is actual current lane. Original 445 Swift tests/assertions must remain unchanged. No PBX/new source file.

## Grounded gap and tiny seam
Opening collection full-refresh invalidates derived overview. A wires explicit settings/hour/Retry; a confirmed care action while original card remains open still needs one authorized bounded Root read, so new next-date plan can arm before dismiss. Canonical/outbox/idle streams remain cache-only. Reuse A's publishExplicitCareRead with original expected SDK epoch/current locale; card receives captured locale-current guard from existing collection/Root. Old legacy fixtures must not get new overview HTTP, dedicated matched family retains one fake Core.

Positive typed completion seams in Guest:
- retryWateringRecord .confirmed (existing exact canonical identity); explicit recoverUnconfirmedWatering only positively confirmed original fact, not rejection/negative fullSync. Never emit inside passive loadHistory.
- completeRoutine/undoRoutine typed .confirmed (existing exact receipt+canonical validators).
- writeFirstAid typed .confirmed for record/undo/observation/photo; not discard/pending/rejected. Validate original scope after awaited outcome before event.
- refreshAdvice typed .confirmed.
- enableBasicCare only actual exact accepted receipt, not old enabledAt+queue empty.
- retryCorrection manual correction/undo currently repository returns Void/generic drain. correction==ready/queue disappearance is NOT proof: undo terminal rejection dequeues. Must derive a small typed positive result from exact target operation accepted by SAME ordered drain, after receipt/canonical checks. Keep legacy public Int counters/API compatibility, order/UUID/gates/CAS untouched.

A compact possible design (not mandatory): private transient per-pass report {count, trackedExactOperationAccepted}; existing Int wrappers retain count, new internal exact-operation report retains generic ordered drain. No actor-global receipt cache, no durable journal/schema/queue. Do not shortcut by switching generic retry to onlyOperation flushPlantCommand: it filters unrelated predecessors before dispatch and would change ordering. A positive flag arises ONLY actual target receipt+canonical validation+finish, never unrelated commit/count>0, empty snapshot, busy, rejection, pending, failed canonical pull. Existing profile branch/count/early returns preserved. No need classify no-proof as rejected. Use @discardableResult if narrow repository return extended so old callers behave unchanged.

Emit event as soon as exact outcome positively confirmed and original SDK/locale still current, BEFORE subsequent optional history/advice read that may fail. A typed ACK followed by view-history failure can authorize recovery read. Cancellation/stale SDK/locale/pending/rejected/unconfirmed never emit. No autonomous retry, no new domain command, no change to action confirmation copy or guards. On automatic Root care reconciliation, existing Root already owns final overview read, do not emit a second event from passive projection.

## Meaningful tests
Append compact groups in existing CollectionWireTests reusing current transports/seed helpers (correction test5902, undo5990, owner/ABA6220, marker9030+). Prove exact accepted correction/undo versus unrelated accepted predecessor, terminal undo rejection/dequeue not confirmed, pending/lost ACK exact UUID/body replay, accepted receipt then canonical-read failure not confirmed. Include original lease/owner/ABA and basic-enable preexisting enabledAt/rejected action cannot yield confirmed. Preserve every existing445 assertion and guards. ~250-350 total new/changed lines, split only on actual timeout.

Write ONLY GuestCatalogueView.swift, CollectionRepository.swift, SyncEngine.swift, CollectionWireTests.swift. Existing files/scaffolds ALREADY EXIST; generate unified diff PROGRAMMATICALLY from actual lane file bytes using difflib/equivalent, no /dev/null or guessed @@/header normalization.

## Acceptance boundary
FullSwift/build/welcome,149automation,MCP,diff,highReviewQA. Actual rendered scenario remains next: strict dedicated hour mode allows ONLY typed/idempotent profile.update, all other commands rejected/carefacts0; named8 consent UI including in-sheet settings-open/hourACK fresh plan. Final wholeB from80eaa98 runs allold13care/Today6+8readOnly/PL plusnew8UI/highReviewQA. Parent ordinary System/Scheduler/SDK live then tests fresh cache+ARMED while card still open and closed-app delivery/tap. Do not claim those from this unit slice. Root parentcheckboxes remain open, technical only, no external distribution/recommendations/purchases/backend/System changes. Same models/routes900/budgets; current usage <50 (controller reads fresh), soft48/noreset.
