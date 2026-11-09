-- Current schema, real triggers/RPCs, synthetic data only. The controller runs
-- this after clean installation and after its seeded forward-upgrade snapshot.
BEGIN;
SELECT plan(54);

CREATE TEMP TABLE anchor_import_target AS
SELECT p.id, to_jsonb(p) AS profile_before, a.registered_at AS original_at,
       a.source AS original_source,
       COALESCE(a.registered_at, '2026-01-31 10:20Z'::timestamptz) AS target_at
FROM public.profiles p JOIN public.account_quota_anchors a ON a.owner_id = p.id
WHERE NOT p.anonymous AND p.account_state = 'active'
ORDER BY a.registered_at NULLS FIRST, p.id LIMIT 1;
SELECT is((SELECT count(*) FROM anchor_import_target), 1::bigint,
          'Controller supplied an existing permanent owner');
SELECT ok(NOT EXISTS (
    SELECT 1 FROM public.account_quota_anchors
    WHERE source = 'unresolved' AND registered_at IS NOT NULL
), 'Seeded legacy anchors stay explicitly unresolved without evidence');
SELECT ok(NOT EXISTS (
    SELECT 1 FROM public.profiles p LEFT JOIN public.account_quota_anchors a ON a.owner_id = p.id
    WHERE a.owner_id IS NULL OR (p.anonymous AND a.registered_at IS NOT NULL)
), 'Every existing owner has an anchor row; guests have no monthly anchor');
SELECT throws_ok(
    format('DELETE FROM public.account_quota_anchors WHERE owner_id = %L', (SELECT id FROM anchor_import_target)),
    '55000', 'REGISTRATION_ANCHOR_IMMUTABLE', 'Even unresolved legacy rows cannot be deleted');
SELECT lives_ok(
    format('SELECT public.set_registration_quota_anchor(%L,%L,%L)',
           id, target_at, 'fixture verified permanent registration'),
    'Verified import or same-date retry succeeds'
) FROM anchor_import_target;
SELECT is(
    (SELECT registered_at FROM public.account_quota_anchors WHERE owner_id = (SELECT id FROM anchor_import_target)),
    (SELECT target_at FROM anchor_import_target), 'Verified date is stored exactly');
SELECT is(
    (SELECT source FROM public.account_quota_anchors WHERE owner_id = (SELECT id FROM anchor_import_target)),
    (SELECT CASE WHEN original_at IS NULL THEN 'fixture verified permanent registration'
                 ELSE original_source END FROM anchor_import_target),
    'First evidence is retained, including on same-date retry');
SELECT is(
    (SELECT to_jsonb(p) FROM public.profiles p WHERE id = (SELECT id FROM anchor_import_target)),
    (SELECT profile_before FROM anchor_import_target),
    'Import never changes the profile or its sync watermark');

INSERT INTO public.profiles(id, anonymous, app_account_token, created_at, quota_anchor_at)
VALUES ('16310000-0000-4000-8000-000000000001', false,
        '16310000-0000-4000-8000-000000000011', '2026-01-31 10:20Z', '2025-07-15 12:00Z'),
       ('16310000-0000-4000-8000-000000000002', true, NULL, '2020-01-01 00:00Z', NULL),
       ('16310000-0000-4000-8000-000000000003', false, NULL, '2026-01-01 00:00Z', NULL),
       ('16310000-0000-4000-8000-000000000004', false, NULL, '2026-01-01 00:00Z', NULL);
UPDATE public.profiles SET account_state = 'deleting'
WHERE id = '16310000-0000-4000-8000-000000000003';

SELECT is((SELECT registered_at FROM public.account_quota_anchors
           WHERE owner_id = '16310000-0000-4000-8000-000000000001'),
          '2026-01-31 10:20Z'::timestamptz, 'Permanent INSERT uses trusted profiles.created_at');
SELECT is((SELECT source FROM public.account_quota_anchors
           WHERE owner_id = '16310000-0000-4000-8000-000000000001'),
          'profile_insert', 'Permanent INSERT records its source');
SELECT ok((SELECT registered_at IS NULL FROM public.account_quota_anchors
           WHERE owner_id = '16310000-0000-4000-8000-000000000002'),
          'Anonymous INSERT has no registration instant');
