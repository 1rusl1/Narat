BEGIN;
SELECT no_plan();

CREATE TEMP TABLE revoke_case AS
SELECT gen_random_uuid() AS owner, gen_random_uuid() AS stranger, gen_random_uuid() AS plant,
    gen_random_uuid() AS sibling, gen_random_uuid() AS operation, gen_random_uuid() AS control,
    gen_random_uuid() AS observation;
INSERT INTO public.profiles(id,anonymous)
SELECT owner,false FROM revoke_case UNION ALL SELECT stranger,false FROM revoke_case;
UPDATE public.profiles p SET starter_diagnosis_consumed=true FROM revoke_case f WHERE p.id=f.owner;
INSERT INTO public.plants(id,owner_id,creation_source,display_name)
SELECT id,owner,'identification','Revocation fixture'
FROM revoke_case CROSS JOIN LATERAL (VALUES (plant),(sibling)) plants(id);

CREATE TEMP TABLE revoke_assets AS
SELECT label,(public.create_diagnosis_upload(owner,gen_random_uuid(),'image/jpeg',4,repeat('a',64))
    ->>'photo_asset_id')::uuid AS id
FROM revoke_case CROSS JOIN (VALUES ('main'),('bound'),('sibling')) asset(label);
SELECT public.mark_diagnosis_upload_ready(owner,id,repeat('a',64)) FROM revoke_case CROSS JOIN revoke_assets;
UPDATE public.photo_assets a SET plant_id=f.plant FROM revoke_case f,revoke_assets x
WHERE a.id=x.id AND x.label='main';
UPDATE public.plants p SET main_photo_id=x.id FROM revoke_case f,revoke_assets x
WHERE p.id=f.plant AND x.label='main';

CREATE TEMP TABLE revoke_jobs AS
SELECT label, gen_random_uuid() AS op FROM (VALUES ('bound'),('sibling')) job(label);
ALTER TABLE revoke_jobs ADD COLUMN receipt JSONB;
UPDATE revoke_jobs j SET receipt=public.create_plant_diagnosis_job(owner,j.op,a.id,NULL,'en',true,
    CASE j.label WHEN 'bound' THEN plant ELSE sibling END)
