BEGIN;
SELECT no_plan();

CREATE TEMP TABLE photo_fixture AS
SELECT gen_random_uuid() AS owner, gen_random_uuid() AS outsider,
    gen_random_uuid() AS plant, gen_random_uuid() AS foreign_plant,
    gen_random_uuid() AS ticket_op, gen_random_uuid() AS observe_op, id AS kb
FROM public.kb_releases WHERE state = 'published';
INSERT INTO public.profiles(id, anonymous)
SELECT owner, false FROM photo_fixture UNION ALL SELECT outsider, false FROM photo_fixture;
INSERT INTO public.plants(id, owner_id, plant_id, creation_source, display_name)
SELECT f.id, f.owner_id, 'monstera_deliciosa', 'identification', 'Photo cleanup fixture'
FROM photo_fixture, LATERAL (VALUES (plant, owner), (foreign_plant, outsider)) f(id, owner_id);

-- The controls are synthetic and carry no published interval.
CREATE TEMP TABLE photo_controls AS
SELECT n, gen_random_uuid() AS job, gen_random_uuid() AS entry, gen_random_uuid() AS control
FROM generate_series(1, 2) n;
INSERT INTO public.analysis_jobs(id, owner_id, flow_id, intent, add_method, plant_id, mode,
    kb_release_id, prompt_version, operation_id, payload_hash, locale, quota_kind, quota_state, state)
SELECT job, owner, gen_random_uuid(), 'problem', 'scan', plant, 'diagnosis', kb,
    'photo-cleanup-fixture', gen_random_uuid(), 'fixture', 'en', 'none', 'not_applicable', 'succeeded'
FROM photo_fixture CROSS JOIN photo_controls;
INSERT INTO public.care_entries(id, owner_id, plant_id, action_code, occurred_at, occurred_local_date,
    timezone, operation_id, first_aid_job_id)
SELECT entry, owner, plant, 'check_soil', now(), current_date, 'UTC', gen_random_uuid(), job
FROM photo_fixture CROSS JOIN photo_controls;
INSERT INTO public.first_aid_followups(id, owner_id, plant_id, origin_analysis_id, kb_release_id,
    action_code, first_action_snapshot, check_policy_snapshot, action_entry_id)
SELECT control, owner, plant, gen_random_uuid(), kb, 'check_soil', '{}', '{"fixture":true}', entry
FROM photo_fixture CROSS JOIN photo_controls;

CREATE TEMP TABLE cleanup_assets AS
SELECT name, (public.create_first_aid_photo_upload(owner, gen_random_uuid(), plant, control,
    'image/jpeg', 4, repeat('a',64))->>'photo_asset_id')::uuid AS id
FROM photo_fixture CROSS JOIN photo_controls CROSS JOIN (VALUES
    ('initialized'), ('ready'), ('attached'), ('historical'), ('unexpired')) fixture(name)
WHERE n = 1;

SELECT public.mark_first_aid_photo_ready(owner, id, repeat('a',64))
FROM photo_fixture CROSS JOIN cleanup_assets WHERE name IN ('ready', 'attached', 'historical');
SELECT public.complete_first_aid_control(owner, observe_op, plant,
    jsonb_build_object('control_id', control, 'status_code', 'unknown', 'photo_id', id))
FROM photo_fixture CROSS JOIN photo_controls CROSS JOIN cleanup_assets WHERE n=1 AND name='attached';
-- Protect history even if a legacy observation references a photo without plant_id.
INSERT INTO public.care_observations(owner_id,plant_id,status_code,photo_id,operation_id,deleted_at)
SELECT owner,plant,'unknown',id,gen_random_uuid(),clock_timestamp()
FROM photo_fixture CROSS JOIN cleanup_assets WHERE name='historical';
UPDATE public.first_aid_photo_upload_tickets t SET expires_at=clock_timestamp()-interval '1 second'
FROM cleanup_assets a WHERE a.id=t.photo_asset_id AND a.name<>'unexpired';
UPDATE public.first_aid_photo_upload_tickets t SET expires_at=clock_timestamp()+interval '1 minute'
FROM cleanup_assets a WHERE a.id=t.photo_asset_id AND a.name='unexpired';