SELECT throws_ok(
    $$SELECT public.set_registration_quota_anchor('16310000-0000-4000-8000-000000000002','2026-01-01 00:00Z','evidence')$$,
    '42501', 'ACTIVE_PERMANENT_OWNER_REQUIRED', 'Service cannot anchor an anonymous owner');

CREATE TEMP TABLE anchor_conversion_clock AS SELECT clock_timestamp() AS before_at;
UPDATE public.profiles SET anonymous = false
WHERE id = '16310000-0000-4000-8000-000000000002';
SELECT ok((SELECT a.registered_at >= c.before_at AND a.registered_at <= clock_timestamp()
                  AND a.registered_at <> p.created_at
           FROM public.account_quota_anchors a JOIN public.profiles p ON p.id = a.owner_id
           CROSS JOIN anchor_conversion_clock c
           WHERE a.owner_id = '16310000-0000-4000-8000-000000000002'),
          'Guest conversion uses the current server clock, never the guest creation date');
SELECT is((SELECT source FROM public.account_quota_anchors
           WHERE owner_id = '16310000-0000-4000-8000-000000000002'),
          'anonymous_conversion', 'Conversion records its source');
CREATE TEMP TABLE anchor_conversion_before AS
SELECT to_jsonb(a) AS data FROM public.account_quota_anchors a
WHERE owner_id = '16310000-0000-4000-8000-000000000002';
UPDATE public.profiles SET anonymous = false, created_at = '2019-01-01 00:00Z'
WHERE id = '16310000-0000-4000-8000-000000000002';
SELECT is((SELECT to_jsonb(a) FROM public.account_quota_anchors a
           WHERE owner_id = '16310000-0000-4000-8000-000000000002'),
          (SELECT data FROM anchor_conversion_before), 'Repeated conversion/profile edits cannot reanchor');

SELECT lives_ok(
    $$SELECT public.set_registration_quota_anchor('16310000-0000-4000-8000-000000000001','2026-01-31 10:20Z','retry evidence')$$,
    'Same instant is an idempotent retry');
SELECT is((SELECT source FROM public.account_quota_anchors
           WHERE owner_id = '16310000-0000-4000-8000-000000000001'),
          'profile_insert', 'Retry does not replace original evidence');
SELECT throws_ok(
    $$SELECT public.set_registration_quota_anchor('16310000-0000-4000-8000-000000000001','2026-02-01 00:00Z','different date')$$,
    '23505', 'REGISTRATION_ANCHOR_CONFLICT', 'Changing a fixed date conflicts');
SELECT throws_ok(
    $$SELECT public.set_registration_quota_anchor('16310000-0000-4000-8000-000000000003','2026-01-01 00:00Z','evidence')$$,
    '42501', 'ACTIVE_PERMANENT_OWNER_REQUIRED', 'Inactive owner is rejected');
SELECT throws_ok(
    $$SELECT public.set_registration_quota_anchor('16310000-0000-4000-8000-000000000099','2026-01-01 00:00Z','evidence')$$,
    'P0002', 'OWNER_NOT_FOUND', 'Unknown owner is rejected');
SELECT throws_ok(
    $$SELECT public.set_registration_quota_anchor('16310000-0000-4000-8000-000000000001',NULL,'evidence')$$,
    '22023', 'INVALID_REGISTRATION_EVIDENCE', 'NULL registration date is rejected');
SELECT throws_ok(
    $$SELECT public.set_registration_quota_anchor('16310000-0000-4000-8000-000000000001',clock_timestamp()+interval '1 day','evidence')$$,
    '22023', 'INVALID_REGISTRATION_EVIDENCE', 'Future date is rejected');
SELECT throws_ok(
    $$SELECT public.set_registration_quota_anchor('16310000-0000-4000-8000-000000000001','infinity','evidence')$$,
    '22023', 'INVALID_REGISTRATION_EVIDENCE', 'Infinite date is rejected');
SELECT throws_ok(
    $$SELECT public.set_registration_quota_anchor('16310000-0000-4000-8000-000000000001','2026-01-31 10:20Z',E' \t\n ')$$,
    '22023', 'INVALID_REGISTRATION_EVIDENCE', 'Whitespace evidence is rejected');
