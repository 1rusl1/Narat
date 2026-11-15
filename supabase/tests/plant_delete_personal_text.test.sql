BEGIN;
SELECT no_plan();

CREATE TEMP TABLE personal_case AS
SELECT gen_random_uuid() AS owner,gen_random_uuid() AS plant,gen_random_uuid() AS sibling,
    gen_random_uuid() AS observation,gen_random_uuid() AS sibling_observation,gen_random_uuid() AS operation;
INSERT INTO public.profiles(id,anonymous) SELECT owner,false FROM personal_case;
INSERT INTO public.plants(id,owner_id,creation_source,personal_name,cultivar_label)
SELECT id,owner,'identification','Fixture personal name','Fixture cultivar'
FROM personal_case CROSS JOIN LATERAL (VALUES (plant),(sibling)) x(id);
INSERT INTO public.care_observations(id,owner_id,plant_id,status_code,note,operation_id)
SELECT id,owner,plant_id,'unknown','Fixture private note',gen_random_uuid()
FROM personal_case CROSS JOIN LATERAL (VALUES (observation,plant),(sibling_observation,sibling)) x(id,plant_id);
SELECT throws_ok($q$UPDATE public.plants SET personal_name=NULL,display_name=NULL
    WHERE id=(SELECT plant FROM personal_case)$q$, '23514',
    'new row for relation "plants" violates check constraint "plants_name_present_chk"',
    'live plant still requires a name');
SELECT ok(NOT has_function_privilege('authenticated','public.purge_plant_deletion_personal_text(uuid)','EXECUTE')
    AND has_function_privilege('service_role','public.purge_plant_deletion_personal_text(uuid)','EXECUTE'),
    'personal text purge is service-only');

CREATE TEMP TABLE personal_delete AS
SELECT public.execute_plant_delete_command(owner,operation,plant,'{}') AS receipt FROM personal_case;
ALTER TABLE personal_delete ADD COLUMN id UUID;
UPDATE personal_delete SET id=(receipt->>'deletion_job_id')::uuid;
CREATE TEMP TABLE personal_sync AS
SELECT s.* FROM public.owner_sync_entries s JOIN personal_case c ON s.owner_id=c.owner;
SELECT is((SELECT public.purge_plant_deletion_personal_text(id) FROM personal_delete),
    '{"state":"pending","cleared":0}'::jsonb,'personal text cleanup waits for Storage');
SELECT is((SELECT public.finish_plant_deletion_storage(id) FROM personal_delete),'purge_data',
    'empty Storage inventory advances the job');
SELECT is((SELECT public.purge_plant_deletion_personal_text(id) FROM personal_delete),
    '{"state":"cleared","cleared":2}'::jsonb,'deletion clears the private plant fields and note');
SELECT ok((SELECT p.personal_name IS NULL AND p.display_name IS NULL AND p.cultivar_label IS NULL
    AND p.deleted_at IS NOT NULL FROM public.plants p JOIN personal_case c ON p.id=c.plant),
    'plant tombstone keeps its identity with no private text');
SELECT is((SELECT note FROM public.care_observations o JOIN personal_case c ON o.id=c.observation),
    NULL::text,'target note is cleared');
SELECT is((SELECT note FROM public.care_observations o JOIN personal_case c ON o.id=c.sibling_observation),
    'Fixture private note','sibling note stays intact');
SELECT is((SELECT personal_name FROM public.plants p JOIN personal_case c ON p.id=c.sibling),
    'Fixture personal name','sibling name stays intact');
SELECT results_eq(
    'SELECT s.* FROM public.owner_sync_entries s JOIN personal_case c ON s.owner_id=c.owner ORDER BY s.entity_type,s.id',
    'SELECT * FROM personal_sync ORDER BY entity_type,id','all sync tombstones and watermarks stay intact');
SELECT is((SELECT public.purge_plant_deletion_personal_text(id) FROM personal_delete),
    '{"state":"cleared","cleared":0}'::jsonb,'repeat after success changes nothing');
SELECT is((SELECT public.execute_plant_delete_command(owner,operation,plant,'{}') FROM personal_case),
    (SELECT receipt FROM personal_delete),'original deletion receipt replays exactly');

SELECT * FROM finish();
ROLLBACK;
