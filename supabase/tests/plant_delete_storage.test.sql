BEGIN;
SELECT no_plan();

CREATE TEMP TABLE purge_case AS
SELECT gen_random_uuid() AS owner, gen_random_uuid() AS stranger,
    gen_random_uuid() AS plant, gen_random_uuid() AS sibling, gen_random_uuid() AS control;
INSERT INTO public.profiles(id,anonymous,starter_diagnosis_consumed)
SELECT owner,false,true FROM purge_case UNION ALL SELECT stranger,false,true FROM purge_case;
INSERT INTO public.plants(id,owner_id,creation_source,display_name)
SELECT id,owner,'identification','Storage purge fixture'
FROM purge_case CROSS JOIN LATERAL (VALUES (plant),(sibling)) plants(id);
INSERT INTO public.first_aid_followups(id,owner_id,plant_id,origin_analysis_id,kb_release_id,
    action_code,first_action_snapshot,check_policy_snapshot,state)
SELECT control,owner,plant,gen_random_uuid(),k.id,'check_soil','{}','{"fixture":true}','active'
FROM purge_case CROSS JOIN public.kb_releases k WHERE k.state='published';

CREATE TEMP TABLE purge_assets AS
SELECT label,(public.create_diagnosis_upload(owner,gen_random_uuid(),'image/jpeg',4,repeat('a',64))
    ->>'photo_asset_id')::uuid AS id
FROM purge_case CROSS JOIN (VALUES ('main'),('bound'),('sibling'),('shared'),('legacy'),('alias'),('duplicate')) x(label)
UNION ALL SELECT 'pending',(public.create_first_aid_photo_upload(
    owner,gen_random_uuid(),plant,control,'image/jpeg',4,repeat('b',64))->>'photo_asset_id')::uuid FROM purge_case
UNION ALL SELECT 'foreign',(public.create_diagnosis_upload(
    stranger,gen_random_uuid(),'image/jpeg',4,repeat('a',64))->>'photo_asset_id')::uuid FROM purge_case;
