BEGIN;
SELECT no_plan();

-- Closed initial context uses an independent owner and the ordinary quota admission.
INSERT INTO public.profiles(id,anonymous) VALUES
    ('16310000-0000-4000-8000-000000000071',false),
    ('16310000-0000-4000-8000-000000000078',true);
CREATE TEMP TABLE initial_photo AS SELECT (public.create_diagnosis_upload(
    '16310000-0000-4000-8000-000000000071','16310000-0000-4000-8000-000000000072',
    'image/jpeg',4,repeat('d',64))->>'photo_asset_id')::uuid id;
SELECT public.mark_diagnosis_upload_ready(
    '16310000-0000-4000-8000-000000000071',(SELECT id FROM initial_photo),repeat('d',64));
CREATE FUNCTION pg_temp.initial_job(
    p_context JSONB,
    p_operation UUID DEFAULT '16310000-0000-4000-8000-000000000074',
    p_owner UUID DEFAULT '16310000-0000-4000-8000-000000000071',
    p_dispatch BOOLEAN DEFAULT true
) RETURNS JSONB LANGUAGE sql AS $$
    SELECT public.create_initial_diagnosis_job(
        p_owner,p_operation,(SELECT id FROM initial_photo),NULL,'en',p_dispatch,p_context)
$$;
SELECT ok(NOT has_function_privilege('anon',
    'public.create_initial_diagnosis_job(uuid,uuid,uuid,uuid,text,boolean,jsonb)','execute'),
    'anonymous role cannot supply initial context');
SELECT ok(NOT has_function_privilege('authenticated',
    'public.create_initial_diagnosis_job(uuid,uuid,uuid,uuid,text,boolean,jsonb)','execute'),
    'owner clients cannot execute initial admission directly');
SELECT ok(has_function_privilege('service_role',
    'public.create_initial_diagnosis_job(uuid,uuid,uuid,uuid,text,boolean,jsonb)','execute'),
    'service role can admit initial context');
SELECT throws_ok(format($q$SELECT pg_temp.initial_job(%L::jsonb)$q$, invalid),
    '22023','INVALID_INITIAL_CONTEXT','initial context rejects missing, extra or invalid values')
FROM (VALUES
    (NULL::jsonb), ('null'::jsonb), ('[]'::jsonb), ('{}'::jsonb),
    ('{"light":"low","watering_frequency":"moderate"}'::jsonb),
    ('{"light":"low","watering_frequency":"moderate","drainage":null}'::jsonb),
    ('{"light":"low","watering_frequency":"moderate","drainage":true}'::jsonb),
    ('{"light":"LOW","watering_frequency":"moderate","drainage":"yes"}'::jsonb),
    ('{"light":"low","watering_frequency":"less_often","drainage":"yes"}'::jsonb),
    ('{"light":"low","watering_frequency":"moderate","drainage":"yes","care_history":[]}'::jsonb),
    ('{"light":"low","watering_frequency":"moderate","drainage":"yes","target_plant_id":"x"}'::jsonb)
) invalid_context(invalid);
SELECT throws_ok($q$SELECT pg_temp.initial_job(
    '{"light":"low","watering_frequency":"moderate","drainage":"yes"}',
    p_owner=>'16310000-0000-4000-8000-000000000078')$q$,
    '42501','ACTIVE_PERMANENT_OWNER_REQUIRED','guest diagnosis remains forbidden');
SELECT throws_ok($q$SELECT pg_temp.initial_job(
    '{"light":"low","watering_frequency":"moderate","drainage":"yes"}',
    p_owner=>'16300000-0000-4000-8000-000000000001')$q$,
    'P0002','PHOTO_NOT_READY','initial context cannot use a foreign photo');
SELECT throws_ok($q$SELECT pg_temp.initial_job(
    '{"light":"low","watering_frequency":"moderate","drainage":"yes"}',
    p_operation=>'16310000-0000-4000-8000-000000000072')$q$,
    '23505','IDEMPOTENCY_CONFLICT','initial admission cannot overwrite an upload receipt');
SELECT throws_ok($q$SELECT pg_temp.initial_job(
    '{"light":"unknown","watering_frequency":"unknown","drainage":"unknown"}',
    p_dispatch=>false)$q$,'P0001','PROVIDER_UNAVAILABLE','valid unknown context requires a worker for new work');
SELECT throws_ok(format($q$SELECT pg_temp.initial_job(%L::jsonb,
    p_operation=>gen_random_uuid(),p_dispatch=>false)$q$, valid),
    'P0001','PROVIDER_UNAVAILABLE','supported initial enums pass SQL validation')
FROM (
    SELECT jsonb_build_object('light',light,'watering_frequency','moderate','drainage','yes') valid
    FROM unnest(ARRAY['low','medium','bright_indirect','direct_sun','unknown']) light
    UNION ALL
    SELECT jsonb_build_object('light','low','watering_frequency',watering,'drainage','yes')
    FROM unnest(ARRAY['frequent','moderate','sparse','unknown']) watering
    UNION ALL
    SELECT jsonb_build_object('light','low','watering_frequency','moderate','drainage',drainage)
    FROM unnest(ARRAY['yes','no','unknown']) drainage
) valid_context;
CREATE TEMP TABLE initial_created AS SELECT pg_temp.initial_job(
    '{"light":"low","watering_frequency":"moderate","drainage":"yes"}') body;
CREATE TEMP TABLE initial_job_id AS SELECT (body->'job'->>'job_id')::uuid id FROM initial_created;
SELECT is(public.create_initial_diagnosis_job(
    '16310000-0000-4000-8000-000000000071','16310000-0000-4000-8000-000000000074',
    (SELECT id FROM initial_photo),NULL,'en',false,
    '{"drainage":"yes","watering_frequency":"moderate","light":"low"}'),
    (SELECT jsonb_set(body,'{replayed}','true') FROM initial_created),
    'normalized exact context replays its accepted receipt without a worker');
SELECT throws_ok(format($q$SELECT pg_temp.initial_job(%L::jsonb)$q$, changed),
    '23505','IDEMPOTENCY_CONFLICT','each context field participates in exact replay')
FROM (VALUES
    ('{"light":"medium","watering_frequency":"moderate","drainage":"yes"}'::jsonb),
    ('{"light":"low","watering_frequency":"sparse","drainage":"yes"}'::jsonb),
    ('{"light":"low","watering_frequency":"moderate","drainage":"no"}'::jsonb)
) changed_context(changed);
SELECT throws_ok($q$SELECT public.create_diagnosis_job(
    '16310000-0000-4000-8000-000000000071','16310000-0000-4000-8000-000000000074',
    (SELECT id FROM initial_photo),NULL,'en',false)$q$,
    '23505','IDEMPOTENCY_CONFLICT','omitting accepted context conflicts');
SELECT throws_ok($q$SELECT public.create_photo_analysis_job(
    '16310000-0000-4000-8000-000000000071','16310000-0000-4000-8000-000000000074',
    (SELECT id FROM initial_photo),NULL,'en',false,'identification')$q$,
    '23505','IDEMPOTENCY_CONFLICT','changing accepted initial mode conflicts');
SELECT is((SELECT r.payload_hash FROM public.operation_receipts r
    WHERE owner_id='16310000-0000-4000-8000-000000000071'
      AND operation_id='16310000-0000-4000-8000-000000000074'),
    (SELECT payload_hash FROM public.analysis_jobs WHERE id=(SELECT id FROM initial_job_id)),
    'job and receipt share the exact context hash');
SELECT ok((SELECT NOT (body->'job' ? 'initial_context') FROM initial_created),
    'context stays outside the public receipt');
SELECT is((SELECT initial_context FROM public.diagnosis_job_runtime
    WHERE job_id=(SELECT id FROM initial_job_id)),
    '{"light":"low","watering_frequency":"moderate","drainage":"yes"}'::jsonb,
    'initial values are persisted exactly');
SELECT throws_ok($q$UPDATE public.diagnosis_job_runtime SET initial_context=NULL
    WHERE job_id=(SELECT id FROM initial_job_id)$q$,
    '22023','IMMUTABLE_INITIAL_CONTEXT','accepted initial context cannot be removed');
SELECT throws_ok($q$UPDATE public.diagnosis_job_runtime
    SET initial_context='{"light":"medium","watering_frequency":"moderate","drainage":"yes"}'
    WHERE job_id=(SELECT id FROM initial_job_id)$q$,
    '22023','IMMUTABLE_INITIAL_CONTEXT','accepted initial context cannot be rewritten');
CREATE TEMP TABLE initial_lease AS SELECT public.lease_diagnosis_job((SELECT id FROM initial_job_id)) body;
SELECT is((SELECT body->'initial_context' FROM initial_lease),
    '{"light":"low","watering_frequency":"moderate","drainage":"yes"}'::jsonb,
    'only the leased initial job receives its closed context');
SELECT is((SELECT body->'repeat_context' FROM initial_lease),'null'::jsonb,
    'initial context does not become repeat context');
SELECT is(public.lease_diagnosis_job((SELECT id FROM initial_job_id)),NULL::jsonb,
    'initial admission retains the single lease guard');
SELECT is(public.read_diagnosis_job('16300000-0000-4000-8000-000000000001',
    (SELECT id FROM initial_job_id)),NULL::jsonb,'initial status remains owner scoped');
SELECT is(pg_temp.initial_job(
    '{"light":"low","watering_frequency":"moderate","drainage":"yes"}',p_dispatch=>false),
    (SELECT jsonb_set(body,'{replayed}','true') FROM initial_created),
    'lease does not change the original accepted receipt');
SELECT is((SELECT count(*) FROM public.analysis_jobs
    WHERE owner_id='16310000-0000-4000-8000-000000000071'),1::bigint,
    'invalid and conflicting initial requests create no extra jobs');


CREATE TEMP TABLE photo AS SELECT (public.create_diagnosis_upload(
    '16300000-0000-4000-8000-000000000002','16310000-0000-4000-8000-000000000011',
    'image/jpeg',4,repeat('a',64))->>'photo_asset_id')::uuid id;
SELECT throws_ok($q$SELECT public.create_diagnosis_job(
    '16300000-0000-4000-8000-000000000002','16310000-0000-4000-8000-000000000012',
    (SELECT id FROM photo),NULL,'en',true)$q$,'P0002','PHOTO_NOT_READY','pending photo cannot start a job');
