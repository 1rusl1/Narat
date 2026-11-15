BEGIN;
SELECT no_plan();

CREATE TEMP TABLE repeat_fixture(owner_id uuid, other_owner uuid, plant_id uuid, other_plant uuid, foreign_plant uuid);
INSERT INTO repeat_fixture VALUES ('16300000-0000-4000-8000-000000000002', '16300000-0000-4000-8000-000000000001',
    gen_random_uuid(), gen_random_uuid(), gen_random_uuid());

INSERT INTO public.plants(id, owner_id, personal_name, creation_source)
SELECT plant_id, owner_id, 'Repeat plant', 'identification' FROM repeat_fixture
UNION ALL SELECT other_plant, owner_id, 'Other plant', 'identification' FROM repeat_fixture
UNION ALL SELECT foreign_plant, other_owner, 'Foreign plant', 'identification' FROM repeat_fixture;

INSERT INTO public.condition_snapshots(owner_id, plant_id, version, light_code, light_source,
    light_confirmed, watering_code, drainage_code)
SELECT owner_id, plant_id, 1, 'low', 'manual', true, 'weekly', 'no' FROM repeat_fixture
UNION ALL
SELECT owner_id, plant_id, 2, 'bright_indirect', 'manual', true, 'less_often', 'yes' FROM repeat_fixture;
UPDATE public.plants p SET current_condition_snapshot_id = s.id
FROM public.condition_snapshots s JOIN repeat_fixture f ON f.plant_id = s.plant_id
WHERE p.id = f.plant_id AND s.version = 2;

INSERT INTO public.care_entries(owner_id, plant_id, action_code, occurred_at,
    occurred_local_date, timezone, state, operation_id)
SELECT f.owner_id, p.plant_id, p.action_code, p.day::timestamptz, p.day::date, 'UTC', p.state, gen_random_uuid()
FROM repeat_fixture f CROSS JOIN LATERAL (VALUES
    (f.plant_id, 'water', '2026-10-01', 'active'),
    (f.plant_id, 'repot', '2026-10-02', 'active'),
    (f.plant_id, 'water', '2026-10-03', 'voided'),
    (f.plant_id, 'private unapproved text', '2026-10-04', 'active'),
    (f.other_plant, 'fertilize', '2026-10-05', 'active'),
    (f.plant_id, 'water', '2999-10-06', 'active')
) AS p(plant_id, action_code, day, state);
CREATE TEMP TABLE repeat_care_before AS SELECT * FROM public.care_entries;

CREATE TEMP TABLE repeat_photos AS
SELECT label, subject, (public.create_diagnosis_upload(subject, gen_random_uuid(),
    'image/jpeg', 4, repeat('c',64))->>'photo_asset_id')::uuid AS id
FROM repeat_fixture f CROSS JOIN LATERAL (VALUES ('old', f.owner_id), ('new', f.owner_id),
    ('pending', f.owner_id), ('foreign', f.other_owner)) AS p(label, subject);
SELECT public.mark_diagnosis_upload_ready(subject, id, repeat('c',64))
FROM repeat_photos WHERE label <> 'pending';

CREATE TEMP TABLE repeat_history AS SELECT public.create_diagnosis_job(
    f.owner_id, gen_random_uuid(), photo.id, NULL, 'en', true)->'job' AS body
FROM repeat_fixture f JOIN repeat_photos photo ON photo.label = 'old';
CREATE TEMP TABLE repeat_old_lease AS SELECT public.lease_diagnosis_job((body->>'job_id')::uuid) AS body
FROM repeat_history;
SELECT public.start_diagnosis_provider((body->>'job_id')::uuid,(body->>'lease_token')::uuid)
FROM repeat_old_lease;
SELECT public.finish_diagnosis_job((body->>'job_id')::uuid,(body->>'lease_token')::uuid,
    jsonb_build_object('job_id', body->>'job_id', 'mode', 'diagnosis', 'kb_release_id', body->>'kb_release_id'),
    true, NULL) FROM repeat_old_lease;
CREATE TEMP TABLE repeat_old_result AS SELECT public.read_diagnosis_job(f.owner_id,(h.body->>'job_id')::uuid) body
FROM repeat_fixture f CROSS JOIN repeat_history h;
UPDATE public.plants SET main_photo_id = (SELECT id FROM repeat_photos WHERE label = 'old')
WHERE id = (SELECT plant_id FROM repeat_fixture);
CREATE TEMP TABLE repeat_plants_before AS SELECT p.* FROM public.plants p JOIN repeat_fixture f ON p.id = f.plant_id;