SELECT public.mark_diagnosis_upload_ready(owner,id,repeat('a',64))
FROM purge_case CROSS JOIN purge_assets WHERE label='bound';
CREATE TEMP TABLE purge_bound AS
SELECT (public.create_plant_diagnosis_job(owner,gen_random_uuid(),id,NULL,'en',true,plant)#>>'{job,job_id}')::uuid AS id
FROM purge_case CROSS JOIN purge_assets WHERE label='bound';
SELECT public.finalize_analysis_quota(id,'succeeded',false,clock_timestamp()) FROM purge_bound;
CREATE TEMP TABLE purge_usage AS
SELECT u.* FROM public.account_quota_usage u JOIN purge_bound b ON b.id=u.job_id;

UPDATE public.photo_assets a SET plant_id=c.plant FROM purge_case c,purge_assets x
WHERE a.id=x.id AND x.label IN ('main','shared','legacy','foreign','alias');
UPDATE public.plants p SET main_photo_id=x.id FROM purge_case c,purge_assets x
WHERE (p.id=c.plant AND x.label='main') OR (p.id=c.sibling AND x.label='shared');
UPDATE public.photo_assets a SET original_key='legacy/photo.jpg' FROM purge_assets x
WHERE a.id=x.id AND x.label='legacy';
UPDATE public.photo_assets a SET analysis_key=source.original_key
FROM public.photo_assets source,purge_assets x,purge_assets y
WHERE a.id=x.id AND x.label='duplicate' AND source.id=y.id AND y.label='alias';
UPDATE public.diagnosis_upload_tickets SET expires_at=clock_timestamp()-interval '1 hour';
INSERT INTO storage.objects(bucket_id,name)
SELECT 'analysis-inputs',a.original_key FROM public.photo_assets a JOIN purge_assets x ON x.id=a.id
WHERE x.label<>'pending';

SELECT ok(NOT has_function_privilege('authenticated','public.read_plant_deletion_storage(uuid)','EXECUTE')
    AND NOT has_function_privilege('anon','public.finish_plant_deletion_storage(uuid)','EXECUTE')
    AND has_function_privilege('service_role','public.finish_plant_deletion_storage(uuid)','EXECUTE'),
    'purge plan and finish are service-only');
INSERT INTO public.deletion_jobs(owner_id,scope,target_id,state,operation_id)
SELECT owner,'account',plant,'purge_storage',gen_random_uuid() FROM purge_case;
SELECT is((SELECT public.read_plant_deletion_storage(id) FROM public.deletion_jobs WHERE scope='account'),
    NULL::jsonb,'account job never returns a plant storage plan');
INSERT INTO public.deletion_jobs(owner_id,scope,target_id,state,operation_id)
SELECT owner,'plant',sibling,'purge_storage',gen_random_uuid() FROM purge_case;
SELECT is((SELECT public.finish_plant_deletion_storage(d.id) FROM public.deletion_jobs d
    JOIN purge_case c ON d.target_id=c.sibling),NULL::text,'live plant cannot be purged');
CREATE TEMP TABLE purge_job AS
SELECT (public.execute_plant_delete_command(owner,gen_random_uuid(),plant,'{}')->>'deletion_job_id')::uuid AS id
FROM purge_case;
SELECT is((SELECT public.read_plant_deletion_storage(id)->'photo_ids' FROM purge_job),
    (SELECT jsonb_agg(id ORDER BY id) FROM purge_assets WHERE label IN ('main','bound')),
    'plan selects exactly owned attached and plant-bound objects');
SELECT is((SELECT public.read_plant_deletion_storage(id)->>'blocked' FROM purge_job),'4',
    'shared, foreign, legacy and aliased paths are blocked');
SELECT is((SELECT public.read_plant_deletion_storage(id)->>'waiting' FROM purge_job),'1',
    'unattached first-aid upload waits for its ticket to expire');
SELECT is((SELECT public.finish_plant_deletion_storage(id) FROM purge_job),'purge_storage',
    'finish cannot advance while planned objects remain');

-- The Storage API is modeled here by deleting only fixture metadata, never by worker SQL.
DELETE FROM storage.objects s USING public.photo_assets a,purge_assets x
WHERE s.bucket_id='analysis-inputs' AND s.name=a.original_key AND a.id=x.id AND x.label IN ('main','bound');
SELECT is((SELECT public.finish_plant_deletion_storage(id) FROM purge_job),'purge_storage',
    'unsupported or shared objects keep the job pending');
-- Resolve the synthetic ambiguous relationships for the remainder of the scenario.
UPDATE public.plants p SET main_photo_id=NULL FROM purge_case c WHERE p.id=c.sibling;
UPDATE public.photo_assets a SET plant_id=NULL FROM purge_assets x
WHERE a.id=x.id AND x.label IN ('legacy','foreign','alias');
SELECT is((SELECT public.finish_plant_deletion_storage(id) FROM purge_job),'purge_storage',
    'an unexpired ticket alone keeps the job pending');
UPDATE public.first_aid_photo_upload_tickets SET expires_at=clock_timestamp()-interval '1 hour'
WHERE photo_asset_id=(SELECT id FROM purge_assets WHERE label='pending');
DELETE FROM storage.objects s USING public.photo_assets a,purge_assets x
WHERE s.bucket_id='analysis-inputs' AND s.name=a.original_key AND a.id=x.id AND x.label='shared';
SELECT is((SELECT public.finish_plant_deletion_storage(id) FROM purge_job),'purge_data',
    'absent private objects and expired tickets allow the next phase');
INSERT INTO storage.objects(bucket_id,name)
SELECT 'analysis-inputs',a.original_key FROM public.photo_assets a JOIN purge_assets x ON x.id=a.id WHERE x.label='pending';
SELECT is((SELECT public.read_plant_deletion_storage(id)->'photo_ids' FROM purge_job),
    (SELECT jsonb_build_array(id) FROM purge_assets WHERE label='pending'),
    'a late write reappears in the same job plan');
SELECT is((SELECT public.finish_plant_deletion_storage(id) FROM purge_job),'purge_storage',
    'a late object puts the job back in storage purge');
DELETE FROM storage.objects s USING public.photo_assets a,purge_assets x
WHERE s.bucket_id='analysis-inputs' AND s.name=a.original_key AND a.id=x.id AND x.label='pending';
SELECT is((SELECT public.finish_plant_deletion_storage(id) FROM purge_job),'purge_data',
    'retry verifies late object removal and advances again');
SELECT is((SELECT public.finish_plant_deletion_storage(id) FROM purge_job),'purge_data',
    'repeat after success has the same outcome');
SELECT is((SELECT quota_state FROM purge_usage),'consumed','fixture has a consumed monthly attempt');
SELECT results_eq('SELECT u.* FROM public.account_quota_usage u JOIN purge_bound b ON b.id=u.job_id',
    'SELECT * FROM purge_usage','storage purge leaves the ledger byte-for-byte unchanged');
SELECT is((SELECT count(*) FROM storage.objects),5::bigint,'sibling, foreign, legacy and aliased objects were preserved');
SELECT is((SELECT count(*) FROM public.photo_assets a JOIN purge_assets x ON x.id=a.id),
    9::bigint,'photo rows and tombstones remain available for the next phase');

-- One job may have more than one batch. Complete only after the final object is gone.
CREATE TEMP TABLE purge_many AS
SELECT gen_random_uuid() AS id FROM generate_series(1,21);
INSERT INTO public.photo_assets(id,owner_id,plant_id,purpose,original_key,analysis_key,content_hash)
SELECT id,owner,plant,'initial',owner::text||'/'||id::text,owner::text||'/'||id::text,repeat('a',64)
FROM purge_case CROSS JOIN purge_many;
INSERT INTO public.diagnosis_upload_tickets
SELECT id,'image/jpeg',4,clock_timestamp()-interval '1 hour' FROM purge_many;
INSERT INTO storage.objects(bucket_id,name)
SELECT 'analysis-inputs',a.original_key FROM public.photo_assets a JOIN purge_many p ON p.id=a.id;
INSERT INTO storage.objects(bucket_id,name)
SELECT 'another-bucket',a.original_key FROM public.photo_assets a JOIN purge_many p ON p.id=a.id;
SELECT is((SELECT jsonb_array_length(public.read_plant_deletion_storage(id)->'photo_ids') FROM purge_job),
    20,'one pass is limited to 20 private objects');
DELETE FROM storage.objects s USING public.photo_assets a
WHERE s.bucket_id='analysis-inputs' AND s.name=a.original_key AND a.id IN (
    SELECT jsonb_array_elements_text(public.read_plant_deletion_storage(id)->'photo_ids')::uuid FROM purge_job
);
SELECT is((SELECT public.finish_plant_deletion_storage(id) FROM purge_job),'purge_storage',
    'a partial batch cannot advance the job');
SELECT is((SELECT jsonb_array_length(public.read_plant_deletion_storage(id)->'photo_ids') FROM purge_job),
    1,'only the remaining object appears in the next pass');
DELETE FROM storage.objects s USING public.photo_assets a,purge_many p
WHERE s.bucket_id='analysis-inputs' AND s.name=a.original_key AND a.id=p.id;
SELECT is((SELECT public.finish_plant_deletion_storage(id) FROM purge_job),'purge_data',
    'identical keys in a separate bucket do not affect the result');
SELECT is((SELECT count(*) FROM storage.objects WHERE bucket_id='another-bucket'),21::bigint,
    'objects in another bucket are untouched');

SELECT * FROM finish();
ROLLBACK;
