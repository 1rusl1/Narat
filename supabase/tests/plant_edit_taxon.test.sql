BEGIN;
SELECT no_plan();

CREATE TEMP TABLE taxon_edit AS
SELECT gen_random_uuid() AS owner, gen_random_uuid() AS stranger,
    gen_random_uuid() AS plant, gen_random_uuid() AS snapshot,
    gen_random_uuid() AS operation, gen_random_uuid() AS plan, gen_random_uuid() AS rule,
    s.taxon_id AS target, s.plant_id AS slug, s.release_id
FROM public.catalogue_release_species s JOIN public.catalogue_releases r ON r.id=s.release_id
WHERE r.state='published' AND s.status='published' AND s.rank='species' LIMIT 1;
INSERT INTO public.profiles(id,anonymous)
SELECT owner,false FROM taxon_edit UNION ALL SELECT stranger,false FROM taxon_edit;
INSERT INTO public.plants(id,owner_id,creation_source,personal_name)
SELECT plant,owner,'identification','Fixture name' FROM taxon_edit;
INSERT INTO public.condition_snapshots(id,owner_id,plant_id,light_code,light_source,light_confirmed,watering_code)
SELECT snapshot,owner,plant,'low','camera_estimate',true,'weekly' FROM taxon_edit;
UPDATE public.plants p SET current_condition_snapshot_id=f.snapshot FROM taxon_edit f WHERE p.id=f.plant;

INSERT INTO public.basic_care_memberships(owner_id,plant_id) SELECT owner,plant FROM taxon_edit;
INSERT INTO public.care_plans(id,operation_id,owner_id,plant_id,locale,plan_kind,access_tier,
    source_kind,snapshot_id,kb_release_id,context_revision,full_body)
SELECT plan,gen_random_uuid(),owner,plant,'en','routine','basic','catalogue',snapshot,k.id,1,'{}'
FROM taxon_edit CROSS JOIN public.kb_releases k WHERE k.state='published';
INSERT INTO public.task_rules(id,plan_id,owner_id,plant_id,access_class,action_code,condition_code,interval_days)
SELECT rule,plan,owner,plant,'basic_care','check_soil','check_soil_first',7 FROM taxon_edit;
INSERT INTO public.care_tasks(owner_id,plant_id,rule_id,occurrence_key,action_code,due_local_date)
SELECT owner,plant,rule,'future','check_soil',current_date+1 FROM taxon_edit;

CREATE TEMP TABLE taxon_photo AS
SELECT (public.create_diagnosis_upload(owner,gen_random_uuid(),'image/jpeg',4,repeat('a',64))
    ->>'photo_asset_id')::uuid AS id FROM taxon_edit;
