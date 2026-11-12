BEGIN;
SELECT no_plan();

INSERT INTO public.profiles(id, anonymous) VALUES
    ('17400000-0000-4000-8000-000000000001', false),
    ('17400000-0000-4000-8000-000000000002', false);
INSERT INTO public.plants(id, owner_id, plant_id, creation_source, display_name) VALUES
    ('17400000-0000-4000-8000-000000000011', '17400000-0000-4000-8000-000000000001', 'monstera_deliciosa', 'identification', 'First-aid plant'),
    ('17400000-0000-4000-8000-000000000012', '17400000-0000-4000-8000-000000000001', 'monstera_deliciosa', 'identification', 'Other plant'),
    ('17400000-0000-4000-8000-000000000013', '17400000-0000-4000-8000-000000000002', 'monstera_deliciosa', 'identification', 'Foreign plant');

-- This synthetic policy tests numeric scheduling. No staged or live profile is changed.
INSERT INTO public.condition_profiles(kb_release_id, condition_id, version, state, protocol, field_evidence)
SELECT id, 'overwatering', 'fixture', 'published',
    '{"condition_id":"overwatering","first_help_action_id":"check_moisture","contraindication_check_ids":[],
    "actions":[{"action_id":"check_moisture","action_code":"check_soil","purpose":"diagnostic_check",
      "action_en":"Fixture: check the potting mix.","prerequisite_check_ids":[],"contraindication_check_ids":[],
      "next_check_interval_days":3}],
    "provenance":{"source_documents":[{"source_id":"fixture","url":"https://example.test/first-aid",
      "allowed_for":["derived_records"]}],
      "field_evidence":{
        "/actions/0":[{"source_id":"fixture","locator":"Fixture action"}],
        "/actions/0/next_check_interval_days":[{"source_id":"fixture","locator":"Fixture interval"}]}}}'::jsonb
    || jsonb_build_object('kb_release_id', id), '{}'::jsonb
FROM public.kb_releases WHERE state = 'published';

CREATE TEMP TABLE first_aid_jobs(slot int, job_id uuid, analysis_id uuid);
INSERT INTO first_aid_jobs SELECT n, gen_random_uuid(), gen_random_uuid() FROM generate_series(1,5) n;
INSERT INTO public.analysis_jobs(id, owner_id, flow_id, intent, add_method, plant_id, mode, kb_release_id,
    prompt_version, operation_id, payload_hash, locale, quota_kind, quota_state, state)
SELECT j.job_id, '17400000-0000-4000-8000-000000000001', gen_random_uuid(), 'problem', 'scan',
    '17400000-0000-4000-8000-000000000011', 'diagnosis', k.id, 'fixture', gen_random_uuid(),
    'fixture', 'en', 'starter_diagnosis', 'consumed', 'succeeded'
FROM first_aid_jobs j CROSS JOIN public.kb_releases k WHERE k.state = 'published';
INSERT INTO public.diagnosis_job_runtime(job_id, catalogue_release_id, projection, repeat_context)
SELECT j.job_id, c.id, jsonb_build_object('analysis_id', j.analysis_id,
    'diagnosis_status', CASE WHEN j.slot = 5 THEN 'healthy' ELSE 'problem_detected' END,
    'selected_condition_id','overwatering','identification_status','identified',
    'plant_id','monstera_deliciosa','plan_availability','available',
    'first_action_summary','Fixture: check the potting mix.','control_interval_days',3),
    '{"target_plant_id":"17400000-0000-4000-8000-000000000011"}'::jsonb
FROM first_aid_jobs j CROSS JOIN public.catalogue_releases c WHERE c.state = 'published';

CREATE FUNCTION pg_temp.first_aid(n int, op uuid,
    target uuid DEFAULT '17400000-0000-4000-8000-000000000011',
    owner uuid DEFAULT '17400000-0000-4000-8000-000000000001') RETURNS jsonb LANGUAGE sql AS $$
    SELECT public.execute_manual_care_command(owner, op, target, 'care.first_aid.record',
        jsonb_build_object('job_id', job_id, 'occurred_at','2025-10-11T23:30:00Z','timezone','Europe/Warsaw'))
    FROM first_aid_jobs WHERE slot = n
