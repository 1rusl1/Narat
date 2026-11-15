BEGIN;
SELECT no_plan();

CREATE TEMP TABLE edit_case AS
SELECT gen_random_uuid() AS owner,gen_random_uuid() AS other,gen_random_uuid() AS guest,
    gen_random_uuid() AS plant,gen_random_uuid() AS sibling,gen_random_uuid() AS operation;
INSERT INTO public.profiles(id,anonymous)
SELECT owner,false FROM edit_case UNION ALL SELECT other,false FROM edit_case
UNION ALL SELECT guest,true FROM edit_case;
INSERT INTO public.plants(id,owner_id,creation_source,personal_name,care_revision)
SELECT id,owner,'identification','Original name',3
FROM edit_case CROSS JOIN LATERAL (VALUES (plant),(sibling)) p(id);
INSERT INTO public.condition_snapshots(owner_id,plant_id,version)
SELECT owner,plant,1 FROM edit_case;
UPDATE public.plants p SET current_condition_snapshot_id=s.id
FROM public.condition_snapshots s,edit_case f WHERE p.id=f.plant AND s.plant_id=f.plant;

CREATE TEMP TABLE edit_photo AS
SELECT owner,plant,(public.create_diagnosis_upload(owner,gen_random_uuid(),
    'image/jpeg',4,repeat('a',64))->>'photo_asset_id')::uuid AS id
