# Access HTTP — B2 wire proposal

2026-11-09. SQL005–010 accepted through `a367d0b`; HTTP below is a B2 proposal,
not an enabled/live endpoint. `collection-http.md` remains unchanged.

## Requests and identity

- `POST /installations/register`: verified Supabase guest/permanent JWT plus
  `X-Installation-Credential`; no client owner/time. An anonymous JWT is before
  user login. Registration associates **both anonymous and permanent** active
  owner IDs, preserves the credential hash/markers and is idempotent by hash.
- `POST /installations/bind`: permanent active JWT, the same credential header,
  JSON `{ "installation_id": "UUID" }`. Body UUID and hash must match atomically.
- `GET /analysis/access`: active guest/permanent JWT; credential required for
  guests and optional for permanent account-only access. It returns both modes.
  Query/body owner or time never overrides verified context/DB clock.

Service RPCs: `register_installation_access(p_credential_hash,p_owner_id)`,
`bind_installation_credential(p_installation_id,p_owner_id,p_credential_hash)`,
`get_analysis_access_snapshot(p_owner_id,p_installation_credential_hash)`.
Optional trusted p_now is for SQL tests; HTTP adapters never send it.

## Snapshot

Existing `is_guest`, `starter` and camelCase mode fields are retained. New
`owner_id` binds the response to the requesting account; `monthly` is **one
shared pool**, not a pool per mode. Canonical fixture examples are in
[fixtures/monthly-access.json](fixtures/monthly-access.json).

`monthly` has quota_kind (`free_monthly`/`paid_monthly` or null), registered_at,
period_start/end, limit, consumed, reserved, remaining, status. Status is `ready`,
`registration_required`, `history_unresolved`, or `not_applicable` (guest).
Ready remaining=max(0,limit-consumed-reserved); limit3 or100. Legacy unknown
counts/reset are null, never fabricated zero/3/100. Guest monthly fields are null.
Timestamps are opaque RFC3339 UTC instants; preserve fractional precision and
server boundaries, never recompute reset from local month/trial expiry.

Each mode contains mode, allowed, activeQuotaKind, remaining, limit,
inProgressJobId, nextResetAt and optional reason. Free uses its unused starter
first; paid uses only monthly, even if starter remains. nextResetAt is null for
starter and the registration period end for monthly. Mode remaining0 for an
unavailable monthly means no admission, not a known consumed count: display the
monthly null/status correctly. A starter may be allowed while legacy monthly is
unavailable. GET200 reports availability; it never creates a job/reservation.
`allowed` is quota permission, not a guarantee of provider uptime.

Reasons: starter_in_progress, starter_exhausted, free_monthly_exhausted,
paid_monthly_exhausted, quota_registration_required, quota_history_unresolved.
Only identification/diagnosis are produced. No calendar-month wait or Free1.

## Errors and current pipeline boundary

Use existing API error codes: 401 UNAUTHORIZED; 403 FORBIDDEN for verified owner/
credential rejection; 400 VALIDATION_ERROR for malformed input; 409 CONFLICT for
conflicting starter reservations; 503 INTERNAL_ERROR for unavailable or invalid
quota transport/data, localized EN/PL, retryable, without raw SQL details.
Future job admission exhaustion maps429 QUOTA_EXHAUSTED with remaining/reset.
GET exhaustion stays200 with denied mode, remaining0 and nextResetAt.

Unknown registration/history is a mode/monthly status in GET200 so independent
starter access is not hidden. A future denied monthly mutation returns503 with
safe details.reason; purchasing/restoring cannot repair history or refill quota.
This corrects the draft-only QUOTA_EXCEEDED/QUOTA_UNAVAILABLE names in the first
preparation: existing HTTP codes are preserved.

Production job/worker dispatch is not connected yet. B2 will return explicit
503 PROVIDER_UNAVAILABLE for unwired analysis jobs, never a fictitious202/result.
Real job/lease/result/provider transport is a separate T153/T031–034 package.
Fixtures/HTTP mocks are not live Auth/Supabase/Storage/provider/StoreKit proof.
Full T163 still waits clientT036 and required live/integration gates.