CREATE FUNCTION pg_temp.claim(label text) RETURNS jsonb LANGUAGE sql AS $$
    SELECT public.claim_first_aid_photo_cleanup(id) FROM cleanup_assets WHERE name=label
$$;

SELECT ok(NOT has_function_privilege('authenticated','public.claim_first_aid_photo_cleanup(uuid)','EXECUTE')
    AND NOT has_function_privilege('anon','public.finish_first_aid_photo_cleanup(uuid)','EXECUTE'),
    'cleanup RPCs are service-only');
SELECT is(pg_temp.claim('unexpired'), '[]'::jsonb, 'valid ticket is preserved');
SELECT is(pg_temp.claim('attached'), '[]'::jsonb, 'attached asset is preserved past upload expiry');
SELECT is(pg_temp.claim('historical'), '[]'::jsonb, 'tombstoned historical observation protects its photo');
SELECT is(pg_temp.claim('initialized')->0->>'photo_id',
    (SELECT id::text FROM cleanup_assets WHERE name='initialized'), 'expired incomplete upload enters cleanup');
SELECT is(pg_temp.claim('ready')->0->>'photo_id',
    (SELECT id::text FROM cleanup_assets WHERE name='ready'), 'expired ready orphan enters cleanup');
SELECT is((SELECT count(*) FROM public.photo_assets a JOIN cleanup_assets f ON f.id=a.id WHERE a.state='deleting'),
    2::bigint, 'the claim fences both eligible assets before Storage access');
SELECT is((SELECT public.read_first_aid_photo_upload(owner,id) FROM photo_fixture CROSS JOIN cleanup_assets
    WHERE name='ready'), NULL::jsonb, 'fenced upload is no longer available to its owner');
SELECT throws_ok($q$SELECT public.mark_first_aid_photo_ready(owner, id, repeat('a',64))
    FROM photo_fixture CROSS JOIN cleanup_assets WHERE name='initialized'$q$,
    'P0002','PHOTO_NOT_FOUND','a pending PUT cannot mark a fenced upload ready');
SELECT is(pg_temp.claim('ready')->0->>'photo_id',
    (SELECT id::text FROM cleanup_assets WHERE name='ready'), 'interrupted Storage removal is retryable');

SELECT public.finish_first_aid_photo_cleanup(id) FROM cleanup_assets WHERE name IN ('ready', 'attached', 'historical');
CREATE TEMP TABLE cleanup_finished AS
SELECT a.deleted_at FROM public.photo_assets a JOIN cleanup_assets f ON f.id=a.id WHERE f.name='ready';
SELECT ok((SELECT deleted_at IS NOT NULL FROM cleanup_finished), 'Storage success finalizes the tombstone');
SELECT is(pg_temp.claim('ready'), '[]'::jsonb, 'finished row is skipped after the object disappears');
INSERT INTO storage.objects(bucket_id,name)
SELECT 'analysis-inputs',a.original_key FROM public.photo_assets a JOIN cleanup_assets f ON f.id=a.id WHERE f.name='ready';
SELECT is(pg_temp.claim('ready')->0->>'photo_id',
    (SELECT id::text FROM cleanup_assets WHERE name='ready'), 'late Storage write is discovered after tombstoning');
SELECT public.finish_first_aid_photo_cleanup(id) FROM cleanup_assets WHERE name='ready';
SELECT is((SELECT a.deleted_at FROM public.photo_assets a JOIN cleanup_assets f ON f.id=a.id WHERE f.name='ready'),
    (SELECT deleted_at FROM cleanup_finished), 'repeat finish preserves the original tombstone');
SELECT is((SELECT count(*) FROM public.photo_assets a JOIN cleanup_assets f ON f.id=a.id
    WHERE f.name IN ('attached','historical') AND a.state='ready' AND a.deleted_at IS NULL),
    2::bigint, 'finish cannot tombstone attached or historical photos');

SELECT * FROM finish();
ROLLBACK;