FROM edit_case;
SELECT public.mark_diagnosis_upload_ready(owner,id,repeat('a',64)) FROM edit_photo;
CREATE TEMP TABLE edit_job AS
SELECT owner,(public.create_plant_diagnosis_job(owner,gen_random_uuid(),id,NULL,'en',true,plant)
    #>>'{job,job_id}')::uuid AS id FROM edit_photo;
SELECT public.finalize_analysis_quota(id,'succeeded',false,clock_timestamp()) FROM edit_job;
UPDATE public.diagnosis_job_runtime r SET projection='{"fixture":"original diagnosis"}'
FROM edit_job j WHERE r.job_id=j.id;
UPDATE public.photo_assets a SET plant_id=f.plant FROM edit_photo f WHERE a.id=f.id;
UPDATE public.plants p SET main_photo_id=f.id FROM edit_photo f WHERE p.id=f.plant;

SELECT public.execute_manual_care_command(owner,gen_random_uuid(),plant,'care.record',
    '{"action_code":"water","occurred_at":"2025-10-01T00:00:00Z","timezone":"UTC"}') FROM edit_case;
CREATE TEMP TABLE edit_before AS
SELECT p.main_photo_id,p.current_condition_snapshot_id,p.care_revision,p.updated_at,
    public.read_diagnosis_job(f.owner,j.id) AS diagnosis
FROM edit_case f JOIN public.plants p ON p.id=f.plant JOIN edit_job j ON j.owner=f.owner;

CREATE FUNCTION pg_temp.rename_plant(
    payload JSONB DEFAULT '{"personal_name":"  Kitchen Monstera  "}', fresh BOOLEAN DEFAULT false,
    subject TEXT DEFAULT 'owner', target TEXT DEFAULT 'plant'
) RETURNS JSONB LANGUAGE sql AS $$
    SELECT public.execute_plant_edit_command(
        CASE subject WHEN 'other' THEN other WHEN 'guest' THEN guest ELSE owner END,
        CASE WHEN fresh THEN gen_random_uuid() ELSE operation END,
        CASE WHEN target='sibling' THEN sibling ELSE plant END,payload)
    FROM edit_case
$$;

SELECT ok(has_function_privilege('service_role','public.execute_plant_edit_command(uuid,uuid,uuid,jsonb)','EXECUTE')
    AND NOT has_function_privilege('authenticated','public.execute_plant_edit_command(uuid,uuid,uuid,jsonb)','EXECUTE'),
    'plant edit RPC is service-only');
SELECT throws_ok($q$SELECT pg_temp.rename_plant(subject=>'other')$q$,
    'P0002','PLANT_NOT_FOUND','foreign card returns not found');
SELECT throws_ok($q$SELECT pg_temp.rename_plant(subject=>'guest')$q$,
    '42501','ACTIVE_PERMANENT_OWNER_REQUIRED','anonymous account cannot edit');
SELECT throws_ok($q$SELECT pg_temp.rename_plant('{"personal_name":"Name","conditions":{}}')$q$,
    '22023','INVALID_PLANT_EDIT_INPUT','unsupported mixed edit has no partial effect');
SELECT throws_ok($q$SELECT pg_temp.rename_plant('{"personal_name":"\t\n"}')$q$,
    '22023','INVALID_PLANT_EDIT_INPUT','blank name is rejected');
SELECT throws_ok($q$SELECT pg_temp.rename_plant(jsonb_build_object('personal_name',repeat('🌿',121)))$q$,
    '22023','INVALID_PLANT_EDIT_INPUT','length is measured in characters');

CREATE TEMP TABLE edit_since AS SELECT public.advance_owner_watermark(owner) AS ts FROM edit_case;
CREATE TEMP TABLE edit_result AS SELECT pg_temp.rename_plant() AS body;
SELECT ok((SELECT p.personal_name='Kitchen Monstera' AND p.display_name=p.personal_name
    AND p.revision=2 AND p.care_revision=b.care_revision AND p.updated_at=(r.body->>'watermark')::timestamptz
    AND p.main_photo_id=b.main_photo_id AND p.current_condition_snapshot_id=b.current_condition_snapshot_id
    FROM edit_case f JOIN public.plants p ON p.id=f.plant CROSS JOIN edit_before b CROSS JOIN edit_result r),
    'rename changes the name and revision while retaining care and photo pointers');
SELECT is((SELECT body->>'condition_snapshot_id' FROM edit_result),
    (SELECT current_condition_snapshot_id::text FROM edit_before),'receipt retains the original snapshot');
SELECT is(pg_temp.rename_plant(),(SELECT body FROM edit_result),'exact repeat returns the stored receipt');
SELECT throws_ok($q$SELECT pg_temp.rename_plant('{"personal_name":"Kitchen Monstera"}')$q$,
    '23505','IDEMPOTENCY_CONFLICT','same UUID with changed input conflicts even if trimmed name matches');
SELECT throws_ok($q$SELECT pg_temp.rename_plant(target=>'sibling')$q$,
    '23505','IDEMPOTENCY_CONFLICT','operation ID cannot move to another plant');
SELECT is(pg_temp.rename_plant('{"personal_name":"Kitchen Monstera"}',true),
    (SELECT body FROM edit_result),'no-op preserves revision and watermark');
SELECT is((SELECT personal_name FROM public.plants p JOIN edit_case f ON p.id=f.sibling),
    'Original name','sibling is unchanged');
SELECT ok((SELECT public.read_owned_plant_photo(owner,plant)->>'photo_asset_id'=id::text FROM edit_photo),
    'main photo is still readable');
SELECT is((SELECT public.read_diagnosis_job(owner,id) FROM edit_job),
    (SELECT diagnosis FROM edit_before),'original diagnosis projection is unchanged');
SELECT is((SELECT count(*) FROM public.analysis_jobs j JOIN edit_case f ON f.owner=j.owner_id),
    1::bigint,'rename does not enqueue analysis');
SELECT ok((SELECT count(*)=1 AND bool_and(e.action_code='water' AND e.state='active'
    AND e.occurred_local_date='2025-10-01' AND e.timezone='UTC')
    FROM public.care_entries e JOIN edit_case f ON e.plant_id=f.plant),'care history is retained');
SELECT is((SELECT count(*) FROM public.condition_snapshots s JOIN edit_case f ON s.plant_id=f.plant),
    1::bigint,'rename adds no condition snapshot');
SELECT is((SELECT jsonb_array_length(public.fetch_sync_delta(f.owner,b.ts,(r.body->>'watermark')::timestamptz)->'changes')
    FROM edit_case f CROSS JOIN edit_since b CROSS JOIN edit_result r),
    1,'delta through the receipt contains just the updated plant');
SELECT public.execute_plant_delete_command(owner,gen_random_uuid(),plant,'{}') FROM edit_case;
SELECT throws_ok($q$SELECT pg_temp.rename_plant(fresh=>true)$q$,
    'P0002','PLANT_NOT_FOUND','new edit cannot reopen a tombstone');
SELECT is(pg_temp.rename_plant(),(SELECT body FROM edit_result),'old receipt remains replayable after deletion');
SELECT is((SELECT public.execute_plant_edit_command(owner,gen_random_uuid(),sibling,'{"personal_name":"Side"}')
    ->'condition_snapshot_id' FROM edit_case),'null'::jsonb,'snapshot can be null for a catalogue-style card');

SELECT * FROM finish();
ROLLBACK;
