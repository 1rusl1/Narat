BEGIN;
SELECT no_plan();

INSERT INTO public.profiles(id, anonymous) VALUES
    ('17100000-0000-4000-8000-000000000001', false),
    ('17100000-0000-4000-8000-000000000002', false),
    ('17100000-0000-4000-8000-000000000003', true);
CREATE TEMP TABLE taxon AS SELECT t.id FROM public.catalogue_taxa t
JOIN public.catalogue_releases r ON r.id=t.release_id
WHERE t.plant_id='monstera_deliciosa' AND t.status='published' AND r.state='published';
INSERT INTO public.plants(id, owner_id, taxon_id, plant_id, display_name)
VALUES ('17100000-0000-4000-8000-000000000011', '17100000-0000-4000-8000-000000000001',
    (SELECT id FROM taxon), 'monstera_deliciosa', 'Monstera');
INSERT INTO public.plants(id, owner_id, creation_source, add_method, display_name) VALUES
    ('17100000-0000-4000-8000-000000000012', '17100000-0000-4000-8000-000000000001', 'identification', 'scan', 'Unknown'),
    ('17100000-0000-4000-8000-000000000013', '17100000-0000-4000-8000-000000000003', 'identification', 'scan', 'Guest');

CREATE FUNCTION pg_temp.read_profile(
    owner UUID DEFAULT '17100000-0000-4000-8000-000000000001',
    plant UUID DEFAULT '17100000-0000-4000-8000-000000000011'
) RETURNS JSONB LANGUAGE SQL AS $$ SELECT public.read_plant_care_profile(owner, plant) $$;
SELECT ok(has_function_privilege('service_role','public.read_plant_care_profile(uuid,uuid)','execute')
    AND NOT has_function_privilege('authenticated','public.read_plant_care_profile(uuid,uuid)','execute')
    AND NOT has_function_privilege('anon','public.read_plant_care_profile(uuid,uuid)','execute'), 'Profile RPC is service-only');
SELECT is(pg_temp.read_profile()->'profile', 'null'::jsonb, 'Own Monstera has no profile before publication');
CREATE TEMP TABLE profile_fixture AS SELECT id AS kb_release_id,
    jsonb_build_object('schema_version','2.0','kb_release_id',id,'plant_id','monstera_deliciosa') AS body
FROM public.kb_releases WHERE state='published';
INSERT INTO public.care_profiles(kb_release_id, taxon_id, version, profile, field_evidence, state)
SELECT kb_release_id, (SELECT id FROM taxon), '1', body, '{}'::jsonb, 'draft' FROM profile_fixture;
SELECT is(pg_temp.read_profile()->'profile', 'null'::jsonb, 'Draft content remains unavailable');
UPDATE public.care_profiles SET state='published' WHERE kb_release_id=(SELECT kb_release_id FROM profile_fixture);
SELECT is(pg_temp.read_profile()->'profile', (SELECT body FROM profile_fixture), 'Owner sees the active published profile for the exact taxon');
SELECT is(pg_temp.read_profile()->>'plant_slug','monstera_deliciosa','RPC returns the server-side species');
SELECT is(pg_temp.read_profile()->>'kb_release_id',(SELECT kb_release_id::text FROM profile_fixture),'RPC returns the active release identity');
SELECT is(pg_temp.read_profile('17100000-0000-4000-8000-000000000002'), NULL::jsonb, 'Foreign owner cannot see the plant or its profile');
SELECT is(pg_temp.read_profile(plant=>'17100000-0000-4000-8000-000000000012')->'profile', 'null'::jsonb, 'Unknown plant has no recommendation');
SELECT is(pg_temp.read_profile('17100000-0000-4000-8000-000000000003','17100000-0000-4000-8000-000000000013'),
    NULL::jsonb,'Guest cannot read an owner profile');
UPDATE public.plants SET deleted_at=clock_timestamp() WHERE id='17100000-0000-4000-8000-000000000011';
SELECT is(pg_temp.read_profile(), NULL::jsonb, 'Deleted plant is unavailable');

SELECT * FROM finish();
ROLLBACK;