SELECT public.mark_diagnosis_upload_ready('16300000-0000-4000-8000-000000000002',(SELECT id FROM photo),repeat('a',64));
SELECT throws_ok($q$SELECT public.create_diagnosis_job(
    '16300000-0000-4000-8000-000000000002','16310000-0000-4000-8000-000000000011',
    (SELECT id FROM photo),NULL,'en',true)$q$,'23505','IDEMPOTENCY_CONFLICT','upload operation cannot create a job');
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
SELECT throws_ok($q$SELECT public.create_initial_diagnosis_job(
    '16300000-0000-4000-8000-000000000002','16310000-0000-4000-8000-000000000012',
    (SELECT id FROM photo),NULL,'en',true,
    '{"light":"low","watering_frequency":"moderate","drainage":"yes"}')$q$,
    '23505','IDEMPOTENCY_CONFLICT','initial context cannot replace a legacy diagnosis receipt');
SELECT is(public.create_diagnosis_job('16300000-0000-4000-8000-000000000002',
    '16310000-0000-4000-8000-000000000012',(SELECT id FROM photo),NULL,'en',false),
    (SELECT jsonb_set(payload,'{replayed}','true') FROM created),
    'rejected context leaves the legacy receipt intact');
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
SELECT ok((SELECT NOT (body ? 'initial_context') FROM lease),
    'legacy no-context lease omits initial_context');
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
-- Identification must work with no published care KB.
UPDATE public.kb_releases SET state = 'retired' WHERE state = 'published';
CREATE TEMP TABLE identification_created AS SELECT public.create_photo_analysis_job(
    '16300000-0000-4000-8000-000000000002','16310000-0000-4000-8000-000000000041',
    (SELECT id FROM photo),NULL,'en',true,'identification') payload;
CREATE TEMP TABLE identification_job AS
    SELECT (payload->'job'->>'job_id')::uuid id FROM identification_created;
SELECT is((SELECT payload->'job'->>'quota_kind' FROM identification_created),
    'starter_identification','identification has its own starter without published KB');
SELECT is((SELECT kb_release_id FROM public.analysis_jobs WHERE id=(SELECT id FROM identification_job)),
    NULL::uuid,'identification does not store a KB link');
SELECT is(public.create_photo_analysis_job('16300000-0000-4000-8000-000000000002',
    '16310000-0000-4000-8000-000000000041',(SELECT id FROM photo),NULL,'en',false,'identification'),
    (SELECT jsonb_set(payload,'{replayed}','true') FROM identification_created),'identification retries before worker availability');
SELECT throws_ok($q$SELECT public.create_diagnosis_job(
    '16300000-0000-4000-8000-000000000002','16310000-0000-4000-8000-000000000041',
    (SELECT id FROM photo),NULL,'en',true)$q$,'23505','IDEMPOTENCY_CONFLICT','diagnosis cannot replay identification');
SELECT throws_ok($q$SELECT public.create_photo_analysis_job(
    '16300000-0000-4000-8000-000000000002','16310000-0000-4000-8000-000000000012',
    (SELECT id FROM photo),NULL,'en',true,'identification')$q$,'23505','IDEMPOTENCY_CONFLICT','identification cannot replay diagnosis');
SELECT throws_ok($q$SELECT public.create_photo_analysis_job(
    '16300000-0000-4000-8000-000000000001','16310000-0000-4000-8000-000000000041',
    (SELECT id FROM photo),NULL,'en',true,'identification')$q$,'P0002','PHOTO_NOT_READY','another owner cannot identify from this photo');
SELECT is(public.read_diagnosis_job('16300000-0000-4000-8000-000000000001',(SELECT id FROM identification_job)),
    NULL::jsonb,'another owner cannot read identification');
CREATE TEMP TABLE identification_lease_payload AS
    SELECT public.lease_diagnosis_job((SELECT id FROM identification_job)) body;
CREATE TEMP TABLE identification_lease AS
    SELECT (body->>'lease_token')::uuid id FROM identification_lease_payload;
SELECT ok((SELECT NOT (body ? 'initial_context') FROM identification_lease_payload),
    'identification lease omits initial_context');
SELECT ok((SELECT id IS NOT NULL FROM identification_lease),'identification leases through the same queue');
SELECT is(public.lease_diagnosis_job((SELECT id FROM identification_job)),NULL::jsonb,'identification does not lease twice');
SELECT is(public.read_identification_catalog((SELECT id FROM identification_job),gen_random_uuid()),
    NULL::jsonb,'invalid lease cannot read identification catalogue');
CREATE TEMP TABLE identification_catalogue AS SELECT public.read_identification_catalog(
    (SELECT id FROM identification_job),(SELECT id FROM identification_lease)) body;
SELECT is((SELECT body->'plants'->0->>'plant_id' FROM identification_catalogue),
    (SELECT taxon_id::text FROM public.catalogue_release_species WHERE plant_id='monstera_deliciosa'),
    'closed identification list uses the public catalogue UUID');
SELECT ok((SELECT NOT (body ? 'kb_release_id' OR body ? 'conditions') FROM identification_catalogue),
    'identification worker input contains neither KB nor conditions');
SELECT is(public.start_diagnosis_provider((SELECT id FROM identification_job),(SELECT id FROM identification_lease))->>'allowed',
    'true','identification starts provider with the existing budget');
CREATE TEMP TABLE unknown_identification AS SELECT jsonb_build_object(
    'schema_version','1.0','job_id',(SELECT id FROM identification_job),'mode','identification',
    'catalogue_release_id',body->'catalogue_release_id','identification_status','unknown',
    'plant_id',NULL,'plant_display_name',NULL) body FROM identification_catalogue;
SELECT is(public.finish_diagnosis_job((SELECT id FROM identification_job),(SELECT id FROM identification_lease),
    (SELECT body FROM unknown_identification),true,NULL)->>'quota_state','released','unsuitable image releases the identification starter');
SELECT is(public.read_diagnosis_job('16300000-0000-4000-8000-000000000002',(SELECT id FROM identification_job))->'result',
    (SELECT body FROM unknown_identification),'unknown persists as an explicit result');

CREATE TEMP TABLE identified_job AS SELECT (public.create_photo_analysis_job(
    '16300000-0000-4000-8000-000000000002','16310000-0000-4000-8000-000000000042',
    (SELECT id FROM photo),NULL,'en',true,'identification')->'job'->>'job_id')::uuid id;
CREATE TEMP TABLE identified_lease AS
    SELECT (public.lease_diagnosis_job((SELECT id FROM identified_job))->>'lease_token')::uuid id;
UPDATE public.catalogue_releases SET state='retired' WHERE state='published';
SELECT is(public.read_identification_catalog((SELECT id FROM identified_job),(SELECT id FROM identified_lease)),
    (SELECT body FROM identification_catalogue),'an admitted job still reads its pinned catalogue after retirement');
SELECT is(public.start_diagnosis_provider((SELECT id FROM identified_job),(SELECT id FROM identified_lease))->>'allowed',
    'true','a released starter can be admitted again');
CREATE TEMP TABLE identified_result AS SELECT jsonb_build_object(
    'schema_version','1.0','job_id',(SELECT id FROM identified_job),'mode','identification',
    'catalogue_release_id',body->'catalogue_release_id','identification_status','identified',
    'plant_id',body->'plants'->0->'plant_id','plant_display_name',body->'plants'->0->'display_name') body
FROM identification_catalogue;
SELECT throws_ok($q$SELECT public.finish_diagnosis_job((SELECT id FROM identified_job),(SELECT id FROM identified_lease),
    (SELECT jsonb_set(body,'{plant_id}',to_jsonb(gen_random_uuid())) FROM identified_result),false,NULL)$q$,
    '22023','INVALID_IDENTIFICATION_RESULT','database rejects a species outside the pinned list');
SELECT throws_ok($q$SELECT public.finish_diagnosis_job((SELECT id FROM identified_job),(SELECT id FROM identified_lease),
    (SELECT jsonb_set(body,'{catalogue_release_id}',to_jsonb(gen_random_uuid())) FROM identified_result),false,NULL)$q$,
    '22023','INVALID_IDENTIFICATION_RESULT','database rejects a different catalogue pin');
SELECT throws_ok($q$SELECT public.finish_diagnosis_job((SELECT id FROM identified_job),(SELECT id FROM identified_lease),
    (SELECT body || '{"diagnosis_status":"healthy"}'::jsonb FROM identified_result),false,NULL)$q$,
    '22023','INVALID_IDENTIFICATION_RESULT','database rejects diagnosis fields in identification');
SELECT is(public.finish_diagnosis_job((SELECT id FROM identified_job),(SELECT id FROM identified_lease),
    (SELECT body FROM identified_result),false,NULL)->>'quota_state','consumed','identified success settles the original quota');
SELECT is(public.finish_diagnosis_job((SELECT id FROM identified_job),(SELECT id FROM identified_lease),NULL,true,NULL)->>'already_finalized',
    'true','identification settles only once');
SELECT is(public.read_diagnosis_job('16300000-0000-4000-8000-000000000002',(SELECT id FROM identified_job))->'result',
    (SELECT body FROM identified_result),'owner reads the immutable identification');
SELECT is(public.read_diagnosis_job('16300000-0000-4000-8000-000000000002',(SELECT id FROM job_id))->'result',
    (SELECT body FROM projection),'existing diagnosis survives independent identification and catalogue retirement');
SELECT ok(NOT has_function_privilege('authenticated','public.read_identification_catalog(uuid,uuid)','execute'),
    'client cannot bypass the identification worker');
-- Restore the active fixture for the confirmed-species save.
UPDATE public.catalogue_releases SET state='published'
WHERE id=(SELECT (body->>'catalogue_release_id')::uuid FROM identification_catalogue);
CREATE TEMP TABLE scan_input AS SELECT jsonb_build_object(
    'creation_source','catalogue','add_method','scan','creation_intent','care',
    'identification_job_id',(SELECT id FROM identified_job),'taxon_id',body->'plant_id'
) body FROM identified_result;
SELECT throws_ok($q$SELECT public.execute_plant_create_command(
    '16300000-0000-4000-8000-000000000001','16310000-0000-4000-8000-000000000051',
    (SELECT body FROM scan_input))$q$,
    'P0002','identification_source_not_found','another owner cannot attach the identification');
