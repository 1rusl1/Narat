BEGIN;
SELECT no_plan();

CREATE TEMP TABLE observation_fixture AS
SELECT gen_random_uuid() AS owner, gen_random_uuid() AS foreign_owner,
    gen_random_uuid() AS plant, gen_random_uuid() AS other_plant, gen_random_uuid() AS foreign_plant,
    gen_random_uuid() AS snapshot, gen_random_uuid() AS changed_snapshot,
    gen_random_uuid() AS operation, id AS kb
FROM public.kb_releases WHERE state = 'published';
INSERT INTO public.profiles(id, anonymous)
SELECT owner, false FROM observation_fixture UNION ALL SELECT foreign_owner, false FROM observation_fixture;
INSERT INTO public.plants(id, owner_id, plant_id, creation_source, display_name)
SELECT f.plant_id, f.owner_id, 'monstera_deliciosa', 'identification', 'Observation fixture'
FROM observation_fixture, LATERAL (VALUES (plant, owner), (other_plant, owner),
    (foreign_plant, foreign_owner)) f(plant_id, owner_id);
INSERT INTO public.condition_snapshots(id, owner_id, plant_id, version)
SELECT f.id, owner, plant, f.version FROM observation_fixture,
LATERAL (VALUES (snapshot, 1), (changed_snapshot, 2)) f(id, version);
UPDATE public.plants p SET current_condition_snapshot_id = f.snapshot
FROM observation_fixture f WHERE p.id = f.plant;

-- Pending rows are synthetic. No interval is published to a KB or presented as live evidence.
CREATE TEMP TABLE pending_controls AS
SELECT n, gen_random_uuid() AS job, gen_random_uuid() AS entry, gen_random_uuid() AS control
FROM generate_series(1, 3) n;
INSERT INTO public.analysis_jobs(id, owner_id, flow_id, intent, add_method, plant_id, mode,
    kb_release_id, prompt_version, operation_id, payload_hash, locale, snapshot_id, quota_kind, quota_state, state)
SELECT job, owner, gen_random_uuid(), 'problem', 'scan', plant, 'diagnosis', kb,
    'observation-fixture', gen_random_uuid(), 'fixture', 'en', snapshot, 'none', 'not_applicable', 'succeeded'
FROM observation_fixture CROSS JOIN pending_controls;
INSERT INTO public.care_entries(id, owner_id, plant_id, action_code, occurred_at, occurred_local_date,
    timezone, operation_id, first_aid_job_id)
SELECT entry, owner, plant, 'check_soil', now(), current_date, 'UTC', gen_random_uuid(), job
FROM observation_fixture CROSS JOIN pending_controls;
INSERT INTO public.first_aid_followups(id, owner_id, plant_id, origin_analysis_id, kb_release_id,
    action_code, first_action_snapshot, check_policy_snapshot, action_entry_id)
SELECT control, owner, plant, gen_random_uuid(), kb, 'check_soil', '{}', '{"fixture":true}', entry
FROM observation_fixture CROSS JOIN pending_controls;
INSERT INTO public.care_observations(owner_id, plant_id, status_code, operation_id)
SELECT owner, plant, 'unknown', gen_random_uuid() FROM observation_fixture;

CREATE FUNCTION pg_temp.observe(slot int, op uuid DEFAULT NULL, status text DEFAULT 'improved')
RETURNS jsonb LANGUAGE sql AS $$
    SELECT public.complete_first_aid_control(owner, coalesce(op, operation), plant,
        jsonb_build_object('control_id', control, 'status_code', status))
    FROM observation_fixture CROSS JOIN pending_controls WHERE n = slot
$$;
CREATE FUNCTION pg_temp.undo_aid(slot int) RETURNS jsonb LANGUAGE sql AS $$
    SELECT public.execute_manual_care_command(owner, gen_random_uuid(), plant, 'care.undo',
        jsonb_build_object('entry_id', entry))
    FROM observation_fixture CROSS JOIN pending_controls WHERE n = slot
$$;

SELECT ok(NOT has_function_privilege('authenticated',
    'public.complete_first_aid_control(uuid,uuid,uuid,jsonb)', 'EXECUTE'), 'RPC is service-only');
SELECT throws_ok($q$SELECT public.complete_first_aid_control(foreign_owner, operation, foreign_plant,
    jsonb_build_object('control_id', control, 'status_code', 'improved'))
    FROM observation_fixture CROSS JOIN pending_controls WHERE n = 1$q$,
    'P0002', 'FIRST_AID_CONTROL_NOT_FOUND', 'foreign control is unavailable');
SELECT throws_ok($q$SELECT public.complete_first_aid_control(owner, operation, other_plant,
    jsonb_build_object('control_id', control, 'status_code', 'improved'))
    FROM observation_fixture CROSS JOIN pending_controls WHERE n = 1$q$,
    'P0002', 'FIRST_AID_CONTROL_NOT_FOUND', 'control belongs to the selected plant');
SELECT throws_ok($q$SELECT public.complete_first_aid_control(owner, operation, plant,
    jsonb_build_object('control_id', control, 'status_code', 'improved', 'note', 'extra'))
    FROM observation_fixture CROSS JOIN pending_controls WHERE n = 1$q$,
    '22023', 'INVALID_OBSERVATION_INPUT', 'direct RPC also rejects unsupported fields');
