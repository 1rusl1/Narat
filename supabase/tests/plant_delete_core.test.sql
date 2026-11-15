BEGIN;
SELECT no_plan();

CREATE TEMP TABLE deletion_fixture AS
SELECT gen_random_uuid() AS owner, gen_random_uuid() AS other, gen_random_uuid() AS guest,
    gen_random_uuid() AS plant, gen_random_uuid() AS sibling, gen_random_uuid() AS foreign_plant,
    gen_random_uuid() AS operation, gen_random_uuid() AS undo_operation, gen_random_uuid() AS fail_operation;
INSERT INTO public.profiles(id,anonymous)
SELECT owner,false FROM deletion_fixture UNION ALL SELECT other,false FROM deletion_fixture
UNION ALL SELECT guest,true FROM deletion_fixture;
INSERT INTO public.plants(id,owner_id,creation_source,display_name)
SELECT item.id,item.owner,'identification','Deletion fixture'
FROM deletion_fixture,LATERAL (VALUES (plant,owner),(sibling,owner),(foreign_plant,other)) item(id,owner);
INSERT INTO public.condition_snapshots(owner_id,plant_id,version)
SELECT owner,plant,1 FROM deletion_fixture;
INSERT INTO public.basic_care_memberships(owner_id,plant_id,enabled,free_slot)
SELECT owner,plant,true,1 FROM deletion_fixture
UNION ALL SELECT owner,sibling,true,2 FROM deletion_fixture;
CREATE TEMP TABLE deletion_asset AS
SELECT owner, plant, (public.create_diagnosis_upload(owner,gen_random_uuid(),
    'image/jpeg',4,repeat('a',64))->>'photo_asset_id')::uuid AS id
FROM deletion_fixture;
SELECT public.mark_diagnosis_upload_ready(owner,id,repeat('a',64)) FROM deletion_asset;
UPDATE public.photo_assets a SET plant_id=f.plant FROM deletion_asset f WHERE a.id=f.id;
UPDATE public.plants p SET main_photo_id=f.id FROM deletion_asset f WHERE p.id=f.plant;

CREATE TEMP TABLE old_fact AS
SELECT owner,plant,(public.execute_manual_care_command(owner,gen_random_uuid(),plant,'care.record',
    '{"action_code":"water","occurred_at":"2025-10-01T00:00:00Z","timezone":"UTC"}')->>'entry_id')::uuid AS id
FROM deletion_fixture;
SELECT public.execute_manual_care_command(f.owner,f.undo_operation,f.plant,'care.undo',jsonb_build_object('entry_id',e.id))
FROM deletion_fixture f CROSS JOIN old_fact e;

CREATE FUNCTION pg_temp.remove_plant(target text DEFAULT 'plant', op uuid DEFAULT NULL, subject text DEFAULT 'owner')
RETURNS jsonb LANGUAGE sql AS $$
    SELECT public.execute_plant_delete_command(
        CASE subject WHEN 'guest' THEN guest WHEN 'other' THEN other ELSE owner END,
        coalesce(op, operation),
        CASE target WHEN 'sibling' THEN sibling WHEN 'foreign' THEN foreign_plant ELSE plant END, '{}'::jsonb)
    FROM deletion_fixture
$$;

SELECT ok(has_function_privilege('service_role','public.execute_plant_delete_command(uuid,uuid,uuid,jsonb)','EXECUTE')
    AND NOT has_function_privilege('authenticated','public.execute_plant_delete_command(uuid,uuid,uuid,jsonb)','EXECUTE'),
    'deletion RPC is service-only');
SELECT throws_ok($q$SELECT pg_temp.remove_plant(subject=>'guest')$q$,
    '42501','ACTIVE_PERMANENT_OWNER_REQUIRED','anonymous profile cannot delete');
SELECT throws_ok($q$SELECT pg_temp.remove_plant('foreign')$q$,
    'P0002','PLANT_NOT_FOUND','foreign card is hidden');
SELECT throws_ok($q$SELECT public.execute_plant_delete_command(owner,operation,gen_random_uuid(),'{}')
    FROM deletion_fixture$q$, 'P0002','PLANT_NOT_FOUND','missing card gives the same error');
SELECT throws_ok($q$SELECT public.execute_plant_delete_command(owner,operation,plant,'{"photo_id":null}')
    FROM deletion_fixture$q$, '22023','INVALID_PLANT_DELETE_INPUT','payload must be an empty object');
SELECT throws_ok($q$SELECT pg_temp.remove_plant(op=>undo_operation) FROM deletion_fixture$q$,
    '23505','IDEMPOTENCY_CONFLICT','receipt namespace is shared with other owner commands');

