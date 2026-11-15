BEGIN;
SELECT no_plan();

INSERT INTO public.profiles(id, anonymous) VALUES
    ('17000000-0000-4000-8000-000000000001', false),
    ('17000000-0000-4000-8000-000000000002', false),
    ('17000000-0000-4000-8000-000000000003', true);
INSERT INTO public.plants(id, owner_id, creation_source, add_method, display_name) VALUES
    ('17000000-0000-4000-8000-000000000011', '17000000-0000-4000-8000-000000000001', 'identification', 'scan', 'A'),
    ('17000000-0000-4000-8000-000000000012', '17000000-0000-4000-8000-000000000002', 'identification', 'scan', 'B');

CREATE FUNCTION pg_temp.care(
    op UUID, cmd TEXT, payload JSONB,
    owner UUID DEFAULT '17000000-0000-4000-8000-000000000001',
    plant UUID DEFAULT '17000000-0000-4000-8000-000000000011'
) RETURNS JSONB LANGUAGE SQL AS $$
    SELECT public.execute_manual_care_command(owner, op, plant, cmd, payload)
$$;
CREATE TEMP TABLE record_input AS SELECT
    '17000000-0000-4000-8000-000000000021'::uuid AS operation_id,
    '{"action_code":"water","occurred_at":"2025-10-11T23:30:00Z","timezone":"Europe/Warsaw"}'::jsonb AS payload;
SELECT ok(has_function_privilege('service_role', 'public.execute_manual_care_command(uuid,uuid,uuid,text,jsonb)', 'EXECUTE')
    AND NOT has_function_privilege('authenticated', 'public.execute_manual_care_command(uuid,uuid,uuid,text,jsonb)', 'EXECUTE')
    AND NOT has_function_privilege('anon', 'public.execute_manual_care_command(uuid,uuid,uuid,text,jsonb)', 'EXECUTE'),
    'Manual command RPC is service-only');
SELECT throws_ok($q$SELECT pg_temp.care(operation_id,'care.record',payload,
    '17000000-0000-4000-8000-000000000002') FROM record_input$q$,
    'P0002','PLANT_NOT_FOUND','Another owner cannot record on this plant');
SELECT throws_ok($q$SELECT pg_temp.care(operation_id,'care.record',payload,
    '17000000-0000-4000-8000-000000000003') FROM record_input$q$,
    '42501','ACTIVE_PERMANENT_OWNER_REQUIRED','Guest is not admitted');
SELECT throws_ok($q$SELECT pg_temp.care(operation_id,'care.record',payload || '{"occurred_at":"2099-10-11T23:30:00Z"}')
    FROM record_input$q$, '22023','FUTURE_CARE_ENTRY','Future fact is rejected');
SELECT throws_ok($q$SELECT pg_temp.care(operation_id,'care.record',payload || '{"timezone":"Missing/Zone"}')
    FROM record_input$q$, '22023','INVALID_CARE_INPUT','Invalid time zone is rejected');
SELECT throws_ok($q$SELECT pg_temp.care(operation_id,'care.record',payload || '{"occurred_at":"2025-02-30T23:30:00Z"}')
    FROM record_input$q$, '22008',NULL,'Invalid calendar date is rejected');
SELECT throws_ok($q$SELECT pg_temp.care(operation_id,'care.record',payload || '{"task_id":null}')
    FROM record_input$q$, '22023','INVALID_CARE_INPUT','Manual journal cannot link to a task');

CREATE TEMP TABLE record_result AS SELECT pg_temp.care(operation_id,'care.record',payload) body FROM record_input;
CREATE TEMP TABLE entry AS SELECT (body->>'entry_id')::uuid AS id FROM record_result;
SELECT is((SELECT body->>'state' FROM record_result), 'active', 'Record receipt confirms an active fact');
SELECT is((SELECT occurred_local_date FROM public.care_entries WHERE id=(SELECT id FROM entry)),
    '2025-10-12'::date, 'Local journal date derives from the given zone across midnight');
SELECT ok(EXISTS (
    SELECT 1 FROM jsonb_array_elements(public.fetch_sync_delta('17000000-0000-4000-8000-000000000001')->'changes') item
    WHERE item->>'entity_type'='care_entries' AND item->>'id'=(SELECT id::text FROM entry)
        AND item->'data'->>'state'='active'), 'Owner sync returns the active journal fact');
