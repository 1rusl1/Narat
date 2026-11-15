-- Actual schema and production functions; synthetic data only.
-- Concurrent lock/retry and clean/upgrade preservation run in the controller gate.
BEGIN;
SELECT plan(39);

INSERT INTO public.profiles (id, anonymous, preferred_locale) VALUES
('c1610000-0000-4000-8000-000000000001', false, 'en'),
('c1610000-0000-4000-8000-000000000002', false, 'pl'),
('c1610000-0000-4000-8000-000000000003', false, 'en');

-- Reuse a published release on seeded databases; create one on clean databases.
INSERT INTO public.catalogue_releases (id, version, state, published_at)
SELECT 'c1610000-0000-4000-8000-000000000401', 'fixture-collection-cap',
       'published', clock_timestamp()
WHERE NOT EXISTS (SELECT 1 FROM public.catalogue_releases WHERE state = 'published');
INSERT INTO public.catalogue_taxa
    (id, release_id, plant_id, accepted_scientific_name, status)
SELECT 'c1610000-0000-4000-8000-000000000301', id,
       'fixture_collection_cap', 'Fixture collection cap', 'published'
FROM public.catalogue_releases WHERE state = 'published' LIMIT 1;

SELECT is((SELECT count(*) FROM public.plants
    WHERE owner_id = 'c1610000-0000-4000-8000-000000000001'), 0::bigint,
    'Free starts empty');
SELECT lives_ok($q$
    INSERT INTO public.plants (owner_id, taxon_id, display_name)
    SELECT 'c1610000-0000-4000-8000-000000000001',
           'c1610000-0000-4000-8000-000000000301', 'Free ' || n
    FROM generate_series(1, 2) n
$q$, 'Two instances of the same taxon fit in one statement');
SELECT is((SELECT count(*) FROM public.plants
    WHERE owner_id = 'c1610000-0000-4000-8000-000000000001'), 2::bigint,
    'Capacity counts instances rather than distinct taxa');
SELECT throws_ok($q$
    INSERT INTO public.plants (owner_id, taxon_id, display_name)
    SELECT 'c1610000-0000-4000-8000-000000000001',
           'c1610000-0000-4000-8000-000000000301', 'Overflow ' || n
    FROM generate_series(1, 2) n
$q$, 'P0001', 'COLLECTION_LIMIT_REACHED', 'Multi-row insert cannot cross the cap');
SELECT is((SELECT count(*) FROM public.plants
    WHERE owner_id = 'c1610000-0000-4000-8000-000000000001'), 2::bigint,
    'Failed multi-row statement rolls back its first row');

SELECT lives_ok($q$
    SELECT public.execute_plant_create_command(
        'c1610000-0000-4000-8000-000000000001',
        'c1610000-0000-4000-8000-000000000101',
        '{"plant_id":"fixture_collection_cap","display_name":"Third"}'::jsonb)
$q$, 'RPC creates the last Free instance');
SELECT is((SELECT count(*) FROM public.plants
    WHERE owner_id = 'c1610000-0000-4000-8000-000000000001'
      AND deleted_at IS NULL), 3::bigint, 'Free reaches three');
SELECT ok(public.execute_plant_create_command(
    'c1610000-0000-4000-8000-000000000001',
    'c1610000-0000-4000-8000-000000000101',
    '{"plant_id":"fixture_collection_cap","display_name":"Third"}'::jsonb)
    = (SELECT response_payload FROM public.operation_receipts
       WHERE owner_id = 'c1610000-0000-4000-8000-000000000001'
         AND operation_id = 'c1610000-0000-4000-8000-000000000101'),
    'Exact retry at cap returns the original response');
SELECT is((SELECT count(*) FROM public.operation_receipts
    WHERE owner_id = 'c1610000-0000-4000-8000-000000000001'), 1::bigint,
    'Retry leaves one receipt');

