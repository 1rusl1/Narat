-- Room retirement regression; local fixtures, not positive guest-claim acceptance.
BEGIN;
SELECT plan(66);
CREATE TEMP TABLE before_guards AS SELECT jsonb_build_object('profiles',(SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY to_jsonb(r)::text),'[]'::jsonb) FROM public.profiles r),'rooms',(SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY to_jsonb(r)::text),'[]'::jsonb) FROM public.rooms r),'plants',(SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY to_jsonb(r)::text),'[]'::jsonb) FROM public.plants r),'photo_assets',(SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY to_jsonb(r)::text),'[]'::jsonb) FROM public.photo_assets r),'condition_snapshots',(SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY to_jsonb(r)::text),'[]'::jsonb) FROM public.condition_snapshots r),'monthly_quotas',(SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY to_jsonb(r)::text),'[]'::jsonb) FROM public.monthly_quotas r),'operation_receipts',(SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY to_jsonb(r)::text),'[]'::jsonb) FROM public.operation_receipts r)) AS body;

SELECT throws_ok($query$SELECT public.execute_room_command('15800000-0000-4000-8000-000000000001','15800000-0000-4000-8000-000000000900','room.create','{"room_id": "15800000-0000-4000-8000-000000000101", "name": "New"}'::jsonb)$query$, '22023', 'ROOM_COMMAND_RETIRED', 'Reject new retired command room.create');

SELECT throws_ok($query$SELECT public.execute_room_command('15800000-0000-4000-8000-000000000001','15800000-0000-4000-8000-000000000901','room.rename','{"room_id": "15800000-0000-4000-8000-000000000101", "name": "New"}'::jsonb)$query$, '22023', 'ROOM_COMMAND_RETIRED', 'Reject new retired command room.rename');

SELECT throws_ok($query$SELECT public.execute_room_command('15800000-0000-4000-8000-000000000001','15800000-0000-4000-8000-000000000902','room.delete','{"room_id": "15800000-0000-4000-8000-000000000101", "name": "New"}'::jsonb)$query$, '22023', 'ROOM_COMMAND_RETIRED', 'Reject new retired command room.delete');

SELECT throws_ok($query$SELECT public.execute_room_command('15800000-0000-4000-8000-000000000001','15800000-0000-4000-8000-000000000903',NULL,'{"room_id": "15800000-0000-4000-8000-000000000101", "name": "New"}'::jsonb)$query$, '22023', 'ROOM_COMMAND_RETIRED', 'Reject new retired command None');

SELECT throws_ok($query$SELECT public.execute_room_command('15800000-0000-4000-8000-000000000001','15800000-0000-4000-8000-000000000904','room.unknown','{"room_id": "15800000-0000-4000-8000-000000000101", "name": "New"}'::jsonb)$query$, '22023', 'ROOM_COMMAND_RETIRED', 'Reject new retired command room.unknown');

SELECT throws_ok($query$SELECT public.execute_plant_create_command('15800000-0000-4000-8000-000000000001','15800000-0000-4000-8000-000000000925','{"room_id": null}'::jsonb)$query$, '22023', 'ROOM_FIELDS_RETIRED', 'Reject plant room key room_id, nested=False, null=True');

SELECT throws_ok($query$SELECT public.execute_plant_create_command('15800000-0000-4000-8000-000000000001','15800000-0000-4000-8000-000000000926','{"room_id": "retired"}'::jsonb)$query$, '22023', 'ROOM_FIELDS_RETIRED', 'Reject plant room key room_id, nested=False, null=False');

SELECT throws_ok($query$SELECT public.execute_plant_create_command('15800000-0000-4000-8000-000000000001','15800000-0000-4000-8000-000000000927','{"overrides": {"room_id": null}}'::jsonb)$query$, '22023', 'ROOM_FIELDS_RETIRED', 'Reject plant room key room_id, nested=True, null=True');

SELECT throws_ok($query$SELECT public.execute_plant_create_command('15800000-0000-4000-8000-000000000001','15800000-0000-4000-8000-000000000928','{"overrides": {"room_id": "retired"}}'::jsonb)$query$, '22023', 'ROOM_FIELDS_RETIRED', 'Reject plant room key room_id, nested=True, null=False');