$$;
SELECT throws_ok($q$SELECT pg_temp.first_aid(1,gen_random_uuid(),
    '17400000-0000-4000-8000-000000000012')$q$,
    'P0002','FIRST_AID_ACTION_NOT_FOUND','cannot reuse diagnosis on a different owned plant');
SELECT throws_ok($q$SELECT pg_temp.first_aid(1,gen_random_uuid(),
    '17400000-0000-4000-8000-000000000013','17400000-0000-4000-8000-000000000002')$q$,
    'P0002','FIRST_AID_ACTION_NOT_FOUND','cannot reuse another owner diagnosis');
SELECT throws_ok($q$SELECT pg_temp.first_aid(5,gen_random_uuid())$q$,
    'P0002','FIRST_AID_ACTION_NOT_FOUND','healthy has no first aid');

CREATE FUNCTION pg_temp.first_aid_status(n int, owner uuid DEFAULT '17400000-0000-4000-8000-000000000001')
RETURNS jsonb LANGUAGE sql AS $$
    SELECT public.read_diagnosis_job(owner, job_id) FROM first_aid_jobs WHERE slot = n
$$;
SELECT is(pg_temp.first_aid_status(1)->'first_aid_action',
    (SELECT jsonb_build_object('job_id',job_id,'plant_id','17400000-0000-4000-8000-000000000011',
        'action_id','check_moisture','action_code','check_soil',
        'source',jsonb_build_object('url','https://example.test/first-aid','locator','Fixture action'))
     FROM first_aid_jobs WHERE slot = 1), 'owner GET supplies the exact bound action and direct evidence');
SELECT is(pg_temp.first_aid_status(1,'17400000-0000-4000-8000-000000000002'), NULL::jsonb,
    'foreign owner cannot read first-aid action');
SELECT ok(NOT (pg_temp.first_aid_status(5) ? 'first_aid_action'), 'healthy GET has no recordable action');
SELECT ok(NOT ((SELECT public.diagnosis_job_payload(job_id) FROM first_aid_jobs WHERE slot=1) ? 'first_aid_action'),
    'base payload and receipt wire are unchanged');

CREATE TEMP TABLE first_aid_op AS SELECT gen_random_uuid() AS id;
CREATE TEMP TABLE first_aid_receipt AS SELECT pg_temp.first_aid(1,id) AS body FROM first_aid_op;
SELECT ok((SELECT body->>'control_id' IS NOT NULL AND body->>'state' = 'active' FROM first_aid_receipt),
    'a verified interval creates one pending control');
SELECT is((SELECT check_policy_snapshot FROM public.first_aid_followups
    WHERE id = (SELECT (body->>'control_id')::uuid FROM first_aid_receipt)),
    '{"due_on":"2025-10-15","interval_days":3,"source":{"url":"https://example.test/first-aid","locator":"Fixture interval"}}'::jsonb,
    'date uses the performed local day and separately sourced interval');
SELECT is((SELECT action_code FROM public.care_entries
    WHERE id = (SELECT (body->>'entry_id')::uuid FROM first_aid_receipt)),
    'check_soil','first aid is an actual soil check, never a water fact');
SELECT is((SELECT pg_temp.first_aid(1,id) FROM first_aid_op),
    (SELECT body FROM first_aid_receipt),'exact retry reuses the receipt');
SELECT ok(NOT (pg_temp.first_aid_status(1) ? 'first_aid_action'), 'record hides action in status');
SELECT throws_ok($q$SELECT pg_temp.first_aid(1,gen_random_uuid())$q$,
    '23505','FIRST_AID_ALREADY_RECORDED','a new operation cannot duplicate the diagnosis control');

