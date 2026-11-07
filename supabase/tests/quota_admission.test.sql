-- supabase/tests/quota_admission.test.sql
-- T028: pgTAP tests for independent starter quotas, Free UTC=1 starting next month after first_starter_success_at,
-- paid_monthly=100 from first verified trial/access, OR/earliest bind, starter_in_progress, non-billable release,
-- job across month/purchase/expiry, and 20-request admission cap on the last attempt.

BEGIN;
SELECT plan(18);

-- Setup KB release
INSERT INTO public.kb_releases (
  id, version, status, manifest_sha256, schema_version, published_at
) VALUES (
  '00000000-0000-0000-0000-000000000100', '2026.11.01', 'published',
  repeat('b', 64), '3.0', TIMESTAMPTZ '2026-11-01T00:00:00Z'
);

-- Setup guest installation
INSERT INTO public.installation_access (
  id, credential_hash
) VALUES (
  '00000000-0000-0000-0000-000000000101', repeat('c', 64)
);

-- 1. Starter diagnosis is admitted and blocks a second diagnosis while starter_in_progress
SELECT is(
  (public.admit_analysis_quota(
    'diagnosis',
    NULL,
    '00000000-0000-0000-0000-000000000101',
    '00000000-0000-0000-0000-000000000201',
    TIMESTAMPTZ '2026-11-05T10:00:00Z'
  )->>'quota_kind'),
  'starter_diagnosis',
  'Guest diagnosis reserves starter_diagnosis'
);

SELECT is(
  (public.admit_analysis_quota(
    'diagnosis',
    NULL,
    '00000000-0000-0000-0000-000000000101',
    '00000000-0000-0000-0000-000000000202',
    TIMESTAMPTZ '2026-11-05T10:00:05Z'
  )->>'reason'),
  'starter_in_progress',
  'Concurrent guest diagnosis returns starter_in_progress'
);

-- 2. Starter identification is completely independent of starter diagnosis
SELECT is(
  (public.admit_analysis_quota(
    'identification',
    NULL,
    '00000000-0000-0000-0000-000000000101',
    '00000000-0000-0000-0000-000000000203',
    TIMESTAMPTZ '2026-11-05T10:01:00Z'
  )->>'quota_kind'),
  'starter_identification',
  'Guest identification is independent and reserves starter_identification while diagnosis is in progress'
);

-- Insert jobs for settlement testing
INSERT INTO public.analysis_jobs (
  id, installation_id, kb_release_id, mode, status, quota_kind, quota_state
) VALUES
(
  '00000000-0000-0000-0000-000000000201',
  '00000000-0000-0000-0000-000000000101',
  '00000000-0000-0000-0000-000000000100',
  'diagnosis', 'running', 'starter_diagnosis', 'reserved'
),
(
  '00000000-0000-0000-0000-000000000203',
  '00000000-0000-0000-0000-000000000101',
  '00000000-0000-0000-0000-000000000100',
  'identification', 'running', 'starter_identification', 'reserved'
);

-- 3. Unsuitable / out-of-scope photo releases starter_identification without consuming it
SELECT is(
  (public.finalize_analysis_quota(
    '00000000-0000-0000-0000-000000000203',
    'succeeded',
    TRUE,
    TIMESTAMPTZ '2026-11-05T10:01:15Z'
  )->>'quota_state'),
  'released',
  'Unsuitable/out-of-scope result releases starter_identification without consuming'
);

SELECT is(
  (SELECT starter_identification_consumed FROM public.installation_access WHERE id = '00000000-0000-0000-0000-000000000101'),
  FALSE,
  'starter_identification_consumed remains FALSE after released job'
);

-- 4. Successful diagnosis consumes starter_diagnosis and records first_starter_success_at
SELECT is(
  (public.finalize_analysis_quota(
    '00000000-0000-0000-0000-000000000201',
    'succeeded',
    FALSE,
    TIMESTAMPTZ '2026-11-05T10:02:00Z'
  )->>'quota_state'),
  'consumed',
  'Valid diagnosis consumes starter_diagnosis'
);