SELECT throws_ok($q$SELECT public.execute_plant_create_command(
    '16300000-0000-4000-8000-000000000002','16310000-0000-4000-8000-000000000051',
    (SELECT body || jsonb_build_object('origin_flow_id',gen_random_uuid()) FROM scan_input))$q$,
    'P0002','identification_source_not_found','a different flow cannot attach the photo');
SELECT throws_ok($q$SELECT public.execute_plant_create_command(
    '16300000-0000-4000-8000-000000000002','16310000-0000-4000-8000-000000000051',
    (SELECT body || jsonb_build_object('photo_id',gen_random_uuid()) FROM scan_input))$q$,
    '22023','invalid_identification_save','scan save ignores no client-supplied replacement photo');
SELECT throws_ok($q$SELECT public.execute_plant_create_command(
    '16300000-0000-4000-8000-000000000002','16310000-0000-4000-8000-000000000051',
    (SELECT body || jsonb_build_object('identification_job_id',(SELECT id FROM job_id)) FROM scan_input))$q$,
    'P0002','identification_source_not_found','a completed diagnosis is not a scan-save source');
SELECT is((SELECT plant_id FROM public.photo_assets WHERE id=(SELECT id FROM photo)),
    NULL::uuid,'failed saves leave the photo unattached');
CREATE TEMP TABLE scan_saved AS SELECT public.execute_plant_create_command(
    '16300000-0000-4000-8000-000000000002','16310000-0000-4000-8000-000000000051',
    (SELECT body FROM scan_input)) body;
CREATE TEMP TABLE scan_plant AS SELECT (body->>'plant_id')::uuid id FROM scan_saved;
SELECT is((SELECT body->>'photo_id' FROM scan_saved),(SELECT id::text FROM photo),
    'receipt records the original photo identity');
SELECT is((SELECT main_photo_id FROM public.plants WHERE id=(SELECT id FROM scan_plant)),
    (SELECT id FROM photo),'confirmed plant points to the original photo');
SELECT is((SELECT plant_id FROM public.photo_assets WHERE id=(SELECT id FROM photo)),
    (SELECT id FROM scan_plant),'original photo points back to its saved plant');
SELECT is((SELECT origin_flow_id FROM public.plants WHERE id=(SELECT id FROM scan_plant)),
    (SELECT flow_id FROM public.analysis_jobs WHERE id=(SELECT id FROM identified_job)),
    'origin flow comes from the owned completed job');
SELECT is((SELECT creation_source FROM public.plants WHERE id=(SELECT id FROM scan_plant)),
    'identification','saved instance records identification provenance');
SELECT is((SELECT taxon_id::text FROM public.plants WHERE id=(SELECT id FROM scan_plant)),
    (SELECT body->>'taxon_id' FROM scan_input),'confirmed taxon is persisted');
SELECT is(public.execute_plant_create_command(
    '16300000-0000-4000-8000-000000000002','16310000-0000-4000-8000-000000000051',
    (SELECT body FROM scan_input)),(SELECT body FROM scan_saved),'exact replay preserves the complete receipt');
SELECT throws_ok($q$SELECT public.execute_plant_create_command(
    '16300000-0000-4000-8000-000000000002','16310000-0000-4000-8000-000000000051',
    (SELECT body || '{"personal_name":"another payload"}'::jsonb FROM scan_input))$q$,
    '23505','operation_payload_mismatch','changed payload conflicts before looking at attached media');
SELECT throws_ok($q$SELECT public.execute_plant_create_command(
    '16300000-0000-4000-8000-000000000002','16310000-0000-4000-8000-000000000052',
    (SELECT body FROM scan_input))$q$,
    '23505','identification_photo_already_attached','a new operation cannot attach the original photo twice');
SELECT is(public.read_owned_plant_photo(
    '16300000-0000-4000-8000-000000000002',(SELECT id FROM scan_plant))->>'content_sha256',
    repeat('a',64),'owner reads immutable photo metadata');
SELECT is(public.read_owned_plant_photo(
    '16300000-0000-4000-8000-000000000001',(SELECT id FROM scan_plant)),NULL::jsonb,
    'another owner cannot resolve private photo metadata');
SELECT ok(NOT has_function_privilege('authenticated','public.read_owned_plant_photo(uuid,uuid)','execute'),
    'private photo lookup is service-only');
UPDATE public.plants SET deleted_at=clock_timestamp() WHERE id=(SELECT id FROM scan_plant);
SELECT is(public.read_owned_plant_photo(
    '16300000-0000-4000-8000-000000000002',(SELECT id FROM scan_plant)),NULL::jsonb,
    'a deleted plant no longer exposes photo bytes');
-- 058 is absent during the gate's earlier migration checkpoints.
-- Capture persisted effects, including quota balances and the owner watermark.
CREATE TEMP VIEW create_context_state AS SELECT jsonb_build_object(
    'profiles', (SELECT jsonb_agg(to_jsonb(p) ORDER BY id) FROM public.profiles p),
    'plants', (SELECT jsonb_agg(to_jsonb(p) ORDER BY id) FROM public.plants p),
    'snapshots', (SELECT jsonb_agg(to_jsonb(s) ORDER BY id) FROM public.condition_snapshots s),
    'receipts', (SELECT jsonb_agg(to_jsonb(r) ORDER BY owner_id,operation_id) FROM public.operation_receipts r),
    'quotas', (SELECT jsonb_agg(to_jsonb(q) ORDER BY id) FROM public.monthly_quotas q),
    'usage', (SELECT jsonb_agg(to_jsonb(u) ORDER BY job_id) FROM public.account_quota_usage u),
    'installations', (SELECT jsonb_agg(to_jsonb(i) ORDER BY id) FROM public.installation_access i),
    'jobs', (SELECT jsonb_agg(to_jsonb(j) ORDER BY id) FROM public.analysis_jobs j),
    'photos', (SELECT jsonb_agg(to_jsonb(a) ORDER BY id) FROM public.photo_assets a)
) body;

CREATE FUNCTION pg_temp.test_create_context_guard() RETURNS SETOF text
LANGUAGE plpgsql SET search_path = public, extensions, pg_temp AS $test$
<<fixture>>
DECLARE
    owner_id constant uuid := '16310000-0000-4000-8000-000000000081';
    historical_operation constant uuid := '16310000-0000-4000-8000-000000000082';
    base jsonb := '{"creation_source":"catalogue","plant_id":"monstera_deliciosa"}';
    manual jsonb := '{"conditions":{"light_level":"low","light_source":"manual","light_confirmed":true}}';
    historical jsonb;
    receipt jsonb;
    saved jsonb;
    before_state jsonb;
    source_payload jsonb;
    rejected record;
BEGIN
    IF position('CAMERA_LIGHT_SOURCE_RETIRED' IN pg_get_functiondef(
        'public.execute_plant_create_command(uuid,uuid,jsonb,timestamptz)'::regprocedure)) = 0 THEN
        RETURN QUERY SELECT * FROM skip('058 plant create context guard not installed', 1);
        RETURN;
    END IF;
    INSERT INTO public.profiles(id,anonymous) VALUES (owner_id,false);

    -- Seed an actual plant/snapshot/receipt as a pre-058 historical operation.
    -- The retired context is fixture history, never submitted as a new operation.
    receipt := public.execute_plant_create_command(owner_id,historical_operation,base || manual);
    historical := base || '{"conditions":{"light_level":"low","light_source":"camera_estimate","light_confirmed":true,"season_override":"winter"},
        "overrides":{"light_source":"camera_estimate","season_override":"summer"},"season_override":null}'::jsonb;
    UPDATE public.condition_snapshots SET light_source='camera_estimate',season_override='winter'
    WHERE plant_id=(receipt->>'plant_id')::uuid;
    UPDATE public.operation_receipts
    SET payload_hash=encode(digest('plant.create:' || historical::text,'sha256'),'hex')
    WHERE operation_receipts.owner_id=fixture.owner_id
      AND operation_id=historical_operation;
    SELECT body INTO before_state FROM create_context_state;
    RETURN NEXT is(public.execute_plant_create_command(owner_id,historical_operation,historical),
        receipt,'exact historical camera/season receipt replays before retirement guard');
    RETURN NEXT is((SELECT body - 'profiles' FROM create_context_state),before_state - 'profiles',
        'historical replay preserves plants, snapshots, receipts, photos and quotas');
    RETURN NEXT throws_ok(format('SELECT public.execute_plant_create_command(%L::uuid,%L::uuid,%L::jsonb)',
        owner_id,historical_operation,historical || '{"personal_name":"changed"}'::jsonb),
        '23505','operation_payload_mismatch','changed historical replay conflicts before retirement guard');

    SELECT body INTO before_state FROM create_context_state;
    -- Exercise catalogue, identification-photo and fallback payload entry paths.
    FOR source_payload IN
        SELECT base UNION ALL SELECT body FROM scan_input UNION ALL
        SELECT base || '{"creation_source":"local_fallback","origin_draft_id":"16310000-0000-4000-8000-000000000083","analysis_receipt":"synthetic"}'::jsonb
    LOOP
        FOR rejected IN SELECT * FROM (VALUES
            ('conditions camera','{"conditions":{"light_level":"low","light_source":"camera_estimate","light_confirmed":true}}'::jsonb,'CAMERA_LIGHT_SOURCE_RETIRED'),
            ('overrides camera','{"overrides":{"light_level":"low","light_source":"camera_estimate","light_confirmed":true}}'::jsonb,'CAMERA_LIGHT_SOURCE_RETIRED'),
            ('camera masked by manual','{"conditions":{"light_source":"camera_estimate"},"overrides":{"light_source":"manual"}}'::jsonb,'CAMERA_LIGHT_SOURCE_RETIRED'),
            ('camera with unknown light','{"conditions":{"light_level":"unknown","light_source":"camera_estimate"}}'::jsonb,'CAMERA_LIGHT_SOURCE_RETIRED'),
            ('top season','{"season_override":"auto"}'::jsonb,'SEASON_OVERRIDE_RETIRED'),
            ('top null season','{"season_override":null}'::jsonb,'SEASON_OVERRIDE_RETIRED'),
            ('conditions season','{"conditions":{"season_override":"winter"}}'::jsonb,'SEASON_OVERRIDE_RETIRED'),
            ('conditions null season','{"conditions":{"season_override":null}}'::jsonb,'SEASON_OVERRIDE_RETIRED'),
            ('overrides season','{"overrides":{"season_override":"summer"}}'::jsonb,'SEASON_OVERRIDE_RETIRED'),
            ('overrides null season','{"overrides":{"season_override":null}}'::jsonb,'SEASON_OVERRIDE_RETIRED')
        ) AS cases(label,context,error_message)
        LOOP
            RETURN NEXT throws_ok(format('SELECT public.execute_plant_create_command(%L::uuid,%L::uuid,%L::jsonb)',
                owner_id,gen_random_uuid(),source_payload || rejected.context),
                '22023',rejected.error_message,source_payload->>'creation_source' || ': rejects ' || rejected.label);
        END LOOP;
    END LOOP;
    RETURN NEXT is((SELECT body FROM create_context_state),before_state,
        'denied inputs leave plants, snapshots, receipts, quotas, photos and watermarks unchanged');

    saved := public.execute_plant_create_command(owner_id,gen_random_uuid(),base || manual);
    RETURN NEXT is((SELECT jsonb_build_array(light_source,light_code,light_confirmed)
        FROM public.condition_snapshots WHERE plant_id=(saved->>'plant_id')::uuid),
        '["manual","low",true]'::jsonb,'manual light saves with canonical source');
    saved := public.execute_plant_create_command(owner_id,gen_random_uuid(),
        base || '{"conditions":{"light_level":"unknown","light_source":"unknown","light_confirmed":false}}'::jsonb);
    RETURN NEXT is((SELECT jsonb_build_array(light_source,light_code,light_confirmed)
        FROM public.condition_snapshots WHERE plant_id=(saved->>'plant_id')::uuid),
        '["unknown","unknown",false]'::jsonb,'unknown light saves without invented manual source');
    RETURN NEXT is((SELECT count(*) FROM public.plants p WHERE p.owner_id=fixture.owner_id),
        3::bigint,'only historical, manual and unknown plants consume capacity');
