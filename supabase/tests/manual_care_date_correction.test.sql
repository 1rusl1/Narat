BEGIN;
SELECT no_plan();

INSERT INTO public.profiles(id, anonymous) VALUES
    ('17200000-0000-4000-8000-000000000001', false),
    ('17200000-0000-4000-8000-000000000002', false);
INSERT INTO public.plants(id, owner_id, creation_source, display_name) VALUES
    ('17200000-0000-4000-8000-000000000011', '17200000-0000-4000-8000-000000000001', 'identification', 'Water journal'),
    ('17200000-0000-4000-8000-000000000012', '17200000-0000-4000-8000-000000000002', 'identification', 'Foreign journal');
INSERT INTO public.entitlements(owner_id, product_id, state, offer_kind, valid_until) VALUES
    ('17200000-0000-4000-8000-000000000001', 'app.narat.plants.pro.monthly', 'expired', 'paid', '2025-10-01');

CREATE FUNCTION pg_temp.care_date(
    op UUID, cmd TEXT, payload JSONB,
    owner UUID DEFAULT '17200000-0000-4000-8000-000000000001',
    plant UUID DEFAULT '17200000-0000-4000-8000-000000000011'
) RETURNS JSONB LANGUAGE SQL AS $$
    SELECT public.execute_manual_care_command(owner, op, plant, cmd, payload)
$$;
CREATE TEMP TABLE date_original AS
SELECT pg_temp.care_date('17200000-0000-4000-8000-000000000021','care.record',
    '{"action_code":"water","occurred_at":"2025-10-12T12:00:00Z","timezone":"UTC"}') body;
CREATE TEMP TABLE date_before AS SELECT e.* FROM public.care_entries e
WHERE id = (SELECT (body->>'entry_id')::uuid FROM date_original);
CREATE TEMP TABLE date_correction AS SELECT
    '17200000-0000-4000-8000-000000000022'::uuid op,
    jsonb_build_object('entry_id', id, 'occurred_at', '2025-10-10T23:30:00Z',
        'timezone', 'Europe/Warsaw') payload FROM date_before;

SELECT throws_ok($q$SELECT pg_temp.care_date(op,'care.correct_date',payload,
    '17200000-0000-4000-8000-000000000002','17200000-0000-4000-8000-000000000012')
    FROM date_correction$q$, 'P0002', 'CARE_ENTRY_NOT_FOUND','foreign entry is hidden');
SELECT throws_ok($q$SELECT pg_temp.care_date(op,'care.correct_date',payload || '{"occurred_at":"2099-01-01T00:00:00Z"}')
    FROM date_correction$q$, '22023', 'FUTURE_CARE_ENTRY','a correction cannot be future-dated');
SELECT throws_ok($q$SELECT pg_temp.care_date(op,'care.correct_date',payload || '{"timezone":"Bad/Zone"}')
    FROM date_correction$q$, '22023', 'INVALID_CARE_INPUT','a correction requires an actual timezone');
SELECT throws_ok($q$SELECT pg_temp.care_date(op,'care.correct_date',payload || '{"action_code":"water"}')
    FROM date_correction$q$, '22023', 'INVALID_CARE_INPUT','a correction cannot change the action');

CREATE TEMP TABLE date_corrected AS
SELECT pg_temp.care_date(op,'care.correct_date',payload) body FROM date_correction;
SELECT ok((SELECT c.body->>'state' = 'active' AND c.body->'reversal_id' = 'null'::jsonb
    AND c.body->>'entry_id' = o.body->>'entry_id'
    AND (c.body->>'watermark')::timestamptz > (o.body->>'watermark')::timestamptz
    FROM date_corrected c CROSS JOIN date_original o),
    'correction returns the original active entry and a new watermark even after expiry');
SELECT ok((SELECT e.occurred_at = '2025-10-10T23:30:00Z'::timestamptz
    AND e.occurred_local_date = '2025-10-11'::date AND e.timezone = 'Europe/Warsaw'
    AND e.recorded_at = b.recorded_at AND e.operation_id = b.operation_id
    AND e.updated_at > b.updated_at
    FROM public.care_entries e JOIN date_before b ON e.id = b.id),
    'correction changes occurrence and local day while preserving identity and record time');
SELECT ok(EXISTS (
    SELECT 1 FROM date_original r CROSS JOIN LATERAL jsonb_array_elements(public.fetch_sync_delta(
        '17200000-0000-4000-8000-000000000001', (r.body->>'watermark')::timestamptz)->'changes') item
    WHERE item->>'entity_type' = 'care_entries' AND item->>'id' = r.body->>'entry_id'
      AND item->'data'->>'occurred_local_date' = '2025-10-11'),
    'owner delta after the record watermark contains the corrected local day');
SELECT is((SELECT pg_temp.care_date(op,'care.correct_date',payload) FROM date_correction),
    (SELECT body FROM date_corrected),'exact retry returns the same correction receipt');
SELECT throws_ok($q$SELECT pg_temp.care_date(op,'care.correct_date',payload || '{"timezone":"UTC"}')
    FROM date_correction$q$, '23505','IDEMPOTENCY_CONFLICT','changed retry cannot alter the accepted correction');

CREATE TEMP TABLE date_undone AS SELECT pg_temp.care_date(
    '17200000-0000-4000-8000-000000000023','care.undo',jsonb_build_object('entry_id', id)) body FROM date_before;
SELECT is((SELECT body->>'state' FROM date_undone), 'voided', 'undo still targets the same entry');
SELECT throws_ok($q$SELECT pg_temp.care_date(gen_random_uuid(),'care.correct_date',payload)
    FROM date_correction$q$, '23505','CARE_ENTRY_ALREADY_VOIDED','new correction cannot reopen a voided entry');
SELECT is((SELECT pg_temp.care_date(op,'care.correct_date',payload) FROM date_correction),
    (SELECT body FROM date_corrected),'receipt replay after undo does not rewrite canonical state');
SELECT ok((SELECT e.state = 'voided' AND e.occurred_local_date = '2025-10-11'::date
    FROM public.care_entries e JOIN date_before b ON e.id = b.id), 'voided fact retains its corrected date');
SELECT ok((SELECT count(*) FROM public.care_entries WHERE owner_id='17200000-0000-4000-8000-000000000001') = 1
    AND (SELECT count(*) FROM public.care_reversals WHERE entry_id=(SELECT id FROM date_before)) = 1
    AND (SELECT count(*) FROM public.operation_receipts WHERE owner_id='17200000-0000-4000-8000-000000000001') = 3,
    'record, correction and undo leave one fact, one reversal and three receipts');
SELECT ok(NOT EXISTS (SELECT 1 FROM public.care_tasks WHERE plant_id='17200000-0000-4000-8000-000000000011')
    AND NOT EXISTS (SELECT 1 FROM public.schedule_changes WHERE plant_id='17200000-0000-4000-8000-000000000011'),
    'manual correction does not resume automation');

SELECT * FROM finish();
ROLLBACK;