UPDATE public.plants p SET current_condition_snapshot_id = f.changed_snapshot
FROM observation_fixture f WHERE p.id = f.plant;
SELECT throws_ok($q$SELECT pg_temp.observe(1)$q$, '23505', 'FIRST_AID_CONTROL_INACTIVE',
    'changed conditions invalidate the pending control');
UPDATE public.plants p SET current_condition_snapshot_id = f.snapshot
FROM observation_fixture f WHERE p.id = f.plant;

CREATE TEMP TABLE observation_result AS SELECT pg_temp.observe(1) AS body;
SELECT is((SELECT body->>'state' FROM observation_result), 'completed', 'control completion is accepted');
SELECT is(pg_temp.observe(1), (SELECT body FROM observation_result), 'exact replay returns the original receipt');
SELECT throws_ok($q$SELECT pg_temp.observe(1, NULL, 'worse')$q$, '23505', 'IDEMPOTENCY_CONFLICT',
    'changing the status on the same operation conflicts');
SELECT throws_ok($q$SELECT pg_temp.observe(1, gen_random_uuid())$q$, '23505', 'FIRST_AID_CONTROL_INACTIVE',
    'another operation cannot complete the same control');
SELECT throws_ok($q$SELECT public.execute_manual_care_command(owner, operation, plant, 'care.undo',
    jsonb_build_object('entry_id', entry))
    FROM observation_fixture CROSS JOIN pending_controls WHERE n = 1$q$,
    '23505', 'IDEMPOTENCY_CONFLICT', 'care command receipts share one operation namespace');
SELECT is(pg_temp.undo_aid(1)->>'state', 'voided', 'original action can be undone after completion');
SELECT is(pg_temp.observe(1), (SELECT body FROM observation_result), 'replay survives undo');
SELECT is(pg_temp.undo_aid(2)->>'state', 'voided', 'undo withdraws a second pending control');
SELECT throws_ok($q$SELECT pg_temp.observe(2, gen_random_uuid())$q$, '23505', 'FIRST_AID_CONTROL_INACTIVE',
    'observation cannot complete the withdrawn control');
INSERT INTO public.entitlements(owner_id, product_id, state, offer_kind, valid_until)
SELECT owner, 'app.narat.plants.pro.monthly', 'active', 'paid', clock_timestamp() - interval '1 second'
FROM observation_fixture;
SELECT throws_ok($q$SELECT pg_temp.observe(3, gen_random_uuid())$q$, '23505', 'FIRST_AID_CONTROL_EXPIRED',
    'past valid_until blocks a new observation even if entitlement state is active');
SELECT is(pg_temp.observe(1), (SELECT body FROM observation_result), 'replay survives access expiry');

CREATE TEMP TABLE observation_sync AS
SELECT jsonb_array_elements(public.fetch_sync_delta(owner)->'changes') AS item FROM observation_fixture;
SELECT is((SELECT item#>>'{data,state}' FROM observation_sync WHERE item->>'entity_type' = 'first_aid_followups'
    AND item->>'id' = (SELECT body->>'control_id' FROM observation_result)), 'completed',
    'owner sync preserves completed control after undo and expiry');
SELECT ok(EXISTS (SELECT 1 FROM observation_sync
    WHERE item->>'entity_type' = 'care_observations'
        AND item->>'id' = (SELECT body->>'observation_id' FROM observation_result)
        AND item#>>'{data,first_aid_control_id}' = (SELECT body->>'control_id' FROM observation_result)
        AND item#>>'{data,status_code}' = 'improved'
        AND item#>>'{data,operation_id}' = (SELECT operation::text FROM observation_fixture)
        AND (item#>>'{data,observed_at}')::timestamptz >= transaction_timestamp()
        AND (item#>>'{data,observed_at}')::timestamptz <= clock_timestamp()
        AND item#>'{data,photo_id}' = 'null'::jsonb), 'owner sync contains the linked observation and server time');
SELECT ok(EXISTS (SELECT 1 FROM observation_sync WHERE item->>'entity_type' = 'care_observations'
    AND item#>>'{data,status_code}' = 'unknown' AND NOT (item->'data' ? 'first_aid_control_id')),
    'historical observation retains its previous payload');
SELECT ok(NOT EXISTS (SELECT 1 FROM observation_fixture,
    LATERAL jsonb_array_elements(public.fetch_sync_delta(foreign_owner)->'changes') AS item
    WHERE item->>'entity_type' IN ('first_aid_followups', 'care_observations')),
    'foreign owner sync exposes neither control nor observation');
SELECT is((SELECT count(*) FROM public.care_observations
    WHERE owner_id = (SELECT owner FROM observation_fixture) AND first_aid_control_id IS NOT NULL),
    1::bigint, 'exactly one linked observation was committed');
SELECT is((SELECT count(*) FROM public.operation_receipts WHERE command_name = 'care.first_aid.observe'
    AND owner_id = (SELECT owner FROM observation_fixture)), 1::bigint, 'exactly one observation receipt was committed');
SELECT is((SELECT count(*) FROM public.analysis_jobs WHERE owner_id = (SELECT owner FROM observation_fixture)),
    3::bigint, 'existing fixture jobs are the only analysis jobs');
SELECT ok(NOT EXISTS (SELECT 1 FROM public.account_quota_usage
    WHERE owner_id = (SELECT owner FROM observation_fixture)), 'no quota usage is created');
SELECT ok(NOT EXISTS (SELECT 1 FROM public.care_tasks
    WHERE owner_id = (SELECT owner FROM observation_fixture)), 'no automatic care task is created');

SELECT * FROM finish();
ROLLBACK;