END;
$test$;
SELECT * FROM pg_temp.test_create_context_guard();

-- Seven-day anonymous draft and permanent transfer from a real leased fixture job.
INSERT INTO public.profiles(id,anonymous) VALUES ('16310000-0000-4000-8000-000000000061',true);
CREATE TEMP TABLE guest_install AS SELECT (public.register_installation_access(
    repeat('e',64),'16310000-0000-4000-8000-000000000061')->>'installation_id')::uuid id;
CREATE TEMP TABLE guest_photo AS SELECT (public.create_bound_photo_upload(
    '16310000-0000-4000-8000-000000000061','16310000-0000-4000-8000-000000000062',
    'image/jpeg',4,repeat('d',64),repeat('e',64))->>'photo_asset_id')::uuid id;
SELECT public.mark_diagnosis_upload_ready('16310000-0000-4000-8000-000000000061',(SELECT id FROM guest_photo),repeat('d',64));
SELECT throws_ok($q$SELECT public.create_bound_photo_analysis_job(
    '16310000-0000-4000-8000-000000000061','16310000-0000-4000-8000-000000000063',
    (SELECT id FROM guest_photo),NULL,'en',true,'identification',repeat('f',64))$q$,
    '42501','INSTALLATION_CREDENTIAL_MISMATCH','guest identification requires the bound installation');
CREATE TEMP TABLE guest_job AS SELECT (public.create_bound_photo_analysis_job(
    '16310000-0000-4000-8000-000000000061','16310000-0000-4000-8000-000000000063',
    (SELECT id FROM guest_photo),NULL,'en',true,'identification',repeat('e',64))->'job'->>'job_id')::uuid id;
CREATE TEMP TABLE guest_lease AS SELECT (public.lease_diagnosis_job((SELECT id FROM guest_job))->>'lease_token')::uuid id;
SELECT is(public.start_diagnosis_provider((SELECT id FROM guest_job),(SELECT id FROM guest_lease))->>'allowed',
    'true','registered guest can start identification');
SELECT is(public.finish_diagnosis_job((SELECT id FROM guest_job),(SELECT id FROM guest_lease),
    (SELECT jsonb_set(body,'{job_id}',to_jsonb((SELECT id FROM guest_job))) FROM identified_result),false,NULL)->>'quota_state',
    'consumed','guest identification consumes its bound starter');
CREATE TEMP TABLE original_guest_window AS SELECT * FROM public.guest_identification_sources
WHERE photo_id=(SELECT id FROM guest_photo);
UPDATE public.guest_identification_sources SET succeeded_at=clock_timestamp()-interval '7 days',
    expires_at=clock_timestamp() WHERE photo_id=(SELECT id FROM guest_photo);
SELECT throws_ok($q$SELECT public.create_guest_photo_draft(
    '16310000-0000-4000-8000-000000000061','16310000-0000-4000-8000-000000000064',(SELECT id FROM guest_job),
    (SELECT (body->>'taxon_id')::uuid FROM scan_input),repeat('e',64))$q$,
    'P0002','DRAFT_EXPIRED','a job at the seven-day boundary cannot create a new draft');
SELECT is(public.read_diagnosis_job('16310000-0000-4000-8000-000000000061',(SELECT id FROM guest_job)),NULL::jsonb,
    'guest job result is unavailable at the seven-day boundary');
SELECT ok(EXISTS (SELECT 1 FROM jsonb_array_elements(public.read_guest_photo_cleanup(NULL)) x
    WHERE x->>'source_photo_id'=(SELECT id::text FROM guest_photo) AND x->>'draft_id' IS NULL),
    'a completed guest photo that never became a draft enters cleanup');
UPDATE public.guest_identification_sources s SET succeeded_at=o.succeeded_at-interval '1 hour',
    expires_at=o.expires_at-interval '1 hour' FROM original_guest_window o WHERE s.photo_id=o.photo_id;
CREATE TEMP TABLE guest_draft_created AS SELECT public.create_guest_photo_draft(
    '16310000-0000-4000-8000-000000000061','16310000-0000-4000-8000-000000000064',(SELECT id FROM guest_job),
    (SELECT (body->>'taxon_id')::uuid FROM scan_input),repeat('e',64)) body;
CREATE TEMP TABLE guest_draft AS SELECT (body->>'draft_id')::uuid id FROM guest_draft_created;
SELECT is((SELECT d.expires_at-s.succeeded_at FROM public.guest_drafts d
    JOIN public.guest_identification_sources s ON s.photo_id=d.photo_id WHERE d.id=(SELECT id FROM guest_draft)),
    interval '7 days','guest lifetime is exactly seven days from successful analysis');
SELECT ok((SELECT expires_at-created_at<interval '7 days' FROM public.guest_drafts WHERE id=(SELECT id FROM guest_draft)),
    'delayed confirmation does not refresh the analysis deadline');
SELECT is(public.create_guest_photo_draft(
    '16310000-0000-4000-8000-000000000061','16310000-0000-4000-8000-000000000064',(SELECT id FROM guest_job),
    (SELECT (body->>'taxon_id')::uuid FROM scan_input),repeat('e',64)),(SELECT body FROM guest_draft_created),
    'draft operation replay preserves identity and deadline');
SELECT throws_ok($q$SELECT public.prepare_guest_photo_claim(
    '16300000-0000-4000-8000-000000000001','16310000-0000-4000-8000-000000000065',
    (SELECT id FROM guest_draft),repeat('e',64))$q$,
    '42501','INSTALLATION_CREDENTIAL_MISMATCH','unbound permanent owner cannot prepare the guest claim');
SELECT public.bind_installation_credential((SELECT id FROM guest_install),'16300000-0000-4000-8000-000000000002',repeat('e',64));
CREATE TEMP TABLE guest_claim AS SELECT (public.prepare_guest_photo_claim(
    '16300000-0000-4000-8000-000000000002','16310000-0000-4000-8000-000000000065',
    (SELECT id FROM guest_draft),repeat('e',64))->>'claim_id')::uuid id;
SELECT throws_ok($q$SELECT public.process_guest_photo_claim(
    '16300000-0000-4000-8000-000000000002','16310000-0000-4000-8000-000000000066',
    (SELECT id FROM guest_claim),repeat('e',64),true)$q$,
    '22023','COPY_NOT_PREPARED','publication requires the copy phase');
SELECT is(public.process_guest_photo_claim(
    '16300000-0000-4000-8000-000000000002','16310000-0000-4000-8000-000000000066',
    (SELECT id FROM guest_claim),repeat('e',64),false)->>'destination',
    '16300000-0000-4000-8000-000000000002/'||(SELECT id::text FROM guest_photo),
    'server chooses immutable target path using the original photo ID');

UPDATE public.guest_drafts SET expires_at=clock_timestamp()-interval '1 second' WHERE id=(SELECT id FROM guest_draft);
SELECT throws_ok($q$SELECT public.process_guest_photo_claim(
    '16300000-0000-4000-8000-000000000002','16310000-0000-4000-8000-000000000066',
    (SELECT id FROM guest_claim),repeat('e',64),true)$q$,
    'P0002','DRAFT_EXPIRED','copy started before expiry cannot publish an expired draft');
UPDATE public.guest_drafts SET expires_at=created_at+interval '7 days' WHERE id=(SELECT id FROM guest_draft);
-- Use isolated statements to preserve pgTAP's accounting for rejection cases.
UPDATE public.guest_drafts SET deleted_at=clock_timestamp() WHERE id=(SELECT id FROM guest_draft);
SELECT throws_ok($q$SELECT public.process_guest_photo_claim(
    '16300000-0000-4000-8000-000000000002','16310000-0000-4000-8000-000000000066',
    (SELECT id FROM guest_claim),repeat('e',64),true)$q$,
    'P0002','DRAFT_EXPIRED','a deleted draft cannot be published');
UPDATE public.guest_drafts SET deleted_at=NULL WHERE id=(SELECT id FROM guest_draft);
CREATE TEMP TABLE guest_commit AS SELECT public.process_guest_photo_claim(
    '16300000-0000-4000-8000-000000000002','16310000-0000-4000-8000-000000000066',
    (SELECT id FROM guest_claim),repeat('e',64),true) body;