SELECT throws_ok($query$SELECT public.prepare_guest_claim('15800000-0000-4000-8000-000000000001','15800000-0000-4000-8000-000000000969','15800000-0000-4000-8000-000000001001','fixture-proof','{"room_id": null}'::jsonb)$query$, '22023', 'ROOM_FIELDS_RETIRED', 'prepare_guest_claim rejects room_id before incompatible baseline');

SELECT throws_ok($query$SELECT public.commit_guest_claim('15800000-0000-4000-8000-000000000001','15800000-0000-4000-8000-000000000970','15800000-0000-4000-8000-000000001001','{"room_id": null}'::jsonb)$query$, '22023', 'ROOM_FIELDS_RETIRED', 'commit_guest_claim rejects room_id before incompatible baseline');

SELECT throws_ok($query$SELECT public.execute_plant_create_command('15800000-0000-4000-8000-000000000001','15800000-0000-4000-8000-000000000931','{"new_room_name": null}'::jsonb)$query$, '22023', 'ROOM_FIELDS_RETIRED', 'Reject plant room key new_room_name, nested=False, null=True');

SELECT throws_ok($query$SELECT public.execute_plant_create_command('15800000-0000-4000-8000-000000000001','15800000-0000-4000-8000-000000000932','{"new_room_name": "retired"}'::jsonb)$query$, '22023', 'ROOM_FIELDS_RETIRED', 'Reject plant room key new_room_name, nested=False, null=False');

SELECT throws_ok($query$SELECT public.execute_plant_create_command('15800000-0000-4000-8000-000000000001','15800000-0000-4000-8000-000000000933','{"overrides": {"new_room_name": null}}'::jsonb)$query$, '22023', 'ROOM_FIELDS_RETIRED', 'Reject plant room key new_room_name, nested=True, null=True');

SELECT throws_ok($query$SELECT public.execute_plant_create_command('15800000-0000-4000-8000-000000000001','15800000-0000-4000-8000-000000000934','{"overrides": {"new_room_name": "retired"}}'::jsonb)$query$, '22023', 'ROOM_FIELDS_RETIRED', 'Reject plant room key new_room_name, nested=True, null=False');

SELECT throws_ok($query$SELECT public.prepare_guest_claim('15800000-0000-4000-8000-000000000001','15800000-0000-4000-8000-000000000975','15800000-0000-4000-8000-000000001001','fixture-proof','{"new_room_name": null}'::jsonb)$query$, '22023', 'ROOM_FIELDS_RETIRED', 'prepare_guest_claim rejects new_room_name before incompatible baseline');

SELECT throws_ok($query$SELECT public.commit_guest_claim('15800000-0000-4000-8000-000000000001','15800000-0000-4000-8000-000000000976','15800000-0000-4000-8000-000000001001','{"new_room_name": null}'::jsonb)$query$, '22023', 'ROOM_FIELDS_RETIRED', 'commit_guest_claim rejects new_room_name before incompatible baseline');

SELECT throws_ok($query$SELECT public.execute_plant_create_command('15800000-0000-4000-8000-000000000001','15800000-0000-4000-8000-000000000937','{"create_room_name": null}'::jsonb)$query$, '22023', 'ROOM_FIELDS_RETIRED', 'Reject plant room key create_room_name, nested=False, null=True');

SELECT throws_ok($query$SELECT public.execute_plant_create_command('15800000-0000-4000-8000-000000000001','15800000-0000-4000-8000-000000000938','{"create_room_name": "retired"}'::jsonb)$query$, '22023', 'ROOM_FIELDS_RETIRED', 'Reject plant room key create_room_name, nested=False, null=False');

SELECT throws_ok($query$SELECT public.execute_plant_create_command('15800000-0000-4000-8000-000000000001','15800000-0000-4000-8000-000000000939','{"overrides": {"create_room_name": null}}'::jsonb)$query$, '22023', 'ROOM_FIELDS_RETIRED', 'Reject plant room key create_room_name, nested=True, null=True');