CREATE TEMP VIEW cap_state AS SELECT jsonb_build_object(
    'profiles', (SELECT jsonb_agg(to_jsonb(p) ORDER BY id) FROM public.profiles p),
    'plants', (SELECT jsonb_agg(to_jsonb(p) ORDER BY id) FROM public.plants p),
    'receipts', (SELECT jsonb_agg(to_jsonb(r) ORDER BY owner_id, operation_id)
                 FROM public.operation_receipts r),
    'snapshots', (SELECT jsonb_agg(to_jsonb(s) ORDER BY id) FROM public.condition_snapshots s),
    'photos', (SELECT jsonb_agg(to_jsonb(p) ORDER BY id) FROM public.photo_assets p),
    'quotas', (SELECT jsonb_agg(to_jsonb(q) ORDER BY id) FROM public.monthly_quotas q)
) AS body;
CREATE TEMP TABLE cap_before_rejection AS SELECT body FROM cap_state;
SELECT throws_ok($q$
    SELECT public.execute_plant_create_command(
        'c1610000-0000-4000-8000-000000000001',
        'c1610000-0000-4000-8000-000000000102',
        '{"plant_id":"fixture_collection_cap","display_name":"Fourth"}'::jsonb)
$q$, 'P0001', 'COLLECTION_LIMIT_REACHED', 'New operation is rejected at cap');
SELECT is((SELECT body FROM cap_state), (SELECT body FROM cap_before_rejection),
    'Rejected RPC changes no watermark, instance, receipt, snapshot, photo or quota');
SELECT throws_ok($q$
    INSERT INTO public.plants (owner_id, creation_source, display_name)
    VALUES ('c1610000-0000-4000-8000-000000000001', 'guest_claim', 'Guest')
$q$, 'P0001', 'COLLECTION_LIMIT_REACHED', 'Eventual guest INSERT is constrained');
SELECT throws_ok($q$
    INSERT INTO public.plants (owner_id, creation_source, display_name)
    VALUES ('c1610000-0000-4000-8000-000000000001', 'local_fallback', 'Fallback')
$q$, 'P0001', 'COLLECTION_LIMIT_REACHED', 'Legacy writer cannot bypass cap');
SELECT lives_ok($q$
    UPDATE public.plants SET display_name = 'Edited at cap', care_revision = care_revision + 1
    WHERE owner_id = 'c1610000-0000-4000-8000-000000000001'
$q$, 'Active instance edits do not add capacity');
SELECT lives_ok($q$
    INSERT INTO public.plants (id, owner_id, taxon_id, display_name, deleted_at)
    VALUES ('c1610000-0000-4000-8000-000000000201',
            'c1610000-0000-4000-8000-000000000001',
            'c1610000-0000-4000-8000-000000000301', 'Deleted', clock_timestamp())
$q$, 'Deleted instance can be retained at cap');
SELECT is((SELECT count(*) FROM public.plants
    WHERE owner_id = 'c1610000-0000-4000-8000-000000000001'
      AND deleted_at IS NULL), 3::bigint, 'Deleted instances consume no capacity');
SELECT throws_ok($q$
    UPDATE public.plants SET deleted_at = NULL
    WHERE id = 'c1610000-0000-4000-8000-000000000201'
$q$, 'P0001', 'COLLECTION_LIMIT_REACHED', 'Restoring at cap is rejected');
SELECT lives_ok($q$
    UPDATE public.plants SET deleted_at = clock_timestamp()
    WHERE owner_id = 'c1610000-0000-4000-8000-000000000001'
      AND personal_name = 'Free 1';
    UPDATE public.plants SET deleted_at = NULL
    WHERE id = 'c1610000-0000-4000-8000-000000000201'
$q$, 'Soft delete frees capacity for restore');
SELECT is((SELECT count(*) FROM public.plants
    WHERE owner_id = 'c1610000-0000-4000-8000-000000000001'
      AND deleted_at IS NULL), 3::bigint, 'Restore uses exactly one freed place');

