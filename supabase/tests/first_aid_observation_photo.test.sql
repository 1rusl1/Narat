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
SELECT f.id, f.owner_id, 'monstera_deliciosa', 'identification', 'Observation photo fixture'
FROM photo_fixture, LATERAL (VALUES (plant, owner), (foreign_plant, outsider)) f(id, owner_id);

-- The controls are synthetic and carry no published interval.
CREATE TEMP TABLE photo_controls AS
SELECT n, gen_random_uuid() AS job, gen_random_uuid() AS entry, gen_random_uuid() AS control
FROM generate_series(1, 2) n;
INSERT INTO public.analysis_jobs(id, owner_id, flow_id, intent, add_method, plant_id, mode,
    kb_release_id, prompt_version, operation_id, payload_hash, locale, quota_kind, quota_state, state)
SELECT job, owner, gen_random_uuid(), 'problem', 'scan', plant, 'diagnosis', kb,
    'observation-photo-fixture', gen_random_uuid(), 'fixture', 'en', 'none', 'not_applicable', 'succeeded'
FROM photo_fixture CROSS JOIN photo_controls;
INSERT INTO public.care_entries(id, owner_id, plant_id, action_code, occurred_at, occurred_local_date,
    timezone, operation_id, first_aid_job_id)
SELECT entry, owner, plant, 'check_soil', now(), current_date, 'UTC', gen_random_uuid(), job
FROM photo_fixture CROSS JOIN photo_controls;
INSERT INTO public.first_aid_followups(id, owner_id, plant_id, origin_analysis_id, kb_release_id,
    action_code, first_action_snapshot, check_policy_snapshot, action_entry_id)
SELECT control, owner, plant, gen_random_uuid(), kb, 'check_soil', '{}', '{"fixture":true}', entry
FROM photo_fixture CROSS JOIN photo_controls;

CREATE FUNCTION pg_temp.ticket(slot int DEFAULT 1) RETURNS jsonb LANGUAGE sql AS $$
    SELECT public.create_first_aid_photo_upload(owner, ticket_op, plant, control, 'image/jpeg', 4, repeat('a',64))
    FROM photo_fixture CROSS JOIN photo_controls WHERE n = slot
$$;
CREATE TEMP TABLE ticket_result AS SELECT (pg_temp.ticket()->>'photo_asset_id')::uuid AS id;
CREATE FUNCTION pg_temp.attach(slot int DEFAULT 1, op uuid DEFAULT NULL) RETURNS jsonb LANGUAGE sql AS $$
    SELECT public.complete_first_aid_control(owner, coalesce(op, observe_op), plant,
        jsonb_build_object('control_id', control, 'status_code', 'improved', 'photo_id', id))
    FROM photo_fixture CROSS JOIN photo_controls CROSS JOIN ticket_result WHERE n = slot
$$;

SELECT ok(NOT has_function_privilege('authenticated',
    'public.read_owned_first_aid_observation_photo(uuid,uuid)', 'EXECUTE')
    AND NOT has_table_privilege('authenticated', 'public.first_aid_photo_upload_tickets', 'SELECT'),
    'only the service can use private ticket metadata and owner read RPC');
SELECT is((pg_temp.ticket()->>'photo_asset_id')::uuid, (SELECT id FROM ticket_result), 'ticket replay reuses its asset');
SELECT throws_ok($q$SELECT pg_temp.ticket(2)$q$, '23505', 'IDEMPOTENCY_CONFLICT',
    'changing the control on an existing ticket operation conflicts');
SELECT throws_ok($q$SELECT public.create_first_aid_photo_upload(outsider, gen_random_uuid(),
    foreign_plant, control, 'image/jpeg', 4, repeat('a',64))
    FROM photo_fixture CROSS JOIN photo_controls WHERE n=1$q$,
    'P0002', 'FIRST_AID_CONTROL_NOT_FOUND', 'cannot reserve a ticket for another owner control');
SELECT is((SELECT public.read_first_aid_photo_upload(outsider, id) FROM photo_fixture CROSS JOIN ticket_result),
    NULL::jsonb, 'foreign owner cannot load ticket');
SELECT throws_ok($q$SELECT public.mark_first_aid_photo_ready(outsider, id, repeat('a',64))
    FROM photo_fixture CROSS JOIN ticket_result$q$,
    'P0002', 'PHOTO_NOT_FOUND', 'foreign owner cannot mark a photo ready');
SELECT throws_ok($q$SELECT pg_temp.attach()$q$, '23505', 'PHOTO_NOT_READY', 'initialized photo cannot be attached');
SELECT ok(NOT EXISTS (SELECT 1 FROM public.operation_receipts r JOIN photo_fixture f
    ON f.owner = r.owner_id AND f.observe_op = r.operation_id), 'rejected attachment creates no observation receipt');
SELECT is((SELECT state FROM public.first_aid_followups WHERE id = (SELECT control FROM photo_controls WHERE n=1)),
    'active', 'rejected attachment leaves the control active');