SELECT throws_ok($query$SELECT public.execute_plant_create_command('15800000-0000-4000-8000-000000000001','15800000-0000-4000-8000-000000000940','{"overrides": {"create_room_name": "retired"}}'::jsonb)$query$, '22023', 'ROOM_FIELDS_RETIRED', 'Reject plant room key create_room_name, nested=True, null=False');

SELECT throws_ok($query$SELECT public.prepare_guest_claim('15800000-0000-4000-8000-000000000001','15800000-0000-4000-8000-000000000981','15800000-0000-4000-8000-000000001001','fixture-proof','{"create_room_name": null}'::jsonb)$query$, '22023', 'ROOM_FIELDS_RETIRED', 'prepare_guest_claim rejects create_room_name before incompatible baseline');

SELECT throws_ok($query$SELECT public.commit_guest_claim('15800000-0000-4000-8000-000000000001','15800000-0000-4000-8000-000000000982','15800000-0000-4000-8000-000000001001','{"create_room_name": null}'::jsonb)$query$, '22023', 'ROOM_FIELDS_RETIRED', 'commit_guest_claim rejects create_room_name before incompatible baseline');

SELECT ok(jsonb_build_object('profiles',(SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY to_jsonb(r)::text),'[]'::jsonb) FROM public.profiles r),'rooms',(SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY to_jsonb(r)::text),'[]'::jsonb) FROM public.rooms r),'plants',(SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY to_jsonb(r)::text),'[]'::jsonb) FROM public.plants r),'photo_assets',(SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY to_jsonb(r)::text),'[]'::jsonb) FROM public.photo_assets r),'condition_snapshots',(SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY to_jsonb(r)::text),'[]'::jsonb) FROM public.condition_snapshots r),'monthly_quotas',(SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY to_jsonb(r)::text),'[]'::jsonb) FROM public.monthly_quotas r),'operation_receipts',(SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY to_jsonb(r)::text),'[]'::jsonb) FROM public.operation_receipts r)) = (SELECT body FROM before_guards), 'Rejected room writes preserve rows, owner watermarks, history and consumption');

SELECT ok(public.execute_room_command('15800000-0000-4000-8000-000000000001','15800000-0000-4000-8000-000000000801','room.create','{"name": "Historical"}'::jsonb)=(SELECT response_payload FROM public.operation_receipts WHERE owner_id='15800000-0000-4000-8000-000000000001' AND operation_id='15800000-0000-4000-8000-000000000801'), 'Exact completed room replay returns original historical response');

SELECT ok(jsonb_build_object('profiles',(SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY to_jsonb(r)::text),'[]'::jsonb) FROM public.profiles r),'rooms',(SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY to_jsonb(r)::text),'[]'::jsonb) FROM public.rooms r),'plants',(SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY to_jsonb(r)::text),'[]'::jsonb) FROM public.plants r),'photo_assets',(SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY to_jsonb(r)::text),'[]'::jsonb) FROM public.photo_assets r),'condition_snapshots',(SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY to_jsonb(r)::text),'[]'::jsonb) FROM public.condition_snapshots r),'monthly_quotas',(SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY to_jsonb(r)::text),'[]'::jsonb) FROM public.monthly_quotas r),'operation_receipts',(SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY to_jsonb(r)::text),'[]'::jsonb) FROM public.operation_receipts r)) = (SELECT body FROM before_guards), 'Completed room replay does not mutate watermark or any historical row');

SELECT throws_ok($query$SELECT public.execute_room_command('15800000-0000-4000-8000-000000000001','15800000-0000-4000-8000-000000000801','room.create','{"name":"Different"}'::jsonb)$query$, '23505', 'operation_payload_mismatch', 'Legacy operation ID with different room payload conflicts');

SELECT ok(public.execute_plant_create_command('15800000-0000-4000-8000-000000000001','15800000-0000-4000-8000-000000000802','{"plant_id": "fixture_rooms_plant", "room_id": "15800000-0000-4000-8000-000000000101"}'::jsonb)=(SELECT response_payload FROM public.operation_receipts WHERE owner_id='15800000-0000-4000-8000-000000000001' AND operation_id='15800000-0000-4000-8000-000000000802'), 'Exact legacy plant receipt remains readable before retired input guard');

