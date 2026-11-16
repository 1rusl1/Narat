BEGIN;
-- Use a fresh owner, real upload/job APIs and an independent private object fixture.
SELECT no_plan();
CREATE TEMP TABLE diag_save_owner AS SELECT '16310000-0000-4000-8000-0000000000d1'::uuid id;
INSERT INTO public.profiles(id,anonymous) SELECT id,false FROM diag_save_owner;
CREATE TEMP TABLE diag_save_photo AS SELECT (public.create_diagnosis_upload(
    (SELECT id FROM diag_save_owner),gen_random_uuid(),'image/jpeg',4,repeat('b',64))->>'photo_asset_id')::uuid id;
SELECT public.mark_diagnosis_upload_ready(
    (SELECT id FROM diag_save_owner),(SELECT id FROM diag_save_photo),repeat('b',64));
CREATE TEMP TABLE diag_save_job AS SELECT (public.create_diagnosis_job(
    (SELECT id FROM diag_save_owner),gen_random_uuid(),(SELECT id FROM diag_save_photo),NULL,
    'en',true)->'job'->>'job_id')::uuid id;
CREATE TEMP TABLE diag_save_lease AS SELECT (public.lease_diagnosis_job(
    (SELECT id FROM diag_save_job))->>'lease_token')::uuid id;
SELECT public.start_diagnosis_provider((SELECT id FROM diag_save_job),(SELECT id FROM diag_save_lease));
SELECT public.finish_diagnosis_job(
    (SELECT id FROM diag_save_job),(SELECT id FROM diag_save_lease),
    (SELECT jsonb_build_object('mode','diagnosis','job_id',j.id,'kb_release_id',kb_release_id,
        'identification_status','identified','plant_id','monstera_deliciosa','diagnosis_status','healthy')
     FROM public.analysis_jobs j JOIN diag_save_job f ON f.id=j.id),false,NULL);
CREATE TEMP TABLE diag_save_input AS SELECT gen_random_uuid() op,jsonb_build_object(
    'creation_source','catalogue','creation_intent','problem','add_method','scan',
    'plant_id','monstera_deliciosa','diagnosis_job_id',(SELECT id FROM diag_save_job)
) payload;
SELECT throws_ok($q$SELECT public.execute_plant_create_command(
    (SELECT id FROM diag_save_owner),(SELECT op FROM diag_save_input),(SELECT payload FROM diag_save_input))$q$,
    'P0002','diagnosis_source_not_found','successful diagnosis requires the private object to survive');
INSERT INTO storage.objects(bucket_id,name) SELECT 'analysis-inputs',original_key
FROM public.photo_assets WHERE id=(SELECT id FROM diag_save_photo);
SELECT throws_ok($q$SELECT public.execute_plant_create_command(
    '16300000-0000-4000-8000-000000000001',gen_random_uuid(),(SELECT payload FROM diag_save_input))$q$,
    'P0002','diagnosis_source_not_found','foreign owner cannot bind the photo');
SELECT throws_ok($q$SELECT public.execute_plant_create_command((SELECT id FROM diag_save_owner),gen_random_uuid(),
    (SELECT payload || '{"plant_id":"aloe_vera"}'::jsonb FROM diag_save_input))$q$,
    'P0002','diagnosis_source_not_found','diagnosis cannot authorize a different species');
SELECT throws_ok($q$SELECT public.execute_plant_create_command((SELECT id FROM diag_save_owner),gen_random_uuid(),
    (SELECT payload || jsonb_build_object('photo_id',gen_random_uuid()) FROM diag_save_input))$q$,
    '22023','invalid_diagnosis_save','client cannot substitute a raw photo ID');
CREATE TEMP TABLE diag_save_result AS SELECT public.execute_plant_create_command(
    (SELECT id FROM diag_save_owner),op,payload) body FROM diag_save_input;
SELECT is((SELECT (body->>'photo_id')::uuid FROM diag_save_result),
    (SELECT id FROM diag_save_photo),'receipt identifies the original diagnosis photo');
SELECT is((SELECT main_photo_id FROM public.plants WHERE id=(SELECT (body->>'plant_id')::uuid FROM diag_save_result)),
    (SELECT id FROM diag_save_photo),'plant is linked to the original photo');
SELECT is((SELECT plant_id FROM public.photo_assets WHERE id=(SELECT id FROM diag_save_photo)),
    (SELECT (body->>'plant_id')::uuid FROM diag_save_result),'photo reverse link matches');
SELECT is(public.execute_plant_create_command((SELECT id FROM diag_save_owner),
    (SELECT op FROM diag_save_input),(SELECT payload FROM diag_save_input)),
    (SELECT body FROM diag_save_result),'exact retry returns the same receipt');
SELECT throws_ok($q$SELECT public.execute_plant_create_command((SELECT id FROM diag_save_owner),
    gen_random_uuid(),(SELECT payload FROM diag_save_input))$q$,
    '23505','diagnosis_photo_already_attached','new operation cannot duplicate the same photo-backed plant');
SELECT is((SELECT count(*) FROM public.plants WHERE owner_id=(SELECT id FROM diag_save_owner)),1::bigint,
    'one plant after retry and rejected duplicate');
SELECT * FROM finish();
ROLLBACK;