FROM revoke_case CROSS JOIN revoke_assets a WHERE a.label=j.label;
CREATE TEMP TABLE revoke_lease AS
SELECT public.lease_diagnosis_job((receipt#>>'{job,job_id}')::uuid) AS body FROM revoke_jobs WHERE label='bound';
SELECT is((SELECT body->>'job_id' FROM revoke_lease),(SELECT receipt#>>'{job,job_id}' FROM revoke_jobs WHERE label='bound'),
    'bound job has a lease before revocation');

-- Older identification jobs can be connected only through the saved main photo.
CREATE TEMP TABLE saved_identification AS
SELECT owner, id AS photo, gen_random_uuid() AS op FROM revoke_case CROSS JOIN revoke_assets WHERE label='main';
ALTER TABLE saved_identification ADD COLUMN receipt JSONB;
UPDATE saved_identification SET receipt=public.create_photo_analysis_job(owner,op,photo,NULL,'en',true,'identification');

INSERT INTO public.first_aid_followups(id,owner_id,plant_id,origin_analysis_id,kb_release_id,
    action_code,first_action_snapshot,check_policy_snapshot,state)
SELECT control,owner,plant,gen_random_uuid(),k.id,'check_soil','{}','{"fixture":true}','active'
FROM revoke_case CROSS JOIN public.kb_releases k WHERE k.state='published';
CREATE TEMP TABLE revoke_diary AS
SELECT (public.create_first_aid_photo_upload(owner,gen_random_uuid(),plant,control,'image/jpeg',4,repeat('b',64))
    ->>'photo_asset_id')::uuid AS id FROM revoke_case;
SELECT public.mark_first_aid_photo_ready(owner,id,repeat('b',64)) FROM revoke_case CROSS JOIN revoke_diary;
UPDATE public.photo_assets a SET plant_id=f.plant FROM revoke_case f,revoke_diary x WHERE a.id=x.id;
UPDATE public.first_aid_followups x SET state='completed' FROM revoke_case f WHERE x.id=f.control;
INSERT INTO public.care_observations(id,owner_id,plant_id,first_aid_control_id,photo_id,status_code,operation_id)
SELECT observation,owner,plant,control,id,'unknown',gen_random_uuid() FROM revoke_case CROSS JOIN revoke_diary;

SELECT ok((SELECT public.read_owned_plant_photo(owner,plant) IS NOT NULL
    AND public.read_owned_first_aid_observation_photo(owner,observation) IS NOT NULL
    AND public.read_plant_care_profile(owner,plant) IS NOT NULL FROM revoke_case),'owner can read both photos and care before deletion');
SELECT ok((SELECT public.read_owned_plant_photo(stranger,plant) IS NULL
    AND public.read_owned_first_aid_observation_photo(stranger,observation) IS NULL FROM revoke_case),
    'foreign owner cannot resolve either photo');
SELECT ok((SELECT public.read_diagnosis_job(owner,(receipt#>>'{job,job_id}')::uuid) IS NOT NULL
    FROM revoke_case CROSS JOIN revoke_jobs WHERE label='bound'),'owner sees bound job before deletion');
SELECT ok((SELECT public.read_diagnosis_job(owner,(receipt#>>'{job,job_id}')::uuid) IS NOT NULL
    FROM saved_identification),'owner sees the original saved identification');

SELECT public.execute_plant_delete_command(owner,operation,plant,'{}') FROM revoke_case;
SELECT ok((SELECT public.read_owned_plant_photo(owner,plant) IS NULL
    AND public.read_owned_first_aid_observation_photo(owner,observation) IS NULL
    AND public.read_plant_care_profile(owner,plant) IS NULL FROM revoke_case),'owner photo and care readers revoke access');
SELECT ok((SELECT public.read_diagnosis_job(owner,(receipt#>>'{job,job_id}')::uuid) IS NULL
    FROM revoke_case CROSS JOIN revoke_jobs WHERE label='bound'),'bound job status is hidden');
SELECT ok((SELECT public.read_diagnosis_job(owner,(receipt#>>'{job,job_id}')::uuid) IS NOT NULL
    FROM revoke_case CROSS JOIN revoke_jobs WHERE label='sibling'),'sibling job remains available');
SELECT ok((SELECT public.read_diagnosis_job(owner,(receipt#>>'{job,job_id}')::uuid) IS NULL
    FROM saved_identification),'identification linked by main photo is hidden');
SELECT throws_ok($q$SELECT public.create_photo_analysis_job(owner,op,photo,NULL,'en',true,'identification')
    FROM saved_identification$q$, 'P0002','PHOTO_NOT_READY','old identification replay cannot reopen the saved photo');
SELECT is((SELECT public.read_diagnosis_upload(owner,id) FROM revoke_case CROSS JOIN revoke_assets WHERE label='bound'),
    NULL::jsonb,'standalone upload lookup cannot reopen the bound job photo');
SELECT throws_ok($q$SELECT public.create_plant_diagnosis_job(owner,op,id,NULL,'en',true,plant)
    FROM revoke_case CROSS JOIN revoke_jobs JOIN revoke_assets USING(label) WHERE label='bound'$q$,
    'P0002','PLANT_NOT_FOUND','exact old diagnosis replay is revoked before dispatch');
SELECT throws_ok($q$SELECT public.create_diagnosis_job(owner,gen_random_uuid(),id,NULL,'en',true)
    FROM revoke_case CROSS JOIN revoke_assets WHERE label='bound'$q$,
    'P0002','PHOTO_NOT_READY','standalone analysis cannot reuse the revoked photo');
SELECT is((SELECT public.start_diagnosis_provider((body->>'job_id')::uuid,(body->>'lease_token')::uuid)->>'allowed'
    FROM revoke_lease),'false','pre-existing lease cannot start a provider');
SELECT is((SELECT j.quota_state FROM public.analysis_jobs j JOIN revoke_lease r ON j.id=(r.body->>'job_id')::uuid),
    'released','deletion settles the undispatched reservation exactly once');

GRANT SELECT ON public.plants,public.photo_assets,public.analysis_jobs,public.care_observations TO authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT owner::text FROM revoke_case),true);
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*) FROM public.plants),1::bigint,'direct owner table sees only the sibling card');
SELECT is((SELECT count(*) FROM public.photo_assets),1::bigint,'direct owner table sees only the sibling photo');
SELECT is((SELECT count(*) FROM public.analysis_jobs),1::bigint,'direct owner table sees only the sibling job');
SELECT is((SELECT count(*) FROM public.care_observations),0::bigint,'direct owner table hides observation tombstone');
SELECT ok(NOT has_table_privilege('authenticated','public.owner_sync_entries','SELECT'),'raw sync view is service-only');
RESET ROLE;

SELECT * FROM finish();
ROLLBACK;