SELECT ok(public.commit_guest_claim('15800000-0000-4000-8000-000000000001','15800000-0000-4000-8000-000000000803','15800000-0000-4000-8000-000000001001','{"room_id": "15800000-0000-4000-8000-000000000101"}'::jsonb)=(SELECT response_payload FROM public.operation_receipts WHERE owner_id='15800000-0000-4000-8000-000000000001' AND operation_id='15800000-0000-4000-8000-000000000803'), 'Exact legacy claim receipt remains readable without executing broken claim');

SELECT ok(has_function_privilege('service_role','public.execute_room_command(uuid,uuid,text,jsonb)','EXECUTE'), 'service_role execute permission preserved on execute_room_command');

SELECT ok(NOT has_function_privilege('anon','public.execute_room_command(uuid,uuid,text,jsonb)','EXECUTE'), 'anon execute permission preserved on execute_room_command');

SELECT ok(NOT has_function_privilege('authenticated','public.execute_room_command(uuid,uuid,text,jsonb)','EXECUTE'), 'authenticated execute permission preserved on execute_room_command');

SELECT ok((SELECT prosecdef AND proconfig @> ARRAY['search_path=public'] FROM pg_proc WHERE oid='public.execute_room_command(uuid,uuid,text,jsonb)'::regprocedure), 'Fixed SECURITY DEFINER/search_path on execute_room_command');

SELECT ok(has_function_privilege('service_role','public.execute_plant_create_command(uuid,uuid,jsonb,timestamptz)','EXECUTE'), 'service_role execute permission preserved on execute_plant_create_command');

SELECT ok(NOT has_function_privilege('anon','public.execute_plant_create_command(uuid,uuid,jsonb,timestamptz)','EXECUTE'), 'anon execute permission preserved on execute_plant_create_command');

SELECT ok(NOT has_function_privilege('authenticated','public.execute_plant_create_command(uuid,uuid,jsonb,timestamptz)','EXECUTE'), 'authenticated execute permission preserved on execute_plant_create_command');

SELECT ok((SELECT prosecdef AND proconfig @> ARRAY['search_path=public'] FROM pg_proc WHERE oid='public.execute_plant_create_command(uuid,uuid,jsonb,timestamptz)'::regprocedure), 'Fixed SECURITY DEFINER/search_path on execute_plant_create_command');

SELECT ok(has_function_privilege('service_role','public.prepare_guest_claim(uuid,uuid,uuid,text,jsonb,timestamptz)','EXECUTE'), 'service_role execute permission preserved on prepare_guest_claim');

SELECT ok(NOT has_function_privilege('anon','public.prepare_guest_claim(uuid,uuid,uuid,text,jsonb,timestamptz)','EXECUTE'), 'anon execute permission preserved on prepare_guest_claim');

SELECT ok(NOT has_function_privilege('authenticated','public.prepare_guest_claim(uuid,uuid,uuid,text,jsonb,timestamptz)','EXECUTE'), 'authenticated execute permission preserved on prepare_guest_claim');

SELECT ok((SELECT prosecdef AND proconfig @> ARRAY['search_path=public'] FROM pg_proc WHERE oid='public.prepare_guest_claim(uuid,uuid,uuid,text,jsonb,timestamptz)'::regprocedure), 'Fixed SECURITY DEFINER/search_path on prepare_guest_claim');

SELECT ok(has_function_privilege('service_role','public.commit_guest_claim(uuid,uuid,uuid,jsonb,timestamptz)','EXECUTE'), 'service_role execute permission preserved on commit_guest_claim');

SELECT ok(NOT has_function_privilege('anon','public.commit_guest_claim(uuid,uuid,uuid,jsonb,timestamptz)','EXECUTE'), 'anon execute permission preserved on commit_guest_claim');

SELECT ok(NOT has_function_privilege('authenticated','public.commit_guest_claim(uuid,uuid,uuid,jsonb,timestamptz)','EXECUTE'), 'authenticated execute permission preserved on commit_guest_claim');