SELECT ok(NOT EXISTS (
    SELECT 1 FROM jsonb_array_elements(public.fetch_sync_delta('17000000-0000-4000-8000-000000000002')->'changes') item
    WHERE item->>'entity_type'='care_entries'), 'Other owner sync hides the fact');
SELECT is((SELECT pg_temp.care(operation_id,'care.record',payload) FROM record_input),
    (SELECT body FROM record_result), 'Record replay returns the original receipt');
SELECT throws_ok($q$SELECT pg_temp.care(operation_id,'care.record',payload || '{"timezone":"UTC"}')
    FROM record_input$q$, '23505','IDEMPOTENCY_CONFLICT','Changed record payload conflicts');
SELECT throws_ok($q$SELECT pg_temp.care(operation_id,'care.undo',jsonb_build_object('entry_id',(SELECT id FROM entry)))
    FROM record_input$q$, '23505','IDEMPOTENCY_CONFLICT','Cross-command replay conflicts');
SELECT is((SELECT count(*) FROM public.care_entries WHERE owner_id='17000000-0000-4000-8000-000000000001'),
    1::bigint, 'Replay and conflicts leave a single fact');

CREATE TEMP TABLE undo_input AS SELECT
    '17000000-0000-4000-8000-000000000022'::uuid AS operation_id,
    jsonb_build_object('entry_id',(SELECT id FROM entry)) AS payload;
SELECT throws_ok($q$SELECT pg_temp.care(operation_id,'care.undo',payload,
    '17000000-0000-4000-8000-000000000002','17000000-0000-4000-8000-000000000012') FROM undo_input$q$,
    'P0002','CARE_ENTRY_NOT_FOUND','Another owner cannot undo an entry on their own plant');
CREATE TEMP TABLE undo_result AS SELECT pg_temp.care(operation_id,'care.undo',payload) body FROM undo_input;
SELECT is((SELECT body->>'state' FROM undo_result), 'voided', 'Undo receipt confirms the reversal');
SELECT is((SELECT pg_temp.care(operation_id,'care.undo',payload) FROM undo_input),
    (SELECT body FROM undo_result), 'Undo replay returns the original receipt');
SELECT throws_ok($q$SELECT pg_temp.care('17000000-0000-4000-8000-000000000023','care.undo',payload)
    FROM undo_input$q$, '23505','CARE_ENTRY_ALREADY_VOIDED','New undo cannot reverse the same entry twice');
SELECT is((SELECT pg_temp.care(operation_id,'care.record',payload) FROM record_input),
    (SELECT body FROM record_result), 'Record replay after undo remains the original receipt');
SELECT ok(EXISTS (
    SELECT 1 FROM jsonb_array_elements(public.fetch_sync_delta('17000000-0000-4000-8000-000000000001')->'changes') item
    WHERE item->>'entity_type'='care_entries' AND item->>'id'=(SELECT id::text FROM entry)
        AND item->'data'->>'state'='voided'), 'Owner sync returns the voided entry');
SELECT ok(EXISTS (
    SELECT 1 FROM jsonb_array_elements(public.fetch_sync_delta('17000000-0000-4000-8000-000000000001')->'changes') item
    WHERE item->>'entity_type'='care_reversals' AND item->'data'->>'entry_id'=(SELECT id::text FROM entry)
        AND item->>'id'=(SELECT body->>'reversal_id' FROM undo_result)), 'Owner sync returns the same reversal');
SELECT is((SELECT count(*) FROM public.care_reversals WHERE entry_id=(SELECT id FROM entry)), 1::bigint,
    'Replayed undo leaves one reversal');
SELECT is((SELECT count(*) FROM public.operation_receipts WHERE owner_id='17000000-0000-4000-8000-000000000001'),
    2::bigint, 'Failed writes and replays leave only the two accepted receipts');
SELECT ok(NOT EXISTS (SELECT 1 FROM public.care_tasks WHERE plant_id='17000000-0000-4000-8000-000000000011')
    AND NOT EXISTS (SELECT 1 FROM public.schedule_changes WHERE plant_id='17000000-0000-4000-8000-000000000011'),
    'Manual record and undo leave care automation untouched');

SELECT * FROM finish();
ROLLBACK;