SELECT is((SELECT body->'receipt'->>'photo_id' FROM guest_commit),(SELECT id::text FROM guest_photo),
    'claim retains original photo identity');
SELECT is(public.process_guest_photo_claim(
    '16300000-0000-4000-8000-000000000002','16310000-0000-4000-8000-000000000066',
    (SELECT id FROM guest_claim),repeat('e',64),false),(SELECT body FROM guest_commit),
    'published claim replays the same receipt without a second copy');
SELECT is((SELECT count(*) FROM public.plants WHERE origin_draft_id=(SELECT id FROM guest_draft)),1::bigint,
    'one card survives replay');
SELECT is(public.read_owned_plant_photo('16300000-0000-4000-8000-000000000002',
    (SELECT (body->'receipt'->>'plant_id')::uuid FROM guest_commit))->>'content_sha256',
    repeat('d',64),'new owner reads exact source hash');
SELECT is(public.read_diagnosis_upload('16310000-0000-4000-8000-000000000061',(SELECT id FROM guest_photo)),
    NULL::jsonb,'old anonymous owner can no longer resolve the claimed photo');
SELECT is((public.read_guest_photo_cleanup((SELECT id FROM guest_draft))->0->>'source'),
    '16310000-0000-4000-8000-000000000061/'||(SELECT id::text FROM guest_photo),
    'published claim cleanup only removes the guest source');
SELECT is((public.read_guest_photo_cleanup((SELECT id FROM guest_draft))->0->>'abandoned_target'),NULL::text,
    'cleanup never deletes the published private photo');
-- Simulate an owned source being attached and then revoked before an exact replay.
CREATE TEMP TABLE initial_saved_plant AS SELECT (public.execute_plant_create_command(
    '16310000-0000-4000-8000-000000000071','16310000-0000-4000-8000-000000000079',
    '{"creation_source":"catalogue","plant_id":"monstera_deliciosa"}')->>'plant_id')::uuid id;
UPDATE public.photo_assets SET plant_id=(SELECT id FROM initial_saved_plant)
WHERE id=(SELECT id FROM initial_photo);
SELECT is(pg_temp.initial_job('{"light":"low","watering_frequency":"moderate","drainage":"yes"}',
    p_dispatch=>false)->>'replayed','true','active linked source still permits exact replay');
UPDATE public.plants SET deleted_at=clock_timestamp() WHERE id=(SELECT id FROM initial_saved_plant);
SELECT throws_ok($q$SELECT pg_temp.initial_job('{"light":"low","watering_frequency":"moderate","drainage":"yes"}',
    p_dispatch=>false)$q$,'P0002','PHOTO_NOT_READY','initial context replay respects source revocation');

-- SQL-only guest initial admission; worker/transport remain a separate package.
INSERT INTO public.profiles(id,anonymous) VALUES
    ('16320000-0000-4000-8000-000000000081',true),
    ('16320000-0000-4000-8000-000000000082',true);
CREATE TEMP TABLE bound_initial_install AS SELECT (public.register_installation_access(
    repeat('8',64),'16320000-0000-4000-8000-000000000081')->>'installation_id')::uuid id;
CREATE TEMP TABLE bound_initial_other_install AS SELECT (public.register_installation_access(
    repeat('9',64),'16320000-0000-4000-8000-000000000081')->>'installation_id')::uuid id;
CREATE TEMP TABLE bound_initial_photo AS SELECT (public.create_bound_photo_upload(
    '16320000-0000-4000-8000-000000000081',gen_random_uuid(),
    'image/jpeg',4,repeat('d',64),repeat('8',64))->>'photo_asset_id')::uuid id;
SELECT public.mark_diagnosis_upload_ready(
    '16320000-0000-4000-8000-000000000081',(SELECT id FROM bound_initial_photo),repeat('d',64));
CREATE FUNCTION pg_temp.bound_initial_create(
    p_context JSONB DEFAULT '{"light":"low","watering_frequency":"moderate","drainage":"yes"}',
    p_operation UUID DEFAULT '16320000-0000-4000-8000-000000000084',
    p_credential TEXT DEFAULT repeat('8',64), p_dispatch BOOLEAN DEFAULT true
) RETURNS JSONB LANGUAGE sql AS $$
    SELECT public.create_bound_guest_initial_diagnosis_job(
        '16320000-0000-4000-8000-000000000081',p_operation,
        (SELECT id FROM bound_initial_photo),NULL,'en',p_dispatch,p_context,p_credential)
$$;
SELECT ok(NOT has_function_privilege(role_name,rpc,'execute'),
    role_name || ' cannot execute ' || rpc)
FROM unnest(ARRAY['anon','authenticated']) role_name
CROSS JOIN unnest(ARRAY[
    'public.create_bound_guest_initial_diagnosis_job(uuid,uuid,uuid,uuid,text,boolean,jsonb,text)',
    'public.read_bound_guest_initial_diagnosis_job(uuid,uuid,text)',
    'public._create_bound_photo_analysis_job(uuid,uuid,uuid,uuid,text,boolean,text,text,jsonb)'
]) rpc;
SELECT ok(NOT has_function_privilege('service_role',
    'public._create_bound_photo_analysis_job(uuid,uuid,uuid,uuid,text,boolean,text,text,jsonb)','execute'),
    'private admission helper is not service callable');
SELECT ok(has_function_privilege('service_role',rpc,'execute'),'service can execute ' || rpc)
FROM unnest(ARRAY[
    'public.create_bound_guest_initial_diagnosis_job(uuid,uuid,uuid,uuid,text,boolean,jsonb,text)',
    'public.read_bound_guest_initial_diagnosis_job(uuid,uuid,text)'
]) rpc;
SELECT throws_ok(format($q$SELECT pg_temp.bound_initial_create(%L::jsonb)$q$,invalid),
    '22023','INVALID_INITIAL_CONTEXT','guest context is closed')
FROM (VALUES (NULL::jsonb),('null'::jsonb),('[]'::jsonb),('{}'::jsonb),
    ('{"light":"low","watering_frequency":"moderate","drainage":null}'::jsonb),
    ('{"light":"low","watering_frequency":"moderate","drainage":"yes","extra":true}'::jsonb),
    ('{"light":"invalid","watering_frequency":"moderate","drainage":"yes"}'::jsonb)
) invalid_context(invalid);
SELECT throws_ok($q$SELECT pg_temp.bound_initial_create(p_credential=>repeat('7',64))$q$,
    '42501','INSTALLATION_CREDENTIAL_MISMATCH','admission requires a linked installation');
SELECT throws_ok($q$SELECT pg_temp.bound_initial_create(p_dispatch=>false)$q$,
    'P0001','PROVIDER_UNAVAILABLE','new guest work retains dispatch gate');
SELECT throws_ok($q$SELECT public.create_bound_guest_initial_diagnosis_job(
    '16310000-0000-4000-8000-000000000071',gen_random_uuid(),
    (SELECT id FROM bound_initial_photo),NULL,'en',true,
    '{"light":"low","watering_frequency":"moderate","drainage":"yes"}',repeat('8',64))$q$,
    '42501','ACTIVE_ANONYMOUS_OWNER_REQUIRED','new RPC does not replace permanent admission');
SELECT throws_ok($q$SELECT public.create_bound_guest_initial_diagnosis_job(
    '16320000-0000-4000-8000-000000000081',gen_random_uuid(),
    (SELECT id FROM initial_photo),NULL,'en',true,
    '{"light":"low","watering_frequency":"moderate","drainage":"yes"}',repeat('8',64))$q$,
    'P0002','PHOTO_NOT_READY','guest cannot diagnose a foreign ready photo');
SELECT throws_ok($q$SELECT pg_temp.bound_initial_create()$q$,
    'P0001','PUBLISHED_RELEASE_UNAVAILABLE','guest diagnosis requires a published care KB');
-- Restore the KB retired by the earlier identification fixture.
UPDATE public.kb_releases SET state='published'
WHERE id=(SELECT kb_release_id FROM public.analysis_jobs
    WHERE id=(SELECT id FROM initial_job_id));
CREATE TEMP TABLE bound_initial_created AS SELECT pg_temp.bound_initial_create() body;
CREATE TEMP TABLE bound_initial_job AS SELECT (body->'job'->>'job_id')::uuid id FROM bound_initial_created;
SELECT is((SELECT body->'job'->>'quota_kind' FROM bound_initial_created),
    'starter_diagnosis','guest diagnosis uses the existing separate starter');
SELECT is(pg_temp.bound_initial_create(p_dispatch=>false),
    (SELECT jsonb_set(body,'{replayed}','true') FROM bound_initial_created),
    'exact retry returns the original receipt without dispatch');
SELECT throws_ok($q$SELECT pg_temp.bound_initial_create(
    '{"light":"medium","watering_frequency":"moderate","drainage":"yes"}')$q$,
    '23505','IDEMPOTENCY_CONFLICT','changed answers conflict');
SELECT throws_ok($q$SELECT pg_temp.bound_initial_create(p_credential=>repeat('9',64))$q$,
    '23505','IDEMPOTENCY_CONFLICT','same-owner different installation cannot replay admission');
SELECT is(public.read_bound_guest_initial_diagnosis_job(
    '16320000-0000-4000-8000-000000000081',(SELECT id FROM bound_initial_job),repeat('8',64)),
    (SELECT body->'job' FROM bound_initial_created),'bound status reads the admitted job');
SELECT is(public.read_bound_guest_initial_diagnosis_job(owner_id,(SELECT id FROM bound_initial_job),credential),
    NULL::jsonb,'wrong owner or installation cannot read guest diagnosis')
FROM (VALUES
    ('16320000-0000-4000-8000-000000000081'::uuid,repeat('7',64)),
    ('16320000-0000-4000-8000-000000000081'::uuid,repeat('9',64)),
    ('16320000-0000-4000-8000-000000000082'::uuid,repeat('8',64))
) denied(owner_id,credential);
SELECT is(public.read_diagnosis_job(
    '16320000-0000-4000-8000-000000000081',(SELECT id FROM bound_initial_job)),
    NULL::jsonb,'old uncredentialed status cannot expose guest diagnosis');