SELECT ok((SELECT prosecdef AND proconfig @> ARRAY['search_path=public'] FROM pg_proc WHERE oid='public.commit_guest_claim(uuid,uuid,uuid,jsonb,timestamptz)'::regprocedure), 'Fixed SECURITY DEFINER/search_path on commit_guest_claim');

CREATE TEMP TABLE created AS SELECT public.execute_plant_create_command('15800000-0000-4000-8000-000000000001','15800000-0000-4000-8000-000000000804','{"plant_id": "fixture_rooms_plant", "display_name": "Flat new plant"}'::jsonb) AS body;

SELECT ok(NOT (SELECT body ? 'room_id' FROM created), 'New create response has no room key');

SELECT ok((SELECT room_id IS NULL AND owner_id='15800000-0000-4000-8000-000000000001'::uuid AND plant_id='fixture_rooms_plant' FROM public.plants WHERE id=(SELECT (body->>'plant_id')::uuid FROM created)), 'No-room catalogue create stores real species and NULL room');

SELECT ok(public.execute_plant_create_command('15800000-0000-4000-8000-000000000001','15800000-0000-4000-8000-000000000804','{"plant_id": "fixture_rooms_plant", "display_name": "Flat new plant"}'::jsonb) = (SELECT body FROM created), 'No-room exact retry returns same response');

SELECT ok((SELECT count(*)=1 FROM public.plants WHERE id=(SELECT (body->>'plant_id')::uuid FROM created)) AND (SELECT count(*)=1 FROM public.operation_receipts WHERE owner_id='15800000-0000-4000-8000-000000000001' AND operation_id='15800000-0000-4000-8000-000000000804'), 'Create retry has one plant and one operation receipt');

SELECT ok((SELECT count(*)=3 FROM public.rooms) AND (SELECT room_id='15800000-0000-4000-8000-000000000101'::uuid FROM public.plants WHERE id='15800000-0000-4000-8000-000000000201') AND (SELECT room_id='15800000-0000-4000-8000-000000000102'::uuid FROM public.plants WHERE id='15800000-0000-4000-8000-000000000202'), 'Legacy rooms and links of both owners remain unchanged');

SELECT ok((SELECT consumed_count=7 AND reserved_count=1 FROM public.monthly_quotas WHERE id='15800000-0000-4000-8000-000000000601'), 'Room retirement does not reset quota spending or reservations');

CREATE TEMP TABLE full_sync AS SELECT public.fetch_sync_delta('15800000-0000-4000-8000-000000000001',p_limit=>200) AS body;

SELECT ok(NOT EXISTS(SELECT 1 FROM full_sync,jsonb_array_elements(body->'changes') e WHERE e->>'entity_type'='rooms' OR (e->>'entity_type'='plants' AND e->'data' ? 'room_id')), 'Sync omits rooms and plant room_id');

SELECT ok(EXISTS(SELECT 1 FROM full_sync,jsonb_array_elements(body->'changes') e WHERE e->>'entity_type'='plants' AND e->>'id'='15800000-0000-4000-8000-000000000201'), 'Owner sync preserves historical plants');

SELECT ok(EXISTS(SELECT 1 FROM full_sync,jsonb_array_elements(body->'changes') e WHERE e->>'entity_type'='photo_assets' AND e->>'id'='15800000-0000-4000-8000-000000000501'), 'Owner sync preserves historical photo_assets');

SELECT ok(EXISTS(SELECT 1 FROM full_sync,jsonb_array_elements(body->'changes') e WHERE e->>'entity_type'='condition_snapshots' AND e->>'id'='15800000-0000-4000-8000-000000000701'), 'Owner sync preserves historical condition_snapshots');

SELECT ok(NOT EXISTS(SELECT 1 FROM full_sync,jsonb_array_elements(body->'changes') e WHERE e->'data' ?| ARRAY['original_key','analysis_key','signed_url','full_body']), 'Sync still excludes private media storage keys and raw plans');