SELECT is((SELECT public.mark_first_aid_photo_ready(owner, id, repeat('a',64))->>'state'
    FROM photo_fixture CROSS JOIN ticket_result), 'ready', 'verified Storage photo becomes ready');
SELECT is((SELECT public.read_diagnosis_upload(owner, id) FROM photo_fixture CROSS JOIN ticket_result),
    NULL::jsonb, 'diagnosis upload flow cannot read care photo');
SELECT throws_ok($q$SELECT public.create_photo_analysis_job(owner, gen_random_uuid(), id, NULL, 'en', true, 'identification')
    FROM photo_fixture CROSS JOIN ticket_result$q$,
    'P0002', 'PHOTO_NOT_READY', 'care photo cannot start identification');
SELECT throws_ok($q$SELECT public.create_photo_analysis_job(owner, gen_random_uuid(), id, NULL, 'en', true, 'diagnosis')
    FROM photo_fixture CROSS JOIN ticket_result$q$,
    'P0002', 'PHOTO_NOT_READY', 'care photo cannot start diagnosis');
SELECT throws_ok($q$SELECT public.create_plant_diagnosis_job(owner, gen_random_uuid(), id, NULL, 'en', true, plant)
    FROM photo_fixture CROSS JOIN ticket_result$q$,
    'P0002', 'PHOTO_NOT_READY', 'care photo cannot start a repeat diagnosis');
SELECT is((SELECT public.read_owned_first_aid_observation_photo(owner, id) FROM photo_fixture CROSS JOIN ticket_result),
    NULL::jsonb, 'ready unattached bytes cannot be fetched by asset UUID');
SELECT throws_ok($q$SELECT pg_temp.attach(2)$q$, 'P0002', 'PHOTO_NOT_FOUND', 'ready photo is restricted to ticket control');

CREATE TEMP TABLE with_photo AS SELECT pg_temp.attach() AS body;
SELECT is((SELECT body->>'state' FROM with_photo), 'completed', 'observation and attachment commit');
SELECT is(pg_temp.attach(), (SELECT body FROM with_photo), 'exact photo observation replay preserves receipt');
SELECT throws_ok($q$SELECT public.complete_first_aid_control(owner, observe_op, plant,
    jsonb_build_object('control_id', control, 'status_code', 'improved'))
    FROM photo_fixture CROSS JOIN photo_controls WHERE n = 1$q$,
    '23505', 'IDEMPOTENCY_CONFLICT', 'removing photo from an accepted operation conflicts');
SELECT throws_ok($q$SELECT pg_temp.attach(1, gen_random_uuid())$q$, '23505', 'FIRST_AID_CONTROL_INACTIVE',
    'different operation cannot reuse a completed control');
SELECT is((SELECT public.read_owned_first_aid_observation_photo(outsider, (body->>'observation_id')::uuid)
    FROM with_photo CROSS JOIN photo_fixture), NULL::jsonb, 'foreign owner cannot read attached photo');
SELECT is((SELECT public.execute_manual_care_command(owner, gen_random_uuid(), plant, 'care.undo',
    jsonb_build_object('entry_id', entry))->>'state' FROM photo_fixture CROSS JOIN photo_controls WHERE n=1),
    'voided', 'original first-aid entry can still be undone');
INSERT INTO public.entitlements(owner_id, product_id, state, offer_kind, valid_until)
SELECT owner, 'app.narat.plants.pro.monthly', 'active', 'paid', clock_timestamp() - interval '1 second'
FROM photo_fixture;
SELECT is(pg_temp.attach(), (SELECT body FROM with_photo), 'photo replay survives undo and expiry');
SELECT is((SELECT (public.read_owned_first_aid_observation_photo(owner, (body->>'observation_id')::uuid)
    ->>'photo_asset_id')::uuid FROM with_photo CROSS JOIN photo_fixture), (SELECT id FROM ticket_result),
    'owner photo history remains readable after undo and expiry');
SELECT ok(EXISTS (SELECT 1 FROM photo_fixture CROSS JOIN with_photo CROSS JOIN ticket_result,
    LATERAL jsonb_array_elements(public.fetch_sync_delta(owner)->'changes') item
    WHERE item->>'id' = body->>'observation_id' AND item#>>'{data,photo_id}' = id::text),
    'canonical owner sync projects the photo UUID');
SELECT is((SELECT count(*) FROM public.care_observations o JOIN photo_fixture f ON f.owner = o.owner_id),
    1::bigint, 'exactly one observation');
SELECT is((SELECT count(*) FROM public.analysis_jobs j JOIN photo_fixture f ON f.owner = j.owner_id),
    2::bigint, 'only the source fixture jobs exist');
SELECT ok(NOT EXISTS (SELECT 1 FROM public.account_quota_usage u JOIN photo_fixture f ON f.owner = u.owner_id),
    'quota ledger remains empty');

SELECT * FROM finish();
ROLLBACK;