SELECT public.execute_manual_care_command('17400000-0000-4000-8000-000000000001',gen_random_uuid(),
    '17400000-0000-4000-8000-000000000011','care.undo',
    jsonb_build_object('entry_id',body->>'entry_id')) FROM first_aid_receipt;
SELECT is((SELECT state FROM public.first_aid_followups
    WHERE id = (SELECT (body->>'control_id')::uuid FROM first_aid_receipt)),
    'undone','undo withdraws pending control');
SELECT ok(EXISTS (
    SELECT 1 FROM jsonb_array_elements(public.fetch_sync_delta(
        '17400000-0000-4000-8000-000000000001')->'changes') item
    WHERE item->>'entity_type' = 'first_aid_followups'
      AND item->>'id' = (SELECT body->>'control_id' FROM first_aid_receipt)
      AND item->'data'->>'state' = 'undone'), 'canonical owner sync exposes the withdrawn state');
SELECT is((SELECT pg_temp.first_aid(1,id) FROM first_aid_op),
    (SELECT body FROM first_aid_receipt),'record replay after undo does not revive control');
SELECT ok(NOT (pg_temp.first_aid_status(1) ? 'first_aid_action'), 'undo does not re-advertise the action');

UPDATE public.condition_profiles SET protocol = protocol #- '{provenance,field_evidence,/actions/0/next_check_interval_days}'
WHERE version = 'fixture' AND condition_id = 'overwatering';
SELECT ok(pg_temp.first_aid_status(2) ? 'first_aid_action', 'no interval evidence still permits the sourced action');
CREATE TEMP TABLE undated AS SELECT pg_temp.first_aid(2,gen_random_uuid()) AS body;
SELECT ok((SELECT body->'control_id' = 'null'::jsonb AND body->>'entry_id' IS NOT NULL FROM undated),
    'an unsourced interval leaves an ordinary journal entry without a control');
SELECT throws_ok($q$SELECT pg_temp.first_aid(2,gen_random_uuid())$q$,
    '23505',NULL,'one action per diagnosis also applies without an interval');

UPDATE public.condition_profiles SET protocol = jsonb_set(protocol, '{provenance,field_evidence}',
    '{"/actions/0":[{"source_id":"fixture","locator":"Fixture action"}],"/actions/0/next_check_interval_days":[{"source_id":"fixture","locator":"Fixture interval"}]}'::jsonb)
WHERE version = 'fixture' AND condition_id = 'overwatering';
INSERT INTO public.entitlements(owner_id, product_id, state, offer_kind, valid_until) VALUES
    ('17400000-0000-4000-8000-000000000001','app.narat.plants.pro.monthly','expired','paid',now()-interval '1 day');
CREATE TEMP TABLE expired AS SELECT pg_temp.first_aid(3,gen_random_uuid()) AS body;
SELECT ok((SELECT body->'control_id' = 'null'::jsonb AND body->>'entry_id' IS NOT NULL FROM expired),
    'expired access still permits a journal fact without a control');
SELECT is((SELECT count(*) FROM public.first_aid_followups
    WHERE plant_id='17400000-0000-4000-8000-000000000011'), 1::bigint,'one historical control remains');
SELECT ok(NOT EXISTS(SELECT 1 FROM public.care_tasks
    WHERE plant_id='17400000-0000-4000-8000-000000000011'),'no scheduling jobs are created');

UPDATE public.condition_profiles SET protocol=protocol #- '{provenance,field_evidence,/actions/0}'
WHERE version='fixture' AND condition_id='overwatering';
SELECT ok(NOT (pg_temp.first_aid_status(4) ? 'first_aid_action'), 'interval evidence cannot replace action evidence');
SELECT throws_ok($q$SELECT pg_temp.first_aid(4,gen_random_uuid())$q$,
    'P0002','FIRST_AID_ACTION_NOT_FOUND','command rechecks the missing action evidence');

SELECT * FROM finish();
ROLLBACK;
