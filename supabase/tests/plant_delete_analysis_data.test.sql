BEGIN;
SELECT no_plan();

CREATE TEMP TABLE data_case AS
SELECT gen_random_uuid() AS owner,gen_random_uuid() AS plant,gen_random_uuid() AS sibling,
    gen_random_uuid() AS operation;
INSERT INTO public.profiles(id,anonymous,starter_diagnosis_consumed)
SELECT owner,false,true FROM data_case;
INSERT INTO public.plants(id,owner_id,creation_source,display_name)
SELECT id,owner,'identification','Analysis purge fixture'
FROM data_case CROSS JOIN LATERAL (VALUES (plant),(sibling)) plants(id);

CREATE TEMP TABLE data_assets AS
SELECT label,(public.create_diagnosis_upload(owner,gen_random_uuid(),'image/jpeg',4,repeat('a',64))
    ->>'photo_asset_id')::uuid AS id
FROM data_case CROSS JOIN (VALUES ('saved'),('bound'),('sibling')) x(label);
SELECT public.mark_diagnosis_upload_ready(owner,id,repeat('a',64)) FROM data_case CROSS JOIN data_assets;
CREATE TEMP TABLE data_jobs AS
SELECT label, CASE label WHEN 'saved'
    THEN public.create_photo_analysis_job(owner,gen_random_uuid(),id,NULL,'en',true,'identification')
    ELSE public.create_plant_diagnosis_job(owner,gen_random_uuid(),id,NULL,'en',true,
        CASE label WHEN 'bound' THEN plant ELSE sibling END)
    END AS receipt