SELECT is(public.read_bound_guest_initial_diagnosis_job(
    '16310000-0000-4000-8000-000000000061',(SELECT id FROM guest_job),repeat('e',64)),
    NULL::jsonb,'new diagnosis status does not expose old guest identification');
SELECT throws_ok($q$SELECT public.create_photo_analysis_job(
    '16320000-0000-4000-8000-000000000081',gen_random_uuid(),
    (SELECT id FROM bound_initial_photo),NULL,'en',true,'diagnosis')$q$,
    '42501','ACTIVE_PERMANENT_OWNER_REQUIRED','legacy uncredentialed guest diagnosis remains unavailable');
SELECT throws_ok($q$SELECT public.create_bound_photo_analysis_job(
    '16320000-0000-4000-8000-000000000081',gen_random_uuid(),
    (SELECT id FROM bound_initial_photo),NULL,'en',true,'diagnosis',repeat('8',64))$q$,
    '42501','ACTIVE_PERMANENT_OWNER_REQUIRED','old bound identification entry cannot admit guest diagnosis');
SELECT ok((SELECT NOT (body->'job' ?| ARRAY['initial_context','credential_hash','installation_id'])
    FROM bound_initial_created),'admission payload omits answers and installation credentials');
SELECT is((SELECT initial_context FROM public.diagnosis_job_runtime WHERE job_id=(SELECT id FROM bound_initial_job)),
    '{"light":"low","watering_frequency":"moderate","drainage":"yes"}'::jsonb,'guest answers persist privately');
SELECT is((SELECT payload_hash FROM public.operation_receipts
    WHERE owner_id='16320000-0000-4000-8000-000000000081'
      AND operation_id='16320000-0000-4000-8000-000000000084'),
    (SELECT payload_hash FROM public.analysis_jobs WHERE id=(SELECT id FROM bound_initial_job)),
    'receipt and job share guest context provenance');
SELECT throws_ok($q$SELECT pg_temp.bound_initial_create(p_operation=>gen_random_uuid())$q$,
    'P0001','QUOTA_DENIED','a second concurrent guest diagnosis cannot reserve another starter');
-- Exercise both worker gates on a real queued admission, then reuse its finalizer.
SELECT ok(NOT has_function_privilege(role_name,
    'public._lock_bound_guest_diagnosis_worker(uuid,uuid)','execute'),
    role_name || ' cannot execute private worker admission')
FROM unnest(ARRAY['anon','authenticated','service_role']) role_name;
SELECT ok(NOT has_function_privilege(role_name,rpc,'execute'),
    role_name || ' cannot execute worker entrypoint')
FROM unnest(ARRAY['anon','authenticated']) role_name
CROSS JOIN unnest(ARRAY['public.lease_diagnosis_job(uuid)',
    'public.start_diagnosis_provider(uuid,uuid)']) rpc;
CREATE TEMP TABLE bound_worker_original AS SELECT * FROM public.analysis_jobs
WHERE id=(SELECT id FROM bound_initial_job);
CREATE TEMP TABLE bound_worker_budget AS SELECT started_calls, max_calls
FROM public.provider_daily_budget WHERE utc_date=(clock_timestamp() AT TIME ZONE 'UTC')::date;

CREATE FUNCTION pg_temp.bound_worker_denials(p_token UUID DEFAULT NULL)
RETURNS SETOF TEXT LANGUAGE plpgsql AS $$
DECLARE
    v_job public.analysis_jobs%ROWTYPE;
    v_case TEXT;
    v_actual JSONB;
    v_expected JSONB := CASE WHEN p_token IS NULL THEN NULL::jsonb ELSE '{"allowed":false}'::jsonb END;
BEGIN
    SELECT * INTO STRICT v_job FROM bound_worker_original;
    FOREACH v_case IN ARRAY ARRAY['inactive','unlinked','quota_pointer','unbound','legacy',
                                  'receipt','foreign_photo','revoked','deadline'] LOOP
        CASE v_case
        WHEN 'inactive' THEN
            UPDATE public.profiles SET account_state='deleting' WHERE id=v_job.owner_id;
        WHEN 'unlinked' THEN
            UPDATE public.installation_access SET linked_owner_ids='{}' WHERE id=v_job.quota_installation_id;
        WHEN 'quota_pointer' THEN
            UPDATE public.installation_access SET starter_diagnosis_job_id=NULL WHERE id=v_job.quota_installation_id;
        WHEN 'unbound' THEN
            UPDATE public.analysis_jobs SET quota_installation_id=NULL WHERE id=v_job.id;
        WHEN 'legacy' THEN
            -- Even a matching receipt cannot authorize an older/unbound hash.
            UPDATE public.analysis_jobs SET payload_hash=repeat('0',64) WHERE id=v_job.id;
            UPDATE public.operation_receipts SET payload_hash=repeat('0',64)
            WHERE owner_id=v_job.owner_id AND operation_id=v_job.operation_id;
        WHEN 'receipt' THEN
            UPDATE public.operation_receipts SET payload_hash=repeat('0',64)
            WHERE owner_id=v_job.owner_id AND operation_id=v_job.operation_id;
        WHEN 'foreign_photo' THEN
            UPDATE public.analysis_jobs SET photo_ids=ARRAY[(SELECT id FROM initial_photo)] WHERE id=v_job.id;
        WHEN 'revoked' THEN
            UPDATE public.photo_assets SET deleted_at=clock_timestamp() WHERE id=v_job.photo_ids[1];
        WHEN 'deadline' THEN
            UPDATE public.analysis_jobs SET deadline_at=clock_timestamp()-interval '1 second' WHERE id=v_job.id;
        END CASE;
        IF p_token IS NULL THEN
            v_actual := public.lease_diagnosis_job(v_job.id);
        ELSE
            v_actual := public.start_diagnosis_provider(v_job.id,p_token);
        END IF;
        RETURN QUERY SELECT is(v_actual,v_expected,
            CASE WHEN p_token IS NULL THEN 'guest lease rejects ' ELSE 'guest provider rejects ' END || v_case);
        -- Restore only fixture mutations; an accidental lease/start remains visible.
        UPDATE public.profiles SET account_state='active' WHERE id=v_job.owner_id AND v_case='inactive';
        UPDATE public.installation_access SET linked_owner_ids=ARRAY[v_job.owner_id]
        WHERE id=v_job.quota_installation_id AND v_case='unlinked';
        UPDATE public.installation_access SET starter_diagnosis_job_id=v_job.id
        WHERE id=v_job.quota_installation_id AND v_case='quota_pointer';
        UPDATE public.analysis_jobs SET quota_installation_id=v_job.quota_installation_id,
            payload_hash=v_job.payload_hash, photo_ids=v_job.photo_ids, deadline_at=v_job.deadline_at
        WHERE id=v_job.id;
        UPDATE public.operation_receipts SET payload_hash=v_job.payload_hash
        WHERE owner_id=v_job.owner_id AND operation_id=v_job.operation_id AND v_case IN ('legacy','receipt');
        UPDATE public.photo_assets SET deleted_at=NULL WHERE id=v_job.photo_ids[1] AND v_case='revoked';
    END LOOP;
END;
$$;
SELECT * FROM pg_temp.bound_worker_denials();
CREATE TEMP TABLE bound_worker_lease AS SELECT public.lease_diagnosis_job((SELECT id FROM bound_initial_job)) body;
SELECT ok((SELECT body->>'lease_token' IS NOT NULL FROM bound_worker_lease),'fresh bound guest receives a worker lease');
SELECT is((SELECT body->'initial_context' FROM bound_worker_lease),
    '{"light":"low","watering_frequency":"moderate","drainage":"yes"}'::jsonb,'lease carries exact immutable guest answers');
SELECT is((SELECT body->'repeat_context' FROM bound_worker_lease),'null'::jsonb,'guest initial lease has no repeat context');
SELECT is((SELECT body->'upload'->>'photo_asset_id' FROM bound_worker_lease),
    (SELECT id::text FROM bound_initial_photo),'worker receives the exact admitted raw photo');
SELECT is(public.lease_diagnosis_job((SELECT id FROM bound_initial_job)),NULL::jsonb,'guest cannot lease twice');
SELECT is(public.start_diagnosis_provider((SELECT id FROM bound_initial_job),gen_random_uuid())->>'allowed',
    'false','wrong guest lease token cannot start provider');
SELECT is(public.start_diagnosis_provider((SELECT id FROM bound_initial_job),NULL)->>'allowed',
    'false','null guest lease token cannot start provider');
SELECT * FROM pg_temp.bound_worker_denials((SELECT (body->>'lease_token')::uuid FROM bound_worker_lease));
UPDATE public.provider_daily_budget SET max_calls=started_calls
WHERE utc_date=(clock_timestamp() AT TIME ZONE 'UTC')::date;
SELECT is(public.start_diagnosis_provider((SELECT id FROM bound_initial_job),
    (SELECT (body->>'lease_token')::uuid FROM bound_worker_lease))->>'allowed',
    'false','guest provider respects existing daily budget ceiling');
UPDATE public.provider_daily_budget SET max_calls=(SELECT max_calls FROM bound_worker_budget)
WHERE utc_date=(clock_timestamp() AT TIME ZONE 'UTC')::date;
SELECT is((SELECT started_calls FROM public.provider_daily_budget
    WHERE utc_date=(clock_timestamp() AT TIME ZONE 'UTC')::date),
    (SELECT started_calls FROM bound_worker_budget),'denied guest dispatches do not debit provider budget');
SELECT is(public.start_diagnosis_provider((SELECT id FROM bound_initial_job),
    (SELECT (body->>'lease_token')::uuid FROM bound_worker_lease))->>'allowed',
    'true','bound guest diagnosis starts provider');
SELECT is(public.start_diagnosis_provider((SELECT id FROM bound_initial_job),
    (SELECT (body->>'lease_token')::uuid FROM bound_worker_lease))->>'allowed',
    'false','bound guest provider starts once');
SELECT is((SELECT started_calls FROM public.provider_daily_budget
    WHERE utc_date=(clock_timestamp() AT TIME ZONE 'UTC')::date),
    (SELECT started_calls+1 FROM bound_worker_budget),'guest provider debits budget exactly once');