SELECT throws_ok(
    $$SELECT public.set_registration_quota_anchor('16310000-0000-4000-8000-000000000001','2026-01-31 10:20Z',NULL)$$,
    '22023', 'INVALID_REGISTRATION_EVIDENCE', 'NULL evidence is rejected');

SELECT throws_ok(
    $$UPDATE public.account_quota_anchors SET registered_at = NULL WHERE owner_id = '16310000-0000-4000-8000-000000000001'$$,
    '55000', 'REGISTRATION_ANCHOR_IMMUTABLE', 'Direct clearing cannot refill');
SELECT throws_ok(
    $$UPDATE public.account_quota_anchors SET registered_at = '2026-02-01 00:00Z' WHERE owner_id = '16310000-0000-4000-8000-000000000001'$$,
    '55000', 'REGISTRATION_ANCHOR_IMMUTABLE', 'Direct date change cannot refill');
SELECT throws_ok(
    $$UPDATE public.account_quota_anchors SET source = 'replacement' WHERE owner_id = '16310000-0000-4000-8000-000000000001'$$,
    '55000', 'REGISTRATION_ANCHOR_IMMUTABLE', 'Direct evidence replacement is rejected');
SELECT throws_ok(
    $$UPDATE public.account_quota_anchors SET owner_id = '16310000-0000-4000-8000-000000000099' WHERE owner_id = '16310000-0000-4000-8000-000000000001'$$,
    '55000', 'REGISTRATION_ANCHOR_IMMUTABLE', 'Anchor cannot move to another owner');
SELECT throws_ok(
    $$DELETE FROM public.account_quota_anchors WHERE owner_id = '16310000-0000-4000-8000-000000000001'$$,
    '55000', 'REGISTRATION_ANCHOR_IMMUTABLE', 'Direct anchor deletion is rejected');
SELECT throws_ok(
    $$UPDATE public.profiles SET anonymous = true, app_account_token = NULL WHERE id = '16310000-0000-4000-8000-000000000001'$$,
    '55000', 'REGISTRATION_ANCHOR_IMMUTABLE', 'Anchored account cannot become anonymous and later refill');
SELECT lives_ok(
    $$DELETE FROM public.profiles WHERE id = '16310000-0000-4000-8000-000000000004'$$,
    'Account deletion still succeeds');
SELECT is((SELECT count(*) FROM public.account_quota_anchors
           WHERE owner_id = '16310000-0000-4000-8000-000000000004'), 0::bigint,
          'Account deletion cascades to its anchor');

CREATE TEMP TABLE anchor_purchase_before AS
SELECT to_jsonb(p) AS profile_data, to_jsonb(a) AS anchor_data
FROM public.profiles p JOIN public.account_quota_anchors a ON a.owner_id = p.id
WHERE p.id = '16310000-0000-4000-8000-000000000001';
INSERT INTO public.purchase_ownership(environment, original_transaction_id, owner_id,
                                     app_account_token, first_verified_access_at)
VALUES ('Xcode', 'fixture-registration-anchor', '16310000-0000-4000-8000-000000000001',
        '16310000-0000-4000-8000-000000000011', '2024-01-01 00:00Z');
UPDATE public.purchase_ownership SET first_verified_access_at = '2023-01-01 00:00Z'
WHERE environment = 'Xcode' AND original_transaction_id = 'fixture-registration-anchor';
INSERT INTO public.entitlements(owner_id, product_id, state, offer_kind, valid_until, trial_end_at)
VALUES ('16310000-0000-4000-8000-000000000001', 'app.narat.plants.pro.yearly',
        'active', 'trial', '2027-01-01 00:00Z', '2026-12-01 00:00Z');
UPDATE public.entitlements SET offer_kind = 'paid', trial_end_at = NULL
WHERE owner_id = '16310000-0000-4000-8000-000000000001';
UPDATE public.entitlements SET state = 'expired'
WHERE owner_id = '16310000-0000-4000-8000-000000000001';
SELECT is((SELECT to_jsonb(p) FROM public.profiles p
           WHERE id = '16310000-0000-4000-8000-000000000001'),
          (SELECT profile_data FROM anchor_purchase_before),
          'Purchase/restore/trial/expiry preserve the whole profile, including historical quota_anchor_at');
