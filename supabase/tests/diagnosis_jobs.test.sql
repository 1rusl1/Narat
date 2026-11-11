BEGIN;
SELECT no_plan();

CREATE TEMP TABLE photo AS SELECT (public.create_diagnosis_upload(
    '16300000-0000-4000-8000-000000000002','16310000-0000-4000-8000-000000000011',
    'image/jpeg',4,repeat('a',64))->>'photo_asset_id')::uuid id;
SELECT throws_ok($q$SELECT public.create_diagnosis_job(
    '16300000-0000-4000-8000-000000000002','16310000-0000-4000-8000-000000000012',
    (SELECT id FROM photo),NULL,'en',true)$q$,'P0002','PHOTO_NOT_READY','pending photo cannot start a job');
SELECT public.mark_diagnosis_upload_ready('16300000-0000-4000-8000-000000000002',(SELECT id FROM photo),repeat('a',64));
SELECT throws_ok($q$SELECT public.create_diagnosis_job(
    '16300000-0000-4000-8000-000000000001','16310000-0000-4000-8000-000000000012',
    (SELECT id FROM photo),NULL,'en',true)$q$,'P0002','PHOTO_NOT_READY','foreign photo cannot start a job');
SELECT throws_ok($q$SELECT public.create_diagnosis_job(
    '16300000-0000-4000-8000-000000000002','16310000-0000-4000-8000-000000000012',
    (SELECT id FROM photo),NULL,'en',false)$q$,'P0001','PROVIDER_UNAVAILABLE','unconfigured worker cannot accept new work');
CREATE TEMP TABLE created AS SELECT public.create_diagnosis_job(
    '16300000-0000-4000-8000-000000000002','16310000-0000-4000-8000-000000000012',
    (SELECT id FROM photo),NULL,'en',true) payload;
CREATE TEMP TABLE job_id AS SELECT (payload->'job'->>'job_id')::uuid id FROM created;
SELECT is((SELECT payload->'job'->>'quota_state' FROM created),'reserved','creates and reserves atomically');
SELECT is((SELECT payload->'job'->>'quota_kind' FROM created),'starter_diagnosis','uses accepted starter quota');
SELECT is(public.create_diagnosis_job('16300000-0000-4000-8000-000000000002',
    '16310000-0000-4000-8000-000000000012',(SELECT id FROM photo),NULL,'en',false),
    (SELECT jsonb_set(payload,'{replayed}','true') FROM created),'receipt replay precedes provider readiness and quota');
SELECT throws_ok($q$SELECT public.create_diagnosis_job(
    '16300000-0000-4000-8000-000000000002','16310000-0000-4000-8000-000000000012',
    (SELECT id FROM photo),NULL,'pl',true)$q$,'23505','IDEMPOTENCY_CONFLICT','locale is part of immutable job payload');
SELECT throws_ok($q$SELECT public.create_diagnosis_job(
    '16300000-0000-4000-8000-000000000002','16310000-0000-4000-8000-000000000013',
    (SELECT id FROM photo),NULL,'en',true)$q$,'P0001','QUOTA_DENIED','in-progress starter prevents a second job');
SELECT is((SELECT count(*) FROM public.analysis_jobs WHERE owner_id='16300000-0000-4000-8000-000000000002'),1::bigint,'quota denial and replay leave exactly one job');
SELECT is(public.read_diagnosis_job('16300000-0000-4000-8000-000000000001',(SELECT id FROM job_id)),NULL::jsonb,'status hides another owner');
CREATE TEMP TABLE lease AS SELECT public.lease_diagnosis_job((SELECT id FROM job_id)) AS body;
CREATE TEMP TABLE token AS SELECT (body->>'lease_token')::uuid id FROM lease;
SELECT ok((SELECT id IS NOT NULL FROM token),'worker receives a lease');
SELECT is(public.lease_diagnosis_job((SELECT id FROM job_id)),NULL::jsonb,'second dispatch cannot lease same job');
SELECT is(public.read_diagnosis_job('16300000-0000-4000-8000-000000000002',(SELECT id FROM job_id))->>'status','running','leased job is running');
SELECT is(public.read_diagnosis_catalog((SELECT id FROM job_id),gen_random_uuid()),NULL::jsonb,'foreign lease cannot read catalogue');
SELECT is(public.read_diagnosis_catalog((SELECT id FROM job_id),(SELECT id FROM token))->'plants'->0->>'plant_id',
    'monstera_deliciosa','lease reads pinned published species');
