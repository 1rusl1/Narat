BEGIN;
SELECT no_plan();

CREATE TEMP TABLE lease_case AS
SELECT gen_random_uuid() AS owner,gen_random_uuid() AS plant,gen_random_uuid() AS sibling,
    gen_random_uuid() AS operation;
INSERT INTO public.profiles(id,anonymous,starter_diagnosis_consumed)
SELECT owner,false,true FROM lease_case;
INSERT INTO public.plants(id,owner_id,creation_source,display_name)
SELECT id,owner,'identification','Expired lease fixture'
FROM lease_case CROSS JOIN LATERAL (VALUES (plant),(sibling)) plants(id);
CREATE TEMP TABLE lease_photos AS
SELECT label,(public.create_diagnosis_upload(owner,gen_random_uuid(),'image/jpeg',4,repeat('a',64))
    ->>'photo_asset_id')::uuid AS id
FROM lease_case CROSS JOIN (VALUES ('target'),('sibling')) x(label);
SELECT public.mark_diagnosis_upload_ready(owner,id,repeat('a',64)) FROM lease_case CROSS JOIN lease_photos;
CREATE TEMP TABLE lease_jobs AS
SELECT label,(public.create_plant_diagnosis_job(owner,gen_random_uuid(),id,NULL,'en',true,
    CASE label WHEN 'target' THEN plant ELSE sibling END)#>>'{job,job_id}')::uuid AS id
FROM lease_case CROSS JOIN lease_photos;
CREATE TEMP TABLE lease_token AS
SELECT id,(public.lease_diagnosis_job(id)->>'lease_token')::uuid AS token
FROM lease_jobs WHERE label='target';
SELECT is((SELECT public.start_diagnosis_provider(id,token)->>'allowed' FROM lease_token),'true',
    'provider start is recorded before deletion on the synthetic job');
UPDATE public.diagnosis_upload_tickets t SET expires_at=clock_timestamp()-interval '1 hour'
FROM lease_photos x WHERE t.photo_asset_id=x.id;
INSERT INTO storage.objects(bucket_id,name)
SELECT 'analysis-inputs',a.original_key FROM public.photo_assets a JOIN lease_photos x ON x.id=a.id;
CREATE TEMP TABLE lease_delete AS
SELECT (public.execute_plant_delete_command(owner,operation,plant,'{}')->>'deletion_job_id')::uuid AS id
FROM lease_case;
CREATE TEMP TABLE budget_before AS SELECT * FROM public.provider_daily_budget;
SELECT is((SELECT public.read_plant_deletion_storage(id)->>'waiting' FROM lease_delete),'1',
    'an unexpired started analysis waits before Storage remove');
SELECT is((SELECT public.finish_plant_deletion_storage(id) FROM lease_delete),'purge_storage',
    'active lease prevents storage completion');
SELECT is((SELECT a.quota_state FROM public.analysis_jobs a JOIN lease_token t ON a.id=t.id),'reserved',
    'active lease remains reserved');

UPDATE public.analysis_jobs a SET deadline_at=clock_timestamp()-interval '1 second'
FROM lease_jobs j WHERE a.id=j.id;
SELECT is((SELECT public.finish_plant_deletion_storage(id) FROM lease_delete),'purge_storage',
    'settling the expired lease does not claim the existing object is removed');
SELECT is((SELECT a.state FROM public.analysis_jobs a JOIN lease_token t ON a.id=t.id),'timed_out',
    'expired revoked job reaches the normal timeout state');
SELECT is((SELECT u.quota_state FROM public.account_quota_usage u JOIN lease_token t ON u.job_id=t.id),'released',
    'the original reservation is released once');
SELECT is((SELECT a.quota_state FROM public.analysis_jobs a JOIN lease_jobs j ON a.id=j.id
    WHERE j.label='sibling'),'reserved','expired sibling is outside this deletion');
SELECT is((SELECT public.finish_diagnosis_job(id,token,NULL,true,'FIXTURE')->>'already_finalized' FROM lease_token),
    'true','late worker settlement cannot reopen the job');
SELECT is((SELECT public.read_plant_deletion_storage(id)->'photo_ids' FROM lease_delete),
    (SELECT jsonb_build_array(id) FROM lease_photos WHERE label='target'),
    'only the target photo can be removed after timeout');
DELETE FROM storage.objects s USING public.photo_assets a,lease_photos x
WHERE s.bucket_id='analysis-inputs' AND s.name=a.original_key AND a.id=x.id AND x.label='target';
SELECT is((SELECT public.finish_plant_deletion_storage(id) FROM lease_delete),'purge_data',
    'same job advances after its bytes are gone');
SELECT results_eq('SELECT * FROM public.provider_daily_budget ORDER BY utc_date',
    'SELECT * FROM budget_before ORDER BY utc_date','timeout does not refund provider budget');

SELECT * FROM finish();
ROLLBACK;