CREATE TEMP TABLE bound_worker_signed AS SELECT jsonb_build_object(
    'analysis_id','16320000-0000-4000-8000-000000000090',
    'kb_release_id',kb_release_id,'mode','diagnosis','plant_id','monstera_deliciosa',
    'selected_condition_id',NULL,'decision_revision',1,'issued_at',clock_timestamp()) body
FROM public.analysis_jobs WHERE id=(SELECT id FROM bound_initial_job);
CREATE TEMP TABLE bound_worker_projection AS SELECT jsonb_build_object(
    'analysis_id',s.body->'analysis_id','job_id',j.id,'mode','diagnosis',
    'kb_release_id',j.kb_release_id,'locale',j.locale,
    'identification_status','identified','plant_id','monstera_deliciosa',
    'diagnosis_status','healthy','selected_condition_id',NULL,
    -- Trusted resolver fixture. SQL does not possess the worker's HMAC secret.
    'analysis_receipt',encode(convert_to(s.body::text,'UTF8'),'base64') || '.' || repeat('a',64)) body
FROM public.analysis_jobs j CROSS JOIN bound_worker_signed s
WHERE j.id=(SELECT id FROM bound_initial_job);
SELECT is(public.finish_diagnosis_job((SELECT id FROM bound_initial_job),
    (SELECT (body->>'lease_token')::uuid FROM bound_worker_lease),
    (SELECT body FROM bound_worker_projection),false,NULL)->>'quota_state',
    'consumed','existing finalizer settles the leased guest diagnosis');
SELECT is(public.read_bound_guest_initial_diagnosis_job(
    '16320000-0000-4000-8000-000000000081',(SELECT id FROM bound_initial_job),repeat('8',64))->'result',
    (SELECT body FROM bound_worker_projection),'bound GET returns the actual finalized worker projection');
SELECT is(public.finish_diagnosis_job((SELECT id FROM bound_initial_job),
    (SELECT (body->>'lease_token')::uuid FROM bound_worker_lease),NULL,true,'RETRY')->>'already_finalized',
    'true','guest finalizer retry cannot replace result or charge again');
SELECT is(public.read_bound_guest_initial_diagnosis_job(
    '16320000-0000-4000-8000-000000000081',(SELECT id FROM bound_initial_job),repeat('8',64))->>'quota_state',
    'consumed','successful fixture settlement consumes one starter');
CREATE TEMP TABLE bound_initial_quota_before AS SELECT to_jsonb(i) body FROM public.installation_access i
WHERE id=(SELECT id FROM bound_initial_install);
SELECT throws_ok($q$SELECT pg_temp.bound_initial_create(p_operation=>gen_random_uuid())$q$,
    'P0001','QUOTA_DENIED','a consumed guest starter cannot be used again');
SELECT is(pg_temp.bound_initial_create(p_dispatch=>false),
    (SELECT jsonb_set(body,'{replayed}','true') FROM bound_initial_created),
    'consumed job retry still returns the exact receipt');
SELECT is((SELECT to_jsonb(i) FROM public.installation_access i WHERE id=(SELECT id FROM bound_initial_install)),
    (SELECT body FROM bound_initial_quota_before),'denials and retries produce no extra installation debit');
SELECT ok((SELECT starter_diagnosis_consumed AND NOT starter_identification_consumed
    FROM public.installation_access WHERE id=(SELECT id FROM bound_initial_install)),
    'diagnosis consumption leaves identification starter untouched');
SELECT is((SELECT count(*) FROM public.analysis_jobs
    WHERE owner_id='16320000-0000-4000-8000-000000000081'),1::bigint,
    'conflicts and second admissions create no extra job');
UPDATE public.installation_access SET linked_owner_ids='{}'
WHERE id=(SELECT id FROM bound_initial_install);
SELECT is(public.read_bound_guest_initial_diagnosis_job(
    '16320000-0000-4000-8000-000000000081',(SELECT id FROM bound_initial_job),repeat('8',64)),
    NULL::jsonb,'status requires a current installation link');
SELECT throws_ok($q$SELECT pg_temp.bound_initial_create()$q$,
    '42501','INSTALLATION_CREDENTIAL_MISMATCH','retry requires a current installation link');
UPDATE public.installation_access SET linked_owner_ids=ARRAY['16320000-0000-4000-8000-000000000081'::uuid]
WHERE id=(SELECT id FROM bound_initial_install);
UPDATE public.photo_assets SET deleted_at=clock_timestamp() WHERE id=(SELECT id FROM bound_initial_photo);
SELECT is(public.read_bound_guest_initial_diagnosis_job(
    '16320000-0000-4000-8000-000000000081',(SELECT id FROM bound_initial_job),repeat('8',64)),
    NULL::jsonb,'revoked source is unavailable to bound status');
SELECT throws_ok($q$SELECT pg_temp.bound_initial_create()$q$,
    'P0002','PHOTO_NOT_READY','revoked source prevents exact retry');
-- Restore the source revoked by the preceding boundary fixture.
UPDATE public.photo_assets SET deleted_at=NULL WHERE id=(SELECT id FROM bound_initial_photo);
CREATE FUNCTION pg_temp.diagnosis_draft(
    p_operation UUID DEFAULT '16320000-0000-4000-8000-000000000091',
    p_job UUID DEFAULT NULL,
    p_owner UUID DEFAULT '16320000-0000-4000-8000-000000000081',
    p_credential TEXT DEFAULT repeat('8',64)
) RETURNS JSONB LANGUAGE sql AS $$
    SELECT public.create_bound_guest_diagnosis_draft(p_owner,p_operation,coalesce(p_job,(SELECT id FROM bound_initial_job)),p_credential)
$$;
SELECT ok(NOT has_function_privilege(role_name,
    'public.create_bound_guest_diagnosis_draft(uuid,uuid,uuid,text)','execute'),
    role_name || ' cannot create a diagnosis draft directly')
FROM unnest(ARRAY['anon','authenticated']) role_name;
SELECT ok(has_function_privilege('service_role',
    'public.create_bound_guest_diagnosis_draft(uuid,uuid,uuid,text)','execute'),
    'service can create a bound diagnosis draft');
SELECT ok(NOT has_function_privilege(role_name,rpc,'execute'),'private diagnosis helper denied')
FROM unnest(ARRAY['anon','authenticated','service_role']) role_name
CROSS JOIN unnest(ARRAY['public._bound_guest_diagnosis_taxon(uuid)',
    'public._retain_bound_guest_diagnosis_source()',
    'public._clean_bound_guest_diagnosis_projection()']) rpc;
SELECT is((SELECT expires_at-succeeded_at FROM public.guest_identification_sources
    WHERE photo_id=(SELECT id FROM bound_initial_photo)),interval '7 days',
    'normal guest settlement atomically retains source for seven days');
SELECT is((SELECT succeeded_at FROM public.guest_identification_sources
    WHERE photo_id=(SELECT id FROM bound_initial_photo)),
    (SELECT updated_at FROM public.analysis_jobs WHERE id=(SELECT id FROM bound_initial_job)),
    'retention uses original settlement time');

-- Keep TAP assertions outside rolled-back fixture mutations so the final
-- no_plan count includes every emitted assertion.
CREATE FUNCTION pg_temp.diagnosis_draft_probe(
    p_setup TEXT, p_query TEXT DEFAULT 'SELECT pg_temp.diagnosis_draft()::text'
) RETURNS TEXT LANGUAGE plpgsql AS $$
DECLARE
    v_result TEXT;
BEGIN
    BEGIN
        EXECUTE p_setup;
        BEGIN
            EXECUTE p_query INTO v_result;
        EXCEPTION WHEN OTHERS THEN
            v_result := SQLSTATE || ':' || SQLERRM;
        END;
        RAISE EXCEPTION 'ROLLBACK_FIXTURE' USING ERRCODE='ZX001';
    EXCEPTION WHEN SQLSTATE 'ZX001' THEN
        NULL;
    END;
    RETURN v_result;
END;
$$;

DELETE FROM public.guest_identification_sources WHERE photo_id=(SELECT id FROM bound_initial_photo);
SELECT is(pg_temp.diagnosis_draft_probe($setup$
    UPDATE public.diagnosis_job_runtime SET projection=NULL WHERE job_id=(SELECT id FROM bound_initial_job);
    UPDATE public.diagnosis_job_runtime SET projection=(SELECT body FROM bound_worker_projection)
    WHERE job_id=(SELECT id FROM bound_initial_job);
$setup$, $query$
    SELECT EXISTS(SELECT 1 FROM public.guest_identification_sources
        WHERE photo_id=(SELECT id FROM bound_initial_photo))::text
$query$),'true','projection publication creates retention');
SELECT ok(NOT EXISTS(SELECT 1 FROM public.guest_identification_sources
    WHERE photo_id=(SELECT id FROM bound_initial_photo)),'rollback removes newly retained source');
UPDATE public.diagnosis_job_runtime SET projection=NULL WHERE job_id=(SELECT id FROM bound_initial_job);
UPDATE public.diagnosis_job_runtime SET projection=(SELECT body FROM bound_worker_projection)
WHERE job_id=(SELECT id FROM bound_initial_job);
SELECT is((SELECT count(*) FROM public.guest_identification_sources
    WHERE photo_id=(SELECT id FROM bound_initial_photo)),1::bigint,'restored projection retains original source');

CREATE FUNCTION pg_temp.diagnosis_draft_result_denials()
RETURNS SETOF TEXT LANGUAGE plpgsql AS $$
DECLARE
    v_projection JSONB := (SELECT body FROM bound_worker_projection);
    v_bad JSONB;