SELECT is((SELECT to_jsonb(a) FROM public.account_quota_anchors a
           WHERE owner_id = '16310000-0000-4000-8000-000000000001'),
          (SELECT anchor_data FROM anchor_purchase_before),
          'Purchase/restore/trial/expiry never reanchor registration');

SELECT ok((SELECT relrowsecurity FROM pg_class WHERE oid = 'public.account_quota_anchors'::regclass),
          'Private anchor table has RLS enabled');
SELECT ok(NOT has_table_privilege('anon','public.account_quota_anchors','SELECT')
          AND NOT has_table_privilege('authenticated','public.account_quota_anchors','SELECT'),
          'Clients have no anchor table grants');
SELECT ok(NOT EXISTS (
    SELECT 1 FROM pg_proc p
    CROSS JOIN LATERAL aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) acl
    WHERE p.oid IN ('public.set_registration_quota_anchor(uuid,timestamptz,text)'::regprocedure,
                    'public.capture_registration_quota_anchor()'::regprocedure,
                    'public.guard_registration_quota_anchor()'::regprocedure,
                    'public.ensure_profile_quota_anchor()'::regprocedure)
      AND acl.grantee IN (0, 'anon'::regrole::oid, 'authenticated'::regrole::oid)
      AND acl.privilege_type = 'EXECUTE'
), 'PUBLIC and clients cannot execute definer functions');
SELECT ok(NOT EXISTS (
    SELECT 1 FROM pg_proc p
    WHERE p.oid IN ('public.set_registration_quota_anchor(uuid,timestamptz,text)'::regprocedure,
                    'public.capture_registration_quota_anchor()'::regprocedure,
                    'public.guard_registration_quota_anchor()'::regprocedure,
                    'public.ensure_profile_quota_anchor()'::regprocedure)
      AND (NOT p.prosecdef OR NOT COALESCE(p.proconfig @> ARRAY['search_path=""'], false))
), 'All definer functions pin search_path');

SET LOCAL ROLE service_role;
SELECT lives_ok(
    $$SELECT public.set_registration_quota_anchor('16310000-0000-4000-8000-000000000001','2026-01-31 10:20Z','service retry')$$,
    'Service role can call the setter');
SELECT throws_ok(
    $$UPDATE public.account_quota_anchors SET registered_at = NULL WHERE owner_id = '16310000-0000-4000-8000-000000000001'$$,
    '42501', NULL, 'Service role cannot bypass the setter with direct writes');
SELECT throws_ok(
    $$DELETE FROM public.account_quota_anchors WHERE owner_id = '16310000-0000-4000-8000-000000000001'$$,
    '42501', NULL, 'Service role cannot delete an anchor directly');
SELECT throws_ok(
    $$INSERT INTO public.account_quota_anchors VALUES ('16310000-0000-4000-8000-000000000099',NULL,'forged')$$,
    '42501', NULL, 'Service role cannot insert anchors directly');
SELECT throws_ok($$TRUNCATE public.account_quota_anchors$$,
    '42501', NULL, 'Service role cannot truncate anchor history');
RESET ROLE;
SET LOCAL ROLE authenticated;
SELECT throws_ok($$SELECT * FROM public.account_quota_anchors$$,
    '42501', NULL, 'Authenticated client cannot read private anchors');
SELECT throws_ok(
    $$SELECT public.set_registration_quota_anchor('16310000-0000-4000-8000-000000000001','2026-01-31 10:20Z','client')$$,
    '42501', NULL, 'Authenticated client cannot set an anchor');
RESET ROLE;
SET LOCAL ROLE anon;
SELECT throws_ok(
    $$SELECT public.set_registration_quota_anchor('16310000-0000-4000-8000-000000000001','2026-01-31 10:20Z','client')$$,
    '42501', NULL, 'Anonymous client cannot set an anchor');
RESET ROLE;