SELECT is(public.start_diagnosis_provider((SELECT id FROM job_id),gen_random_uuid())->>'allowed','false','stale lease cannot start provider');
SELECT is(public.start_diagnosis_provider((SELECT id FROM job_id),(SELECT id FROM token))->>'allowed','true','valid lease starts provider once');
SELECT is(public.start_diagnosis_provider((SELECT id FROM job_id),(SELECT id FROM token))->>'allowed','false','repeat cannot consume a provider call');
SELECT is((SELECT started_calls FROM public.provider_daily_budget WHERE utc_date=(clock_timestamp() AT TIME ZONE 'UTC')::date),1,'budget increments once');
SELECT throws_ok($q$SELECT public.finish_diagnosis_job((SELECT id FROM job_id),gen_random_uuid(),NULL,true,NULL)$q$,
    '42501','STALE_LEASE','stale lease cannot finalize');
CREATE TEMP TABLE projection AS SELECT jsonb_build_object('job_id',id,'mode','diagnosis',
    'kb_release_id',kb_release_id,'identification_status','unknown') body
FROM public.analysis_jobs WHERE id=(SELECT id FROM job_id);
SELECT is(public.finish_diagnosis_job((SELECT id FROM job_id),(SELECT id FROM token),
    (SELECT body FROM projection),false,NULL)->>'quota_state','consumed','result and original quota finalize together');
SELECT is(public.read_diagnosis_job('16300000-0000-4000-8000-000000000002',(SELECT id FROM job_id))->'result',
    (SELECT body FROM projection),'status reads persisted result');
SELECT is(public.finish_diagnosis_job((SELECT id FROM job_id),(SELECT id FROM token),NULL,true,'RETRY')->>'already_finalized',
    'true','finalize replay cannot replace result or quota');
SELECT is(public.read_diagnosis_job('16300000-0000-4000-8000-000000000002',(SELECT id FROM job_id))->>'status','succeeded','replayed failure keeps success');

INSERT INTO public.profiles(id,anonymous) VALUES ('16310000-0000-4000-8000-000000000031',false);
CREATE TEMP TABLE expiry_photo AS SELECT (public.create_diagnosis_upload(
    '16310000-0000-4000-8000-000000000031','16310000-0000-4000-8000-000000000032',
    'image/jpeg',4,repeat('c',64))->>'photo_asset_id')::uuid id;
SELECT public.mark_diagnosis_upload_ready('16310000-0000-4000-8000-000000000031',(SELECT id FROM expiry_photo),repeat('c',64));
CREATE TEMP TABLE expiry_job AS SELECT (public.create_diagnosis_job(
    '16310000-0000-4000-8000-000000000031','16310000-0000-4000-8000-000000000033',
    (SELECT id FROM expiry_photo),NULL,'en',true)->'job'->>'job_id')::uuid id;
UPDATE public.analysis_jobs SET deadline_at=clock_timestamp()-interval '1 second' WHERE id=(SELECT id FROM expiry_job);
SELECT is(public.lease_diagnosis_job((SELECT id FROM expiry_job)),NULL::jsonb,'expired job cannot lease');
SELECT is(public.read_diagnosis_job('16310000-0000-4000-8000-000000000031',(SELECT id FROM expiry_job))->>'status','expired','status settles expired job');
SELECT is((SELECT quota_state FROM public.analysis_jobs WHERE id=(SELECT id FROM expiry_job)),'released','deadline releases quota');
CREATE TEMP TABLE abandoned AS SELECT (public.create_diagnosis_job(
    '16310000-0000-4000-8000-000000000031','16310000-0000-4000-8000-000000000034',
    (SELECT id FROM expiry_photo),NULL,'en',true)->'job'->>'job_id')::uuid id;
UPDATE public.analysis_jobs SET deadline_at=clock_timestamp()-interval '1 second' WHERE id=(SELECT id FROM abandoned);
SELECT is(public.create_diagnosis_job('16310000-0000-4000-8000-000000000031',
    '16310000-0000-4000-8000-000000000035',(SELECT id FROM expiry_photo),NULL,'en',true)->'job'->>'quota_state',
    'reserved','new operation releases abandoned work before reserving');
SELECT is((SELECT quota_state FROM public.analysis_jobs WHERE id=(SELECT id FROM abandoned)),
    'released','no polling required to recover an abandoned starter');
SELECT ok(NOT has_function_privilege('authenticated','public.lease_diagnosis_job(uuid)','execute'),'client cannot lease or dispatch provider directly');
SELECT ok(NOT has_table_privilege('authenticated','public.diagnosis_job_runtime','select'),'projection table is private');
SELECT * FROM finish();
ROLLBACK;