BEGIN
    FOR v_bad IN SELECT value FROM jsonb_array_elements(jsonb_build_array(
        v_projection || '{"identification_status":"unknown"}'::jsonb,
        v_projection || '{"identification_status":"genus_only"}'::jsonb,
        v_projection || '{"plant_id":"unsupported_species"}'::jsonb,
        v_projection || jsonb_build_object('plant_id',gen_random_uuid()),
        v_projection || '{"analysis_receipt":"invalid"}'::jsonb,
        v_projection || jsonb_build_object('analysis_id',gen_random_uuid()),
        v_projection || '{"mode":"identification"}'::jsonb
    )) LOOP
        DELETE FROM public.guest_identification_sources WHERE photo_id=(SELECT id FROM bound_initial_photo);
        UPDATE public.diagnosis_job_runtime SET projection=v_bad WHERE job_id=(SELECT id FROM bound_initial_job);
        RETURN NEXT ok(NOT EXISTS(SELECT 1 FROM public.guest_identification_sources
            WHERE photo_id=(SELECT id FROM bound_initial_photo)),'unsupported projection cannot retain source');
        RETURN NEXT throws_ok('SELECT pg_temp.diagnosis_draft()',
            'P0002','DIAGNOSIS_SOURCE_NOT_FOUND','unsupported projection cannot create a draft');
    END LOOP;
    UPDATE public.diagnosis_job_runtime SET projection=v_projection WHERE job_id=(SELECT id FROM bound_initial_job);
END;
$$;
SELECT * FROM pg_temp.diagnosis_draft_result_denials();
SELECT throws_ok($q$SELECT pg_temp.diagnosis_draft(p_owner=>'16320000-0000-4000-8000-000000000082')$q$,
    '42501','INSTALLATION_CREDENTIAL_MISMATCH','foreign owner cannot use installation credential');
SELECT throws_ok($q$SELECT pg_temp.diagnosis_draft(p_credential=>repeat('9',64))$q$,
    'P0002','DIAGNOSIS_SOURCE_NOT_FOUND','same owner different linked installation cannot save this job');
SELECT throws_ok($q$SELECT pg_temp.diagnosis_draft(p_job=>(SELECT id FROM guest_job))$q$,
    'P0002','DIAGNOSIS_SOURCE_NOT_FOUND','identification job cannot enter diagnosis draft path');
SELECT throws_ok($q$SELECT pg_temp.diagnosis_draft(p_operation=>NULL)$q$,
    '22023','INVALID_DRAFT_INPUT','operation ID is mandatory');
SELECT is(pg_temp.diagnosis_draft_probe($setup$
DELETE FROM public.guest_identification_sources WHERE photo_id=(SELECT id FROM bound_initial_photo);
$setup$),'P0002:DRAFT_EXPIRED','missing retained source fails closed');
SELECT is(pg_temp.diagnosis_draft_probe($setup$
    UPDATE public.guest_identification_sources SET expires_at=clock_timestamp()
    WHERE photo_id=(SELECT id FROM bound_initial_photo);
$setup$),'P0002:DRAFT_EXPIRED','source expiry boundary rejects save');
SELECT is(pg_temp.diagnosis_draft_probe($setup$
    UPDATE public.guest_identification_sources SET expires_at=clock_timestamp()
    WHERE photo_id=(SELECT id FROM bound_initial_photo);
$setup$, $query$
    SELECT EXISTS(SELECT 1 FROM jsonb_array_elements(public.read_guest_photo_cleanup(NULL)) x
        WHERE x->>'source_photo_id'=(SELECT id::text FROM bound_initial_photo))::text
$query$),'true','expired diagnosis source uses existing cleanup queue');
SELECT is(pg_temp.diagnosis_draft_probe($setup$
    UPDATE public.guest_identification_sources SET expires_at=clock_timestamp()
    WHERE photo_id=(SELECT id FROM bound_initial_photo);
    SELECT public.finish_guest_source_cleanup((SELECT id FROM bound_initial_photo));
$setup$, $query$
    SELECT (projection IS NULL)::text FROM public.diagnosis_job_runtime
    WHERE job_id=(SELECT id FROM bound_initial_job)
$query$),'true','source cleanup removes initial diagnosis projection');

SELECT is(pg_temp.diagnosis_draft_probe($setup$
UPDATE public.analysis_jobs SET payload_hash=repeat('f',64) WHERE id=(SELECT id FROM bound_initial_job);
UPDATE public.operation_receipts SET payload_hash=repeat('f',64)
WHERE owner_id='16320000-0000-4000-8000-000000000081'
  AND operation_id='16320000-0000-4000-8000-000000000084';
$setup$),'P0002:DIAGNOSIS_SOURCE_NOT_FOUND','matching forged admission digests still fail recomputation');
SELECT is(pg_temp.diagnosis_draft_probe($setup$
UPDATE public.guest_identification_sources SET storage_cleaned_at=clock_timestamp()
WHERE photo_id=(SELECT id FROM bound_initial_photo);
$setup$),'P0002:DRAFT_EXPIRED','cleaned source cannot save');
SELECT is(pg_temp.diagnosis_draft_probe($setup$
UPDATE public.photo_assets SET deleted_at=clock_timestamp() WHERE id=(SELECT id FROM bound_initial_photo);
$setup$),'P0002:DIAGNOSIS_SOURCE_NOT_FOUND','deleted photo cannot save');
SELECT is(pg_temp.diagnosis_draft_probe($setup$
UPDATE public.photo_assets SET original_key='foreign/path' WHERE id=(SELECT id FROM bound_initial_photo);
$setup$),'P0002:DIAGNOSIS_SOURCE_NOT_FOUND','foreign storage key cannot save');
SELECT is(pg_temp.diagnosis_draft_probe($setup$
UPDATE public.installation_access SET starter_diagnosis_consumed=false
WHERE id=(SELECT id FROM bound_initial_install);
$setup$),'P0002:DIAGNOSIS_SOURCE_NOT_FOUND','unconsumed separate installation starter cannot save');

CREATE TEMP TABLE diagnosis_draft_receipt AS SELECT pg_temp.diagnosis_draft() body;
SELECT is(pg_temp.diagnosis_draft(),(SELECT body FROM diagnosis_draft_receipt),'draft replay returns exact receipt');
SELECT is((SELECT body - ARRAY['draft_id','expires_at'] FROM diagnosis_draft_receipt),'{}'::jsonb,
    'draft receipt retains existing shape');
SELECT ok((SELECT d.intent='problem' AND d.add_method='scan'
    AND d.confirmed_taxon_id=s.taxon_id AND d.analysis_job_id=j.id
    AND d.photo_id=j.photo_ids[1] AND d.installation_id=j.quota_installation_id
    AND d.source_storage_key=a.original_key AND a.draft_id=d.id AND j.draft_id=d.id
    AND d.expires_at=g.expires_at
    FROM public.guest_drafts d JOIN public.analysis_jobs j ON j.id=d.analysis_job_id
    JOIN public.photo_assets a ON a.id=d.photo_id
    JOIN public.guest_identification_sources g ON g.photo_id=a.id
    JOIN public.diagnosis_job_runtime r ON r.job_id=j.id
    JOIN public.catalogue_release_species s ON s.release_id=r.catalogue_release_id
      AND s.plant_id='monstera_deliciosa'
    WHERE d.id=(SELECT (body->>'draft_id')::uuid FROM diagnosis_draft_receipt)),
    'one problem draft binds canonical published taxon, exact job, photo, installation and original TTL');
SELECT throws_ok($q$SELECT pg_temp.diagnosis_draft(p_operation=>gen_random_uuid())$q$,
    '23505','DRAFT_ALREADY_EXISTS','second operation cannot create another draft');
SELECT throws_ok($q$SELECT pg_temp.diagnosis_draft(p_job=>gen_random_uuid())$q$,
    '23505','IDEMPOTENCY_CONFLICT','changed job conflicts before side effects');
SELECT throws_ok($q$SELECT pg_temp.diagnosis_draft(p_credential=>repeat('9',64))$q$,
    '23505','IDEMPOTENCY_CONFLICT','changed installation cannot replay');
SELECT throws_ok($q$SELECT public.create_guest_photo_draft(
    '16320000-0000-4000-8000-000000000081','16320000-0000-4000-8000-000000000091',
    (SELECT id FROM bound_initial_job),(SELECT taxon_id FROM public.catalogue_release_species
    WHERE plant_id='monstera_deliciosa' LIMIT 1),repeat('8',64))$q$,
    '23505','IDEMPOTENCY_CONFLICT','old identification API cannot replay diagnosis operation');
SELECT is(pg_temp.diagnosis_draft_probe($setup$
UPDATE public.installation_access SET linked_owner_ids='{}' WHERE id=(SELECT id FROM bound_initial_install);
$setup$),'42501:INSTALLATION_CREDENTIAL_MISMATCH','replay requires current installation link');
SELECT is(pg_temp.diagnosis_draft_probe($setup$
UPDATE public.profiles SET anonymous=false WHERE id='16320000-0000-4000-8000-000000000081';
$setup$),'42501:ACTIVE_GUEST_REQUIRED','replay requires active guest');
SELECT is(pg_temp.diagnosis_draft_probe($setup$
UPDATE public.guest_drafts SET deleted_at=clock_timestamp()
WHERE id=(SELECT (body->>'draft_id')::uuid FROM diagnosis_draft_receipt);
$setup$),'P0002:DRAFT_EXPIRED','deleted draft cannot replay');
SELECT is(pg_temp.diagnosis_draft_probe($setup$
UPDATE public.guest_drafts SET claimed_at=clock_timestamp()
WHERE id=(SELECT (body->>'draft_id')::uuid FROM diagnosis_draft_receipt);
$setup$),'P0002:DRAFT_EXPIRED','claimed draft cannot replay');
SELECT is(pg_temp.diagnosis_draft_probe($setup$
    UPDATE public.guest_identification_sources SET expires_at=clock_timestamp()
    WHERE photo_id=(SELECT id FROM bound_initial_photo);
$setup$),'P0002:DRAFT_EXPIRED','expired draft cannot replay');
SELECT is(pg_temp.diagnosis_draft_probe($setup$
    UPDATE public.guest_identification_sources SET expires_at=clock_timestamp()
    WHERE photo_id=(SELECT id FROM bound_initial_photo);
    UPDATE public.guest_drafts SET expires_at=clock_timestamp()
    WHERE id=(SELECT (body->>'draft_id')::uuid FROM diagnosis_draft_receipt);
    SELECT public.finish_guest_photo_cleanup((SELECT (body->>'draft_id')::uuid FROM diagnosis_draft_receipt));
$setup$, $query$
    SELECT (projection IS NULL)::text FROM public.diagnosis_job_runtime
    WHERE job_id=(SELECT id FROM bound_initial_job)
$query$),'true','draft cleanup removes initial diagnosis projection');
SELECT * FROM finish();
ROLLBACK;
