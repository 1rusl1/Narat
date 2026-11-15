BEGIN;
SELECT no_plan();

CREATE TEMP TABLE job_phase_case AS
SELECT gen_random_uuid() AS owner,gen_random_uuid() AS plant,gen_random_uuid() AS operation;
INSERT INTO public.profiles(id,anonymous,starter_diagnosis_consumed)
SELECT owner,false,true FROM job_phase_case;
INSERT INTO public.plants(id,owner_id,creation_source,personal_name)
SELECT plant,owner,'identification','Combined purge fixture' FROM job_phase_case;
CREATE TEMP TABLE job_phase_photo AS
SELECT (public.create_diagnosis_upload(owner,gen_random_uuid(),'image/jpeg',4,repeat('a',64))
    ->>'photo_asset_id')::uuid AS id FROM job_phase_case;
SELECT public.mark_diagnosis_upload_ready(owner,id,repeat('a',64)) FROM job_phase_case CROSS JOIN job_phase_photo;
CREATE TEMP TABLE job_phase_analysis AS
SELECT (public.create_plant_diagnosis_job(owner,gen_random_uuid(),id,NULL,'en',true,plant)#>>'{job,job_id}')::uuid AS id
FROM job_phase_case CROSS JOIN job_phase_photo;
SELECT public.finalize_analysis_quota(id,'succeeded',false,clock_timestamp()) FROM job_phase_analysis;
UPDATE public.diagnosis_job_runtime r SET projection='{"fixture":true}' FROM job_phase_analysis j WHERE r.job_id=j.id;
UPDATE public.diagnosis_upload_tickets t SET expires_at=clock_timestamp()-interval '1 hour'
FROM job_phase_photo p WHERE p.id=t.photo_asset_id;

CREATE TEMP TABLE job_phase_delete AS
SELECT (public.execute_plant_delete_command(owner,operation,plant,'{}')->>'deletion_job_id')::uuid AS id
FROM job_phase_case;
SELECT ok(NOT has_function_privilege('authenticated','public.purge_plant_deletion_data(uuid)','EXECUTE')
    AND has_function_privilege('service_role','public.purge_plant_deletion_data(uuid)','EXECUTE'),
    'combined RPC is service-only');
SELECT is((SELECT public.purge_plant_deletion_data(id) FROM job_phase_delete),
    '{"state":"pending","cleared":0}'::jsonb,'combined cleanup waits for Storage');
SELECT is((SELECT public.finish_plant_deletion_storage(id) FROM job_phase_delete),'purge_data','Storage phase verified');
CREATE FUNCTION pg_temp.fail_text_purge() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'FIXTURE_TEXT_FAILURE';
END;
$$;
CREATE TRIGGER fixture_fail_text_purge BEFORE UPDATE OF personal_name ON public.plants
FOR EACH ROW EXECUTE FUNCTION pg_temp.fail_text_purge();
SELECT throws_ok('SELECT public.purge_plant_deletion_data(id) FROM job_phase_delete',
    'P0001','FIXTURE_TEXT_FAILURE','text failure rolls back the whole data pass');
SELECT is((SELECT projection FROM public.diagnosis_job_runtime r JOIN job_phase_analysis j ON j.id=r.job_id),
    '{"fixture":true}'::jsonb,'projection survived the rollback');
DROP TRIGGER fixture_fail_text_purge ON public.plants;

SELECT is((SELECT public.purge_plant_deletion_data(id) FROM job_phase_delete),
    '{"state":"cleared","cleared":2}'::jsonb,'one successful pass clears projection and plant text');
SELECT is((SELECT public.purge_plant_deletion_data(id) FROM job_phase_delete),
    '{"state":"cleared","cleared":0}'::jsonb,'combined cleanup replays idempotently');

SELECT * FROM finish();
ROLLBACK;