CREATE FUNCTION pg_temp.repeat_create(op uuid, label text, target text, can_dispatch boolean DEFAULT true)
RETURNS jsonb LANGUAGE sql AS $$
    SELECT public.create_plant_diagnosis_job(f.owner_id, op, p.id, NULL, 'en', can_dispatch,
        CASE target WHEN 'foreign' THEN f.foreign_plant WHEN 'other' THEN f.other_plant ELSE f.plant_id END)
    FROM repeat_fixture f JOIN repeat_photos p ON p.label = repeat_create.label
$$;

SELECT throws_ok($q$SELECT pg_temp.repeat_create(gen_random_uuid(),'new','foreign')$q$,
    'P0002','PLANT_NOT_FOUND','another owner cannot target this card');
SELECT throws_ok($q$SELECT pg_temp.repeat_create(gen_random_uuid(),'foreign','own')$q$,
    'P0002','PHOTO_NOT_READY','another owner cannot supply the upload');
SELECT throws_ok($q$SELECT pg_temp.repeat_create(gen_random_uuid(),'pending','own')$q$,
    'P0002','PHOTO_NOT_READY','pending upload is rejected');
SELECT throws_ok($q$SELECT pg_temp.repeat_create(gen_random_uuid(),'old','own')$q$,
    '23505','PHOTO_ALREADY_USED','original photo cannot be reused');
SELECT throws_ok($q$SELECT pg_temp.repeat_create(gen_random_uuid(),'new','own',false)$q$,
    'P0001','PROVIDER_UNAVAILABLE','provider failure creates no receipt or reservation');
SELECT is((SELECT count(*) FROM public.analysis_jobs j JOIN repeat_fixture f ON j.owner_id = f.owner_id),
    1::bigint,'validation leaves only the previous job');

CREATE TEMP TABLE repeat_operation AS SELECT gen_random_uuid() AS id;
CREATE TEMP TABLE repeat_admission AS SELECT pg_temp.repeat_create(id,'new','own') AS body FROM repeat_operation;
CREATE TEMP TABLE repeat_job AS SELECT (body->'job'->>'job_id')::uuid AS id FROM repeat_admission;
SELECT is((SELECT body->'job'->>'quota_kind' FROM repeat_admission),'starter_diagnosis','ordinary diagnosis quota applies');
SELECT is((SELECT body->'job'->>'target_plant_id' FROM repeat_admission),
    (SELECT plant_id::text FROM repeat_fixture),'POST returns the canonical instance');
SELECT is((SELECT body->'job'->>'photo_asset_id' FROM repeat_admission),
    (SELECT id::text FROM repeat_photos WHERE label = 'new'),'POST returns the verified upload');
SELECT is(pg_temp.repeat_create((SELECT id FROM repeat_operation),'new','own',false),
    (SELECT jsonb_set(body,'{replayed}','true') FROM repeat_admission),'exact replay precedes quota and provider checks');
SELECT throws_ok($q$SELECT pg_temp.repeat_create((SELECT id FROM repeat_operation),'new','other')$q$,
    '23505','IDEMPOTENCY_CONFLICT','changed instance conflicts');
SELECT throws_ok($q$SELECT public.create_diagnosis_job(f.owner_id,o.id,p.id,NULL,'en',true)
    FROM repeat_fixture f CROSS JOIN repeat_operation o JOIN repeat_photos p ON p.label = 'new'$q$,
    '23505','IDEMPOTENCY_CONFLICT','standalone cannot replay a repeat operation');
SELECT throws_ok($q$SELECT pg_temp.repeat_create(gen_random_uuid(),'new','own')$q$,
    '23505','PHOTO_ALREADY_USED','parallel logical request cannot reuse a pending repeat upload');
SELECT is(public.read_diagnosis_job((SELECT other_owner FROM repeat_fixture),(SELECT id FROM repeat_job)),
    NULL::jsonb,'foreign status is hidden');
SELECT ok(NOT has_function_privilege('authenticated',
    'public.create_plant_diagnosis_job(uuid,uuid,uuid,uuid,text,boolean,uuid)','execute'),
    'the public client cannot call admission RPC');
