# Root external-refresh lost-trigger — static confirmed, unaccepted

App refreshToday waits a captured todayLocalRead L1. During its await a durable
canonical/outbox signal cancels L1 and sets L2/fenced/needsLocalRead. L1's end
resumes external pass; guard returns outcome before overview. L2 only rereads
local state, so foreground/reconnect/Retry was lost. Post-publication recovery
cannot fix this preHTTP interleaving. Parent/sourceagent independently confirmed.
No implementation or runtime proof is claimed by this static report.

Narrow Developer repair: event-driven await latest existing localtask/revision
under original scope, then exactly one already-authorized bounded overview.
No polling/newHTTP from canonical events/reconcile replay/artificial busy.
Cancellation/error/owner/locale replacement exits safely. Deterministic barriers
prove replacement L1->L2 never drops external request; canonical-only after pass
causes zero extra remote calls. Full C2 source acceptance remains separate.
