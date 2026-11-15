BEGIN;
SELECT no_plan();

CREATE TEMP TABLE sweep_case AS
SELECT gen_random_uuid() AS owner,gen_random_uuid() AS live_plant;
INSERT INTO public.profiles(id,anonymous) SELECT owner,false FROM sweep_case;
INSERT INTO public.plants(id,owner_id,creation_source,personal_name)
SELECT live_plant,owner,'identification','Live fixture' FROM sweep_case;
CREATE TEMP TABLE sweep_jobs(id uuid);
DO $$
DECLARE
    v_owner UUID := (SELECT owner FROM sweep_case);
    v_plant UUID;
BEGIN
    FOR i IN 1..11 LOOP
        INSERT INTO public.plants(owner_id,creation_source,personal_name)
        VALUES(v_owner,'identification','Queue fixture') RETURNING id INTO v_plant;
        INSERT INTO sweep_jobs
        SELECT (public.execute_plant_delete_command(v_owner,gen_random_uuid(),v_plant,'{}')
            ->>'deletion_job_id')::uuid;
    END LOOP;
END;
$$;
UPDATE public.deletion_jobs SET state='purge_data'
WHERE id=(SELECT id FROM sweep_jobs ORDER BY id LIMIT 1);
INSERT INTO public.deletion_jobs(owner_id,scope,target_id,state,operation_id)
SELECT owner,'plant',live_plant,'purge_storage',gen_random_uuid() FROM sweep_case
UNION ALL
SELECT owner,'account',owner,'purge_storage',gen_random_uuid() FROM sweep_case;

SELECT ok(NOT has_function_privilege('authenticated','public.list_plant_deletion_jobs(uuid)','EXECUTE')
    AND has_function_privilege('service_role','public.list_plant_deletion_jobs(uuid)','EXECUTE'),
    'queue inventory is service-only');
SELECT is(public.list_plant_deletion_jobs(),
    (SELECT jsonb_agg(id ORDER BY id) FROM (SELECT id FROM sweep_jobs ORDER BY id LIMIT 10) page),
    'first page is bounded and includes purge_data for late writes without listing active plants or accounts');
SELECT is(public.list_plant_deletion_jobs((SELECT id FROM sweep_jobs ORDER BY id OFFSET 9 LIMIT 1)),
    (SELECT jsonb_agg(id) FROM (SELECT id FROM sweep_jobs ORDER BY id DESC LIMIT 1) page),
    'next page has the final job without repeating earlier jobs');
SELECT is(public.list_plant_deletion_jobs((SELECT id FROM sweep_jobs ORDER BY id DESC LIMIT 1)),
    '[]'::jsonb,'cursor after the last job yields an empty page');
SELECT * FROM finish();
ROLLBACK;