INSERT INTO public.entitlements (owner_id, product_id, state, offer_kind, valid_until)
VALUES ('c1610000-0000-4000-8000-000000000002', 'app.narat.plants.pro.monthly',
        'active', 'paid', clock_timestamp() + interval '1 day');
SELECT lives_ok($q$
    INSERT INTO public.plants (owner_id, taxon_id, display_name)
    SELECT 'c1610000-0000-4000-8000-000000000002',
           'c1610000-0000-4000-8000-000000000301', 'Paid ' || n
    FROM generate_series(1, 5) n
$q$, 'Verified paid owner can insert five in one statement');
SELECT is((SELECT count(*) FROM public.plants
    WHERE owner_id = 'c1610000-0000-4000-8000-000000000002'), 5::bigint,
    'Paid collection exceeds three');
SELECT throws_ok($q$
    UPDATE public.plants SET owner_id = 'c1610000-0000-4000-8000-000000000001'
    WHERE owner_id = 'c1610000-0000-4000-8000-000000000002' AND personal_name = 'Paid 1'
$q$, 'P0001', 'COLLECTION_LIMIT_REACHED', 'Transfer into full Free owner is rejected');

-- Keep state active to prove verified dates, not just state, control access.
UPDATE public.entitlements SET valid_until = clock_timestamp() - interval '1 second'
WHERE owner_id = 'c1610000-0000-4000-8000-000000000002';
SELECT is((SELECT count(*) FROM public.plants
    WHERE owner_id = 'c1610000-0000-4000-8000-000000000002'), 5::bigint,
    'Expiry retains every existing instance');
SELECT lives_ok($q$
    UPDATE public.plants SET display_name = 'After expiry'
    WHERE owner_id = 'c1610000-0000-4000-8000-000000000002'
$q$, 'Over-cap expired collection remains editable');
SELECT throws_ok($q$
    SELECT public.execute_plant_create_command(
        'c1610000-0000-4000-8000-000000000002',
        'c1610000-0000-4000-8000-000000000103',
        '{"plant_id":"fixture_collection_cap","display_name":"Backdated"}'::jsonb,
        clock_timestamp() - interval '1 day')
$q$, 'P0001', 'COLLECTION_LIMIT_REACHED', 'Caller p_now cannot revive expired paid access');
UPDATE public.plants SET deleted_at = clock_timestamp()
WHERE owner_id = 'c1610000-0000-4000-8000-000000000002' AND personal_name = 'Paid 1';
SELECT throws_ok($q$
    UPDATE public.plants SET deleted_at = NULL
    WHERE owner_id = 'c1610000-0000-4000-8000-000000000002' AND personal_name = 'Paid 1'
$q$, 'P0001', 'COLLECTION_LIMIT_REACHED', 'Expired over-cap owner cannot restore');
SELECT is((SELECT count(*) FROM public.plants
    WHERE owner_id = 'c1610000-0000-4000-8000-000000000002'
      AND deleted_at IS NULL), 4::bigint, 'Failed restore preserves four live instances');
UPDATE public.entitlements SET valid_until = clock_timestamp() + interval '1 day'
WHERE owner_id = 'c1610000-0000-4000-8000-000000000002';
SELECT lives_ok($q$
    UPDATE public.plants SET deleted_at = NULL
    WHERE owner_id = 'c1610000-0000-4000-8000-000000000002' AND personal_name = 'Paid 1'
$q$, 'Verified renewed paid access permits restore beyond cap');
SELECT lives_ok($q$
    UPDATE public.plants SET owner_id = 'c1610000-0000-4000-8000-000000000003'
    WHERE owner_id = 'c1610000-0000-4000-8000-000000000002' AND personal_name = 'Paid 2'
$q$, 'Transfer into empty Free collection succeeds');
SELECT is((SELECT count(*) FROM public.plants
    WHERE owner_id = 'c1610000-0000-4000-8000-000000000003'), 1::bigint,
    'Transfer counts one instance for the destination');