CREATE TEMP TABLE anchor_windows (
    n INTEGER, anchor_at TIMESTAMPTZ, now_at TIMESTAMPTZ,
    expected_start TIMESTAMPTZ, expected_end TIMESTAMPTZ
);
INSERT INTO anchor_windows VALUES
(1,'2026-01-31 10:20Z','2026-01-31 10:20Z','2026-01-31 10:20Z','2026-02-28 10:20Z'),
(2,'2026-01-31 10:20Z','2026-02-28 10:19:59.999999Z','2026-01-31 10:20Z','2026-02-28 10:20Z'),
(3,'2026-01-31 10:20Z','2026-02-28 10:20Z','2026-02-28 10:20Z','2026-03-31 10:20Z'),
(4,'2026-01-31 10:20Z','2026-03-31 10:20Z','2026-03-31 10:20Z','2026-04-30 10:20Z'),
(5,'2024-01-31 10:20Z','2024-02-29 10:19:59.999999Z','2024-01-31 10:20Z','2024-02-29 10:20Z'),
(6,'2024-01-31 10:20Z','2024-02-29 10:20Z','2024-02-29 10:20Z','2024-03-31 10:20Z'),
(7,'2026-01-30 10:20Z','2026-02-28 10:20Z','2026-02-28 10:20Z','2026-03-30 10:20Z'),
(8,'2026-01-30 10:20Z','2026-03-30 10:20Z','2026-03-30 10:20Z','2026-04-30 10:20Z'),
(9,'2024-02-29 10:20Z','2025-02-28 10:20Z','2025-02-28 10:20Z','2025-03-29 10:20Z'),
(10,'2024-02-29 10:20Z','2025-03-29 10:20Z','2025-03-29 10:20Z','2025-04-29 10:20Z'),
(11,'2026-01-31 10:20Z','2026-01-01 00:00Z','2026-01-31 10:20Z','2026-02-28 10:20Z'),
(12,'2026-02-08 07:30Z','2026-03-08 07:30Z','2026-03-08 07:30Z','2026-04-08 07:30Z');

SET LOCAL TIME ZONE 'UTC';
SELECT results_eq(
    $$SELECT w.period_start, w.period_end FROM anchor_windows c
      CROSS JOIN LATERAL public.compute_paid_quota_window(c.anchor_at,c.now_at) w ORDER BY c.n$$,
    $$SELECT expected_start, expected_end FROM anchor_windows ORDER BY n$$,
    'UTC: exact half-open boundaries, Jan30/31 rebound, leap day, pre-anchor and DST dates');
SET LOCAL TIME ZONE 'America/New_York';
SELECT results_eq(
    $$SELECT w.period_start, w.period_end FROM anchor_windows c
      CROSS JOIN LATERAL public.compute_paid_quota_window(c.anchor_at,c.now_at) w ORDER BY c.n$$,
    $$SELECT expected_start, expected_end FROM anchor_windows ORDER BY n$$,
    'New York session and DST produce the same UTC windows');
SET LOCAL TIME ZONE 'Pacific/Auckland';
SELECT results_eq(
    $$SELECT w.period_start, w.period_end FROM anchor_windows c
      CROSS JOIN LATERAL public.compute_paid_quota_window(c.anchor_at,c.now_at) w ORDER BY c.n$$,
    $$SELECT expected_start, expected_end FROM anchor_windows ORDER BY n$$,
    'Auckland session and DST produce the same UTC windows');
SELECT throws_ok($$SELECT * FROM public.compute_paid_quota_window(NULL,now())$$,
    '22023', 'INVALID_QUOTA_WINDOW_INPUT', 'NULL anchor is rejected');
SELECT throws_ok($$SELECT * FROM public.compute_paid_quota_window(now(),NULL)$$,
    '22023', 'INVALID_QUOTA_WINDOW_INPUT', 'NULL current instant is rejected');
SELECT throws_ok($$SELECT * FROM public.compute_paid_quota_window('-infinity',now())$$,
    '22023', 'INVALID_QUOTA_WINDOW_INPUT', 'Nonfinite anchor is rejected');
SELECT throws_ok($$SELECT * FROM public.compute_paid_quota_window(now(),'infinity')$$,
    '22023', 'INVALID_QUOTA_WINDOW_INPUT', 'Nonfinite current instant is rejected');

SELECT * FROM finish();
ROLLBACK;