SELECT ok(has_function_privilege('service_role',
    'public.create_plant_diagnosis_job(uuid,uuid,uuid,uuid,text,boolean,uuid)','execute'),
    'the service role can call admission RPC');

UPDATE public.plants SET current_condition_snapshot_id = (
    SELECT s.id FROM public.condition_snapshots s JOIN repeat_fixture f ON s.plant_id = f.plant_id WHERE s.version = 1)
WHERE id = (SELECT plant_id FROM repeat_fixture);
CREATE TEMP TABLE repeat_lease AS SELECT public.lease_diagnosis_job(id) AS body FROM repeat_job;
SELECT is((SELECT body->'repeat_context' FROM repeat_lease),
    '{"light":"bright_indirect","watering_frequency":"less_often","drainage":"yes","care_history":[
        {"action_code":"repot","occurred_local_date":"2026-10-02"},
        {"action_code":"water","occurred_local_date":"2026-10-01"}
    ]}'::jsonb,'lease uses admission snapshot and factual owner/plant history only');
SELECT is((SELECT body->'upload'->>'photo_asset_id' FROM repeat_lease),
    (SELECT id::text FROM repeat_photos WHERE label = 'new'),'worker sees only the new photo');
SELECT is(public.lease_diagnosis_job((SELECT id FROM repeat_job)),NULL::jsonb,'single lease on repeat');
SELECT public.finish_diagnosis_job((body->>'job_id')::uuid,(body->>'lease_token')::uuid,
    NULL,true,'PROVIDER_FAILURE_FIXTURE') FROM repeat_lease;
SELECT is((SELECT public.read_diagnosis_job(f.owner_id,j.id)->>'quota_state'
    FROM repeat_fixture f CROSS JOIN repeat_job j),'released','technical failure releases the normal reservation');
SELECT throws_ok($q$SELECT pg_temp.repeat_create(gen_random_uuid(),'new','other')$q$,
    '23505','PHOTO_ALREADY_USED','a failed upload can only retry for its original card');
CREATE TEMP TABLE repeat_retry AS SELECT pg_temp.repeat_create(gen_random_uuid(),'new','own')->'job' AS body;
SELECT isnt((SELECT body->>'job_id' FROM repeat_retry),(SELECT id::text FROM repeat_job),
    'technical retry creates a new job on the same photo');
CREATE TEMP TABLE repeat_retry_lease AS SELECT public.lease_diagnosis_job((body->>'job_id')::uuid) AS body FROM repeat_retry;
SELECT public.start_diagnosis_provider((body->>'job_id')::uuid,(body->>'lease_token')::uuid)
FROM repeat_retry_lease;
SELECT public.finish_diagnosis_job((body->>'job_id')::uuid,(body->>'lease_token')::uuid,
    jsonb_build_object('job_id', body->>'job_id', 'mode', 'diagnosis', 'kb_release_id', body->>'kb_release_id'),
    false, NULL) FROM repeat_retry_lease;
SELECT is((SELECT public.read_diagnosis_job(f.owner_id,(r.body->>'job_id')::uuid)->>'quota_state'
    FROM repeat_fixture f CROSS JOIN repeat_retry r),'consumed','successful retry settles normal diagnosis quota');
SELECT throws_ok($q$SELECT pg_temp.repeat_create(gen_random_uuid(),'new','own')$q$,
    '23505','PHOTO_ALREADY_USED','successful photo is not a new photo');
SELECT is((SELECT public.read_diagnosis_job(f.owner_id,(h.body->>'job_id')::uuid)
    FROM repeat_fixture f CROSS JOIN repeat_history h),
    (SELECT body FROM repeat_old_result),'historical result remains byte-equivalent JSON');
SELECT is((SELECT p.main_photo_id FROM public.plants p JOIN repeat_fixture f ON p.id = f.plant_id),
    (SELECT main_photo_id FROM repeat_plants_before),'original private photo is still the main photo');
SELECT results_eq('SELECT * FROM public.care_entries ORDER BY id','SELECT * FROM repeat_care_before ORDER BY id',
    'journal is unchanged');
SELECT is((SELECT repeat_context->>'light' FROM public.diagnosis_job_runtime
    WHERE job_id = (SELECT (body->>'job_id')::uuid FROM repeat_retry)), 'low',
    'new operation captures the newly current conditions');

SELECT * FROM finish();
ROLLBACK;