FROM data_case CROSS JOIN data_assets;
ALTER TABLE data_jobs ADD COLUMN id UUID;
UPDATE data_jobs SET id=(receipt#>>'{job,job_id}')::uuid;
SELECT public.finalize_analysis_quota(id,'succeeded',false,clock_timestamp()) FROM data_jobs;
UPDATE public.diagnosis_job_runtime r SET projection=jsonb_build_object('fixture',x.label)
FROM data_jobs x WHERE r.job_id=x.id;
UPDATE public.photo_assets a SET plant_id=c.plant
FROM data_case c,data_assets x WHERE a.id=x.id AND x.label='saved';
UPDATE public.diagnosis_upload_tickets SET expires_at=clock_timestamp()-interval '1 hour';
INSERT INTO storage.objects(bucket_id,name)
SELECT 'analysis-inputs',a.original_key FROM public.photo_assets a JOIN data_assets x ON x.id=a.id
WHERE x.label='bound';

CREATE TEMP TABLE data_delete AS
SELECT public.execute_plant_delete_command(owner,operation,plant,'{}') AS receipt FROM data_case;
ALTER TABLE data_delete ADD COLUMN id UUID;
UPDATE data_delete SET id=(receipt->>'deletion_job_id')::uuid;
CREATE TEMP TABLE data_sync AS
SELECT s.* FROM public.owner_sync_entries s JOIN data_case c ON s.owner_id=c.owner;
CREATE TEMP TABLE data_ledger AS
SELECT u.* FROM public.account_quota_usage u JOIN data_jobs j ON u.job_id=j.id;
CREATE TEMP TABLE data_original_jobs AS
SELECT a.* FROM public.analysis_jobs a JOIN data_jobs j ON a.id=j.id;
CREATE TEMP TABLE data_original_receipts AS
SELECT r.* FROM public.operation_receipts r JOIN data_case c ON r.owner_id=c.owner;

SELECT ok(NOT has_function_privilege('authenticated','public.purge_plant_deletion_analysis_data(uuid)','EXECUTE')
    AND has_function_privilege('service_role','public.purge_plant_deletion_analysis_data(uuid)','EXECUTE'),
    'projection purge is service-only');
SELECT is(public.purge_plant_deletion_analysis_data(gen_random_uuid()),NULL::jsonb,'unknown job returns no work');
SELECT is((SELECT public.purge_plant_deletion_analysis_data(id) FROM data_delete),
    '{"state":"pending","cleared":0}'::jsonb,'data cleanup waits for the Storage phase');
DELETE FROM storage.objects s USING public.photo_assets a,data_assets x
WHERE s.bucket_id='analysis-inputs' AND s.name=a.original_key AND a.id=x.id AND x.label='bound';
SELECT is((SELECT public.finish_plant_deletion_storage(id) FROM data_delete),'purge_data','Storage phase is verified');
INSERT INTO storage.objects(bucket_id,name)
SELECT 'analysis-inputs',a.original_key FROM public.photo_assets a JOIN data_assets x ON x.id=a.id
WHERE x.label='bound';
SELECT is((SELECT public.purge_plant_deletion_analysis_data(id) FROM data_delete),
    '{"state":"pending","cleared":0}'::jsonb,'late Storage object defers data cleanup');
DELETE FROM storage.objects s USING public.photo_assets a,data_assets x
WHERE s.bucket_id='analysis-inputs' AND s.name=a.original_key AND a.id=x.id AND x.label='bound';
UPDATE public.analysis_jobs a SET state='running'
FROM data_jobs j WHERE a.id=j.id AND j.label='bound';
SELECT is((SELECT public.purge_plant_deletion_analysis_data(id) FROM data_delete),
    '{"state":"pending","cleared":0}'::jsonb,'an unsettled analysis defers cleanup');
UPDATE public.analysis_jobs a SET state='succeeded'
FROM data_jobs j WHERE a.id=j.id AND j.label='bound';
SELECT is((SELECT public.purge_plant_deletion_analysis_data(id) FROM data_delete),
    '{"state":"cleared","cleared":2}'::jsonb,'only target diagnosis and saved identification are cleared');
SELECT ok((SELECT bool_and(projection IS NULL AND repeat_context IS NULL)
    FROM public.diagnosis_job_runtime r JOIN data_jobs j ON j.id=r.job_id WHERE j.label IN ('bound','saved')),
    'deleted jobs have no runtime projection or captured care context');
SELECT is((SELECT projection FROM public.diagnosis_job_runtime r JOIN data_jobs j ON j.id=r.job_id
    WHERE j.label='sibling'),'{"fixture":"sibling"}'::jsonb,'sibling projection is intact');
SELECT is((SELECT public.purge_plant_deletion_analysis_data(id) FROM data_delete),
    '{"state":"cleared","cleared":0}'::jsonb,'repeat after success is idempotent');
SELECT results_eq('SELECT u.* FROM public.account_quota_usage u JOIN data_jobs j ON u.job_id=j.id ORDER BY u.job_id',
    'SELECT * FROM data_ledger ORDER BY job_id','ledger is unchanged');
SELECT results_eq('SELECT a.* FROM public.analysis_jobs a JOIN data_jobs j ON a.id=j.id ORDER BY a.id',
    'SELECT * FROM data_original_jobs ORDER BY id','job identity, quota and media references are unchanged');
SELECT results_eq('SELECT s.* FROM public.owner_sync_entries s JOIN data_case c ON s.owner_id=c.owner ORDER BY s.entity_type,s.id',
    'SELECT * FROM data_sync ORDER BY entity_type,id','all sync tombstones and watermarks are unchanged');
SELECT results_eq('SELECT r.* FROM public.operation_receipts r JOIN data_case c ON r.owner_id=c.owner ORDER BY r.operation_id',
    'SELECT * FROM data_original_receipts ORDER BY operation_id','operation receipts are unchanged');
SELECT is((SELECT public.execute_plant_delete_command(owner,operation,plant,'{}') FROM data_case),
    (SELECT receipt FROM data_delete),'delete replay is exact after runtime cleanup');

SELECT * FROM finish();
ROLLBACK;
