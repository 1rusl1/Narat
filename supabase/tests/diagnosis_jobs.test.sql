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
CREATE TEMP TABLE identification_lease AS
    SELECT (public.lease_diagnosis_job((SELECT id FROM identification_job))->>'lease_token')::uuid id;
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
CREATE TEMP TABLE guest_draft_created AS SELECT public.create_guest_photo_draft(
    '16310000-0000-4000-8000-000000000061','16310000-0000-4000-8000-000000000064',(SELECT id FROM guest_job),
    (SELECT (body->>'taxon_id')::uuid FROM scan_input),repeat('e',64)) body;
CREATE TEMP TABLE guest_draft AS SELECT (body->>'draft_id')::uuid id FROM guest_draft_created;
SELECT is((SELECT expires_at-created_at FROM public.guest_drafts WHERE id=(SELECT id FROM guest_draft)),
    interval '7 days','guest draft lives exactly seven days');
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
SELECT * FROM finish();
ROLLBACK;