-- Exactly-once idempotency on finalize_analysis_quota
SELECT is(
  (public.finalize_analysis_quota(
    '00000000-0000-0000-0000-000000000201',
    'failed',
    FALSE,
    TIMESTAMPTZ '2026-11-05T10:03:00Z'
  )->>'already_finalized')::BOOLEAN,
  TRUE,
  'Repeated finalize_analysis_quota is a no-op'
);

-- 5. Bind installation to authenticated owner merges OR flags and earliest first_starter_success_at
INSERT INTO auth.users (id, email)
VALUES ('00000000-0000-0000-0000-000000000102', 'quota-user@example.com');

INSERT INTO public.profiles (
  id, account_state, anonymous, preferred_locale,
  starter_identification_consumed, starter_diagnosis_consumed, first_starter_success_at
) VALUES (
  '00000000-0000-0000-0000-000000000102', 'active', FALSE, 'pl',
  TRUE, FALSE, TIMESTAMPTZ '2026-11-10T12:00:00Z'
);

SELECT public.bind_installation_to_owner(
  '00000000-0000-0000-0000-000000000101',
  '00000000-0000-0000-0000-000000000102',
  TIMESTAMPTZ '2026-11-10T12:05:00Z'
);

SELECT is(
  (SELECT starter_identification_consumed AND starter_diagnosis_consumed
   FROM public.profiles WHERE id = '00000000-0000-0000-0000-000000000102'),
  TRUE,
  'bind_installation_to_owner merges both starter flags via OR'
);

SELECT is(
  (SELECT first_starter_success_at FROM public.profiles WHERE id = '00000000-0000-0000-0000-000000000102'),
  TIMESTAMPTZ '2026-11-05T10:02:00Z',
  'bind_installation_to_owner preserves the earliest first_starter_success_at'
);

-- 6. Free monthly = 1 is NOT available in the same UTC month as first_starter_success_at (Nov 2026)
SELECT is(
  (public.admit_analysis_quota(
    'diagnosis',
    '00000000-0000-0000-0000-000000000102',
    '00000000-0000-0000-0000-000000000101',
    '00000000-0000-0000-0000-000000000204',
    TIMESTAMPTZ '2026-11-25T15:00:00Z'
  )->>'reason'),
  'free_monthly_starts_next_utc_month',
  'free_monthly is blocked during the UTC month of first_starter_success_at'
);

-- 7. In December 2026 (next UTC month), 20 requests for the single free_monthly slot admit exactly 1
CREATE TEMP TABLE free_admission_results AS
SELECT
  i AS attempt_no,
  (public.admit_analysis_quota(
    'diagnosis',
    '00000000-0000-0000-0000-000000000102',
    '00000000-0000-0000-0000-000000000101',
    ('00000000-0000-0000-0000-0000000003' || lpad(i::TEXT, 2, '0'))::UUID,
    TIMESTAMPTZ '2026-12-01T00:01:00Z'
  )->>'admitted')::BOOLEAN AS admitted
FROM generate_series(1, 20) AS i;

SELECT is(
  (SELECT COUNT(*)::INT FROM free_admission_results WHERE admitted = TRUE),
  1,
  'Out of 20 attempts for the last free_monthly=1 slot, exactly 1 is admitted'
);

SELECT is(
  (SELECT COUNT(*)::INT FROM free_admission_results WHERE admitted = FALSE),
  19,
  'The remaining 19 attempts for free_monthly=1 are rejected without oversubscription'
);

-- 8. Paid monthly = 100 anchored at first verified trial access, no reset on trial -> paid, and 20 attempts on 100th slot
INSERT INTO public.entitlements (
  owner_id, product_id, state, offer_kind, trial_end_at, valid_until, auto_renew_enabled, verified_at
) VALUES (
  '00000000-0000-0000-0000-000000000102',
  'app.narat.plants.pro.yearly',
  'active',
  'trial',
  TIMESTAMPTZ '2026-12-12T10:00:00Z',
  TIMESTAMPTZ '2026-12-12T10:00:00Z',
  TRUE,
  TIMESTAMPTZ '2026-12-05T10:00:00Z'
);

UPDATE public.profiles
SET quota_anchor_at = TIMESTAMPTZ '2026-12-05T10:00:00Z'
WHERE id = '00000000-0000-0000-0000-000000000102';