UPDATE public.profiles SET account_state = 'deleting'
WHERE id = 'c1610000-0000-4000-8000-000000000003';
SELECT throws_ok($q$
    INSERT INTO public.plants (owner_id, creation_source, display_name)
    VALUES ('c1610000-0000-4000-8000-000000000003', 'identification', 'Inactive')
$q$, '42501', 'account_not_active', 'Inactive owner cannot insert');
SELECT throws_ok($q$
    UPDATE public.plants SET owner_id = 'c1610000-0000-4000-8000-000000000003'
    WHERE owner_id = 'c1610000-0000-4000-8000-000000000002' AND personal_name = 'Paid 3'
$q$, '42501', 'account_not_active', 'Inactive owner cannot receive a transfer');
SELECT throws_ok($q$
    INSERT INTO public.plants (owner_id, creation_source, display_name)
    VALUES ('c1610000-0000-4000-8000-000000000099', 'identification', 'Missing')
$q$, 'P0002', 'owner_profile_not_found', 'Missing profile is rejected at the boundary');
SELECT ok(
    NOT has_function_privilege('anon', 'public.enforce_plant_collection_cap()', 'EXECUTE')
    AND NOT has_function_privilege('authenticated', 'public.enforce_plant_collection_cap()', 'EXECUTE'),
    'New definer helper is not executable by public client roles');

-- Hosted Supabase installs pgcrypto in extensions instead of public.
CREATE SCHEMA IF NOT EXISTS extensions;
ALTER EXTENSION pgcrypto SET SCHEMA extensions;
SELECT is(public.execute_plant_create_command(
    'c1610000-0000-4000-8000-000000000001',
    'c1610000-0000-4000-8000-000000000101',
    '{"plant_id":"fixture_collection_cap","display_name":"Third"}'::jsonb),
    (SELECT response_payload FROM public.operation_receipts
     WHERE owner_id = 'c1610000-0000-4000-8000-000000000001'
       AND operation_id = 'c1610000-0000-4000-8000-000000000101'),
    'Hosted layout replays a receipt created with pgcrypto in public');
SELECT lives_ok($q$
    SELECT public.execute_plant_create_command(
        'c1610000-0000-4000-8000-000000000002',
        'c1610000-0000-4000-8000-000000000104',
        '{"creation_source":"catalogue","plant_id":"fixture_collection_cap","display_name":"Hosted layout"}'::jsonb)
$q$, 'Hosted layout creates a new catalogue plant');
SELECT is(public.execute_plant_create_command(
    'c1610000-0000-4000-8000-000000000002',
    'c1610000-0000-4000-8000-000000000104',
    '{"creation_source":"catalogue","plant_id":"fixture_collection_cap","display_name":"Hosted layout"}'::jsonb),
    (SELECT response_payload FROM public.operation_receipts
     WHERE owner_id = 'c1610000-0000-4000-8000-000000000002'
       AND operation_id = 'c1610000-0000-4000-8000-000000000104'),
    'Hosted layout retry returns the same receipt');
SELECT is((SELECT count(*) FROM public.plants
    WHERE owner_id = 'c1610000-0000-4000-8000-000000000002' AND personal_name = 'Hosted layout'),
    1::bigint, 'Hosted layout retry leaves exactly one plant');

GRANT SELECT ON public.plants TO authenticated;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub = 'c1610000-0000-4000-8000-000000000001';
SELECT ok(
    (SELECT count(*) > 0 FROM public.plants
     WHERE owner_id = 'c1610000-0000-4000-8000-000000000001')
    AND (SELECT count(*) = 0 FROM public.plants
         WHERE owner_id <> 'c1610000-0000-4000-8000-000000000001'),
    'Real authenticated RLS shows own rows and hides other owners');
RESET ROLE;

SELECT * FROM finish();
ROLLBACK;