CREATE TEMP TABLE deletion_before AS SELECT public.advance_owner_watermark(owner) AS ts FROM deletion_fixture;
CREATE FUNCTION pg_temp.fail_deletion_queue() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN RAISE EXCEPTION 'FIXTURE_QUEUE_FAILURE'; END;
$$;
CREATE TRIGGER fixture_queue_failure BEFORE INSERT ON public.deletion_jobs
FOR EACH ROW EXECUTE FUNCTION pg_temp.fail_deletion_queue();
SELECT throws_ok($q$SELECT pg_temp.remove_plant()$q$,'P0001','FIXTURE_QUEUE_FAILURE','queue failure rolls back the command');
DROP TRIGGER fixture_queue_failure ON public.deletion_jobs;
SELECT ok((SELECT p.deleted_at IS NULL AND q.updated_at=b.ts
    FROM deletion_fixture f JOIN public.plants p ON p.id=f.plant JOIN public.profiles q ON q.id=f.owner
    CROSS JOIN deletion_before b)
    AND EXISTS (SELECT 1 FROM deletion_fixture f WHERE public.read_owned_plant_photo(f.owner,f.plant) IS NOT NULL)
    AND NOT EXISTS (SELECT 1 FROM public.operation_receipts r JOIN deletion_fixture f ON r.owner_id=f.owner AND r.operation_id=f.operation),
    'rollback leaves plant, private photo, watermark and receipt unchanged');

CREATE TEMP TABLE deletion_result AS SELECT pg_temp.remove_plant() AS body;
SELECT is((SELECT body->>'state' FROM deletion_result),'deleting','receipt reports accepted revocation');
SELECT is((SELECT count(*) FROM public.deletion_jobs j JOIN deletion_fixture f
    ON j.owner_id=f.owner AND j.target_id=f.plant AND j.operation_id=f.operation
    CROSS JOIN deletion_result r WHERE j.id=(r.body->>'deletion_job_id')::uuid
      AND j.scope='plant' AND j.state='purge_storage'),1::bigint,'one cleanup job belongs to the exact plant');
SELECT is(pg_temp.remove_plant(), (SELECT body FROM deletion_result), 'exact replay returns the same receipt');
UPDATE public.deletion_jobs SET state='completed' WHERE id=(SELECT (body->>'deletion_job_id')::uuid FROM deletion_result);
SELECT is(pg_temp.remove_plant(), (SELECT body FROM deletion_result), 'queue completion preserves the original receipt');
SELECT throws_ok($q$SELECT pg_temp.remove_plant('sibling')$q$,
    '23505','IDEMPOTENCY_CONFLICT','same operation on another card conflicts');
SELECT throws_ok($q$SELECT pg_temp.remove_plant(op=>gen_random_uuid())$q$,
    '23505','PLANT_ALREADY_DELETED','new operation cannot enqueue the same tombstone again');
SELECT is((SELECT public.read_owned_plant_photo(owner,plant) FROM deletion_fixture),
    NULL::jsonb,'owner photo resolver is closed after the tombstone');

CREATE TEMP TABLE deletion_delta AS
SELECT item FROM deletion_fixture CROSS JOIN deletion_before CROSS JOIN deletion_result,
LATERAL jsonb_array_elements(public.fetch_sync_delta(owner,ts,(body->>'watermark')::timestamptz)->'changes') item;
SELECT is((SELECT array_agg(item->>'entity_type' ORDER BY item->>'entity_type') FROM deletion_delta),
    ARRAY['basic_care_memberships','care_entries','care_reversals','condition_snapshots','photo_assets','plants'],
    'owner delta contains all fixture tombstones and no sibling changes');
SELECT ok((SELECT bool_and(item->'data'='null'::jsonb AND item->>'updated_at'=item->>'deleted_at'
        AND (item->>'updated_at')::timestamptz=(body->>'watermark')::timestamptz)
    FROM deletion_delta CROSS JOIN deletion_result),'all tombstones share the exact receipt watermark');
SELECT ok((SELECT p.deleted_at IS NULL AND m.enabled AND m.deleted_at IS NULL AND m.free_slot=2
    FROM deletion_fixture f JOIN public.plants p ON p.id=f.sibling
    JOIN public.basic_care_memberships m ON m.plant_id=p.id)
    AND (SELECT p.deleted_at IS NULL FROM deletion_fixture f JOIN public.plants p ON p.id=f.foreign_plant),
    'sibling and foreign cards are untouched');

SELECT * FROM finish();
ROLLBACK;