-- Admit first paid_monthly job during trial
SELECT is(
  (public.admit_analysis_quota(
    'follow_up',
    '00000000-0000-0000-0000-000000000102',
    '00000000-0000-0000-0000-000000000101',
    '00000000-0000-0000-0000-000000000401',
    TIMESTAMPTZ '2026-12-06T10:00:00Z'
  )->>'quota_kind'),
  'paid_monthly',
  'follow_up is admitted under paid_monthly during verified trial'
);

-- Simulate 99 consumed scans in trial, then transition trial -> paid on 2026-12-12
UPDATE public.monthly_quotas
SET consumed_count = 99,
    reserved_count = 0
WHERE owner_id = '00000000-0000-0000-0000-000000000102'
  AND quota_kind = 'paid_monthly';

UPDATE public.entitlements
SET offer_kind = 'paid',
    valid_until = TIMESTAMPTZ '2027-12-12T10:00:00Z',
    verified_at = TIMESTAMPTZ '2026-12-12T10:00:00Z'
WHERE owner_id = '00000000-0000-0000-0000-000000000102';

-- Run 20 requests for the 100th paid_monthly slot after trial -> paid transition (same anchor window Dec 5 .. Jan 5)
CREATE TEMP TABLE paid_admission_results AS
SELECT
  i AS attempt_no,
  public.admit_analysis_quota(
    'diagnosis',
    '00000000-0000-0000-0000-000000000102',
    '00000000-0000-0000-0000-000000000101',
    ('00000000-0000-0000-0000-0000000005' || lpad(i::TEXT, 2, '0'))::UUID,
    TIMESTAMPTZ '2026-12-15T10:00:00Z'
  ) AS payload
FROM generate_series(1, 20) AS i;

SELECT is(
  (SELECT COUNT(*)::INT FROM paid_admission_results WHERE (payload->>'admitted')::BOOLEAN = TRUE),
  1,
  'Trial->paid transition does not reset the 100-scan window; exactly 1 of 20 requests gets the 100th slot'
);

SELECT is(
  (SELECT COUNT(*)::INT FROM paid_admission_results WHERE payload->>'reason' = 'paid_monthly_exhausted'),
  19,
  'The other 19 requests fail with paid_monthly_exhausted and never fall back to free_monthly or starter'
);

-- 9. Job reserved before subscription expiry settles against its original monthly_quota_id after expiry
INSERT INTO public.analysis_jobs (
  id, owner_id, installation_id, kb_release_id, mode, status, quota_kind, quota_state, monthly_quota_id
) VALUES (
  '00000000-0000-0000-0000-000000000501',
  '00000000-0000-0000-0000-000000000102',
  '00000000-0000-0000-0000-000000000101',
  '00000000-0000-0000-0000-000000000100',
  'diagnosis', 'running', 'paid_monthly', 'reserved',
  (SELECT id FROM public.monthly_quotas WHERE owner_id = '00000000-0000-0000-0000-000000000102' AND quota_kind = 'paid_monthly')
);

UPDATE public.entitlements
SET state = 'expired',
    valid_until = TIMESTAMPTZ '2026-12-15T10:01:00Z'
WHERE owner_id = '00000000-0000-0000-0000-000000000102';

SELECT is(
  (public.finalize_analysis_quota(
    '00000000-0000-0000-0000-000000000501',
    'succeeded',
    FALSE,
    TIMESTAMPTZ '2026-12-15T10:02:00Z'
  )->>'quota_state'),
  'consumed',
  'In-flight job reserved under paid_monthly settles against its reserved row even after subscription expires'
);

SELECT is(
  (SELECT consumed_count FROM public.monthly_quotas WHERE owner_id = '00000000-0000-0000-0000-000000000102' AND quota_kind = 'paid_monthly'),
  100,
  'paid_monthly consumed_count reaches 100 after in-flight job completes'
);

SELECT is(
  (SELECT reserved_count FROM public.monthly_quotas WHERE owner_id = '00000000-0000-0000-0000-000000000102' AND quota_kind = 'paid_monthly'),
  0,
  'paid_monthly reserved_count returns to 0 after settlement'
);

SELECT * FROM finish();
ROLLBACK;