SELECT public.mark_diagnosis_upload_ready(owner,id,repeat('a',64)) FROM taxon_edit CROSS JOIN taxon_photo;
CREATE TEMP TABLE taxon_job AS
SELECT (public.create_plant_diagnosis_job(owner,gen_random_uuid(),id,NULL,'en',true,plant)#>>'{job,job_id}')::uuid AS id
FROM taxon_edit CROSS JOIN taxon_photo;
SELECT public.finalize_analysis_quota(id,'succeeded',false,clock_timestamp()) FROM taxon_job;
UPDATE public.diagnosis_job_runtime r SET projection='{"fixture":"original diagnosis"}'
FROM taxon_job j WHERE r.job_id=j.id;
UPDATE public.photo_assets a SET plant_id=f.plant FROM taxon_edit f,taxon_photo h WHERE a.id=h.id;
UPDATE public.plants p SET main_photo_id=h.id FROM taxon_edit f,taxon_photo h WHERE p.id=f.plant;

CREATE TEMP TABLE taxon_before AS
SELECT to_jsonb(s) AS original,public.read_diagnosis_job(f.owner,j.id) AS diagnosis
FROM taxon_edit f JOIN public.condition_snapshots s ON s.id=f.snapshot CROSS JOIN taxon_job j;
CREATE FUNCTION pg_temp.change_taxon(payload JSONB, fresh BOOLEAN DEFAULT false, foreign_owner BOOLEAN DEFAULT false)
RETURNS jsonb LANGUAGE sql AS $$
    SELECT public.execute_plant_edit_command(CASE WHEN foreign_owner THEN stranger ELSE owner END,
        CASE WHEN fresh THEN gen_random_uuid() ELSE operation END,plant,payload)
    FROM taxon_edit
$$;

SELECT throws_ok('SELECT pg_temp.change_taxon(jsonb_build_object(''taxon_id'',target),false,true) FROM taxon_edit',
    'P0002','PLANT_NOT_FOUND','foreign owner cannot change the species');
SELECT throws_ok('SELECT pg_temp.change_taxon(jsonb_build_object(''taxon_id'',gen_random_uuid()))',
    '22023','TAXON_NOT_PUBLISHED','unknown taxon is rejected');
SELECT throws_ok($q$SELECT pg_temp.change_taxon('{"taxon_id":"invalid"}')$q$,
    '22023','INVALID_PLANT_EDIT_INPUT','malformed UUID is rejected');
UPDATE public.catalogue_release_species s SET rank='genus'
FROM taxon_edit f WHERE s.taxon_id=f.target AND s.release_id=f.release_id;
SELECT throws_ok('SELECT pg_temp.change_taxon(jsonb_build_object(''taxon_id'',target)) FROM taxon_edit',
    '22023','TAXON_NOT_PUBLISHED','published genus is rejected');
UPDATE public.catalogue_release_species s SET rank='species' FROM taxon_edit f
WHERE s.taxon_id=f.target AND s.release_id=f.release_id;

CREATE TEMP TABLE taxon_receipt AS
SELECT pg_temp.change_taxon(jsonb_build_object('taxon_id',target)) AS body FROM taxon_edit;
SELECT ok((SELECT p.taxon_id=f.target AND p.plant_id=f.slug AND p.personal_name='Fixture name'
    AND p.revision=2 AND p.care_revision=2 AND p.current_condition_snapshot_id<>f.snapshot
    FROM taxon_edit f JOIN public.plants p ON p.id=f.plant),'canonical taxon and slug change in the same revision');
SELECT ok((SELECT s.version=2 AND s.light_code='low' AND s.light_source='camera_estimate' AND s.watering_code='weekly'
    FROM taxon_receipt r JOIN public.condition_snapshots s ON s.id=(r.body->>'condition_snapshot_id')::uuid),
    'species edit keeps condition values in the new snapshot');
SELECT is((SELECT to_jsonb(s) FROM public.condition_snapshots s JOIN taxon_edit f ON s.id=f.snapshot),
    (SELECT original FROM taxon_before),'original snapshot is unchanged');
SELECT is((SELECT public.read_diagnosis_job(f.owner,j.id) FROM taxon_edit f CROSS JOIN taxon_job j),
    (SELECT diagnosis FROM taxon_before),'historical diagnosis remains readable');
SELECT ok((SELECT public.read_owned_plant_photo(f.owner,f.plant)->>'photo_asset_id'=h.id::text
    FROM taxon_edit f CROSS JOIN taxon_photo h),'private plant photo remains readable');
SELECT public.reconcile_owner_basic_care(owner) FROM taxon_edit;
SELECT ok((SELECT r.rule_state='paused' AND NOT t.reminder_eligible
    FROM taxon_edit f JOIN public.task_rules r ON r.id=f.rule JOIN public.care_tasks t ON t.rule_id=r.id),
    'old rule and reminder stay paused after reconciliation');
SELECT is((SELECT pg_temp.change_taxon(jsonb_build_object('taxon_id',upper(target::text))) FROM taxon_edit),
    (SELECT body FROM taxon_receipt),'canonical UUID replay returns the original receipt');
SELECT is((SELECT pg_temp.change_taxon(jsonb_build_object('taxon_id',target),true) FROM taxon_edit),
    (SELECT body FROM taxon_receipt),'same species is a no-op');

SELECT * FROM finish();
ROLLBACK;