SELECT ok(NOT EXISTS(SELECT 1 FROM full_sync,jsonb_array_elements(body->'changes') e WHERE e->>'id'='15800000-0000-4000-8000-000000000202'), 'Owner A sync excludes owner B plant');

SELECT ok(EXISTS(SELECT 1 FROM jsonb_array_elements(public.fetch_sync_delta('15800000-0000-4000-8000-000000000002')->'changes') e WHERE e->>'id'='15800000-0000-4000-8000-000000000202') AND NOT EXISTS(SELECT 1 FROM jsonb_array_elements(public.fetch_sync_delta('15800000-0000-4000-8000-000000000002')->'changes') e WHERE e->>'id'='15800000-0000-4000-8000-000000000201'), 'Owner B sync returns B plant and excludes A plant');

CREATE TEMP TABLE paged(entry jsonb);

DO $test$
DECLARE page jsonb; cursor jsonb; n int := 0; cutoff timestamptz := (SELECT (body->>'until')::timestamptz FROM full_sync);
BEGIN
 LOOP
  page := public.fetch_sync_delta('15800000-0000-4000-8000-000000000001',p_until=>cutoff,p_cursor_updated_at=>(cursor->>'updated_at')::timestamptz,p_cursor_entity_type=>cursor->>'entity_type',p_cursor_id=>(cursor->>'id')::uuid,p_limit=>1);
  INSERT INTO paged SELECT value FROM jsonb_array_elements(page->'changes');
  n := n+1;
  IF n>50 THEN RAISE EXCEPTION 'pagination loop'; END IF;
  EXIT WHEN NOT (page->>'has_more')::boolean;
  cursor := page->'last_cursor';
 END LOOP;
END;
$test$;

SELECT ok((SELECT jsonb_agg(entry ORDER BY entry->>'updated_at',entry->>'entity_type',entry->>'id') FROM paged)=(SELECT jsonb_agg(value ORDER BY value->>'updated_at',value->>'entity_type',value->>'id') FROM full_sync,jsonb_array_elements(body->'changes')), 'Limit-one pagination with shared timestamps matches full sync without loss');

SELECT ok((SELECT count(*)=count(DISTINCT(entry->>'entity_type',entry->>'id')) FROM paged), 'Shared-timestamp pagination has no duplicate entities');

GRANT SELECT ON public.rooms, public.plants TO authenticated;

SET LOCAL ROLE authenticated; SET LOCAL request.jwt.claim.sub='15800000-0000-4000-8000-000000000001';

SELECT ok((SELECT count(*)=2 AND bool_and(owner_id='15800000-0000-4000-8000-000000000001'::uuid) FROM public.rooms), 'Authenticated A can still read own room history, not owner B rooms');

SELECT throws_ok($query$SELECT public.execute_room_command('15800000-0000-4000-8000-000000000001','15800000-0000-4000-8000-000000000999','room.create','{}'::jsonb)$query$, '42501', NULL, 'Authenticated client cannot invoke trusted room RPC');

SET LOCAL request.jwt.claim.sub='15800000-0000-4000-8000-000000000002';

SELECT ok((SELECT count(*)=1 AND bool_and(owner_id='15800000-0000-4000-8000-000000000002'::uuid) FROM public.rooms), 'Authenticated B sees only own historical room');

RESET ROLE;

UPDATE public.profiles SET account_state='deleting' WHERE id='15800000-0000-4000-8000-000000000001';

SELECT throws_ok($query$SELECT public.fetch_sync_delta('15800000-0000-4000-8000-000000000001')$query$, '42501', 'owner_forbidden', 'Deleting owner cannot read flat sync');

SELECT throws_ok($query$SELECT public.execute_room_command('15800000-0000-4000-8000-000000000001','15800000-0000-4000-8000-000000000801','room.create','{"name": "Historical"}'::jsonb)$query$, '42501', 'account_not_active', 'Inactive owner cannot replay room history through trusted RPC');

SELECT ok(NOT EXISTS(SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='guest_drafts' AND column_name='state') AND NOT EXISTS(SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='draft_claims' AND column_name='owner_id'), 'Known incompatible guest baseline remains explicit; positive claim not accepted');
SELECT * FROM finish();
ROLLBACK;
