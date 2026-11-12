BEGIN;
SELECT no_plan();

INSERT INTO public.profiles(id, anonymous) VALUES
    ('17300000-0000-4000-8000-000000000001', false),
    ('17300000-0000-4000-8000-000000000002', false);
INSERT INTO public.plants(id, owner_id, creation_source, display_name) VALUES
    ('17300000-0000-4000-8000-000000000011', '17300000-0000-4000-8000-000000000001', 'identification', 'Check'),
    ('17300000-0000-4000-8000-000000000012', '17300000-0000-4000-8000-000000000001', 'identification', 'Other');
CREATE FUNCTION pg_temp.check_read(owner UUID DEFAULT '17300000-0000-4000-8000-000000000001')
RETURNS JSONB LANGUAGE SQL AS $$
    SELECT public.read_plant_care_profile(owner, '17300000-0000-4000-8000-000000000011')
$$;
CREATE FUNCTION pg_temp.care(op UUID, command TEXT, payload JSONB)
RETURNS JSONB LANGUAGE SQL AS $$
    SELECT public.execute_manual_care_command('17300000-0000-4000-8000-000000000001',
        op, '17300000-0000-4000-8000-000000000011', command, payload)
$$;
SELECT is(pg_temp.check_read()->'calendar_eligible', 'true'::jsonb, 'Free owner can read a calendar check');
SELECT is(pg_temp.check_read()->'last_watered_on', 'null'::jsonb, 'No factual watering has no date');
SELECT is(pg_temp.check_read('17300000-0000-4000-8000-000000000002'), NULL::jsonb, 'Foreign owner gets no journal');

CREATE TEMP TABLE first_water AS
SELECT (pg_temp.care(gen_random_uuid(), 'care.record',
    '{"action_code":"water","occurred_at":"2025-10-10T23:30:00Z","timezone":"Europe/Warsaw"}')->>'entry_id')::uuid AS id;
CREATE TEMP TABLE second_water AS
SELECT (pg_temp.care(gen_random_uuid(), 'care.record',
    '{"action_code":"water","occurred_at":"2025-10-12T12:30:00Z","timezone":"UTC"}')->>'entry_id')::uuid AS id;
SELECT pg_temp.care(gen_random_uuid(), 'care.record',
    '{"action_code":"water","occurred_at":"2025-10-01T12:30:00Z","timezone":"UTC"}');
SELECT public.execute_manual_care_command('17300000-0000-4000-8000-000000000001',
    gen_random_uuid(), '17300000-0000-4000-8000-000000000012', 'care.record',
    '{"action_code":"water","occurred_at":"2025-10-14T12:30:00Z","timezone":"UTC"}');
SELECT is(pg_temp.check_read()->>'last_watered_on', '2025-10-12',
    'Anchor uses occurrence rather than ingestion or another plant');
SELECT pg_temp.care(gen_random_uuid(), 'care.correct_date', jsonb_build_object(
    'entry_id', id, 'occurred_at', '2025-10-13T23:30:00Z', 'timezone', 'Europe/Warsaw')) FROM second_water;
SELECT is(pg_temp.check_read()->>'last_watered_on', '2025-10-14', 'Correction exposes stored local day');
SELECT pg_temp.care(gen_random_uuid(), 'care.undo', jsonb_build_object('entry_id', id)) FROM second_water;
SELECT is(pg_temp.check_read()->>'last_watered_on', '2025-10-11', 'Undo falls back to the previous active fact');

INSERT INTO public.basic_care_memberships(owner_id, plant_id, enabled) VALUES
    ('17300000-0000-4000-8000-000000000001', '17300000-0000-4000-8000-000000000011', false);
SELECT is(pg_temp.check_read()->'calendar_eligible', 'false'::jsonb, 'Disabled care suppresses the date');
UPDATE public.basic_care_memberships SET enabled = true WHERE plant_id = '17300000-0000-4000-8000-000000000011';
INSERT INTO public.entitlements(owner_id, product_id, state, offer_kind, valid_until) VALUES
    ('17300000-0000-4000-8000-000000000001', 'app.narat.plants.pro.monthly', 'active', 'paid', now() - interval '1 day');
SELECT is(pg_temp.check_read()->'calendar_eligible', 'false'::jsonb, 'Elapsed verified access suppresses the date');
UPDATE public.entitlements SET valid_until = now() + interval '1 day' WHERE owner_id = '17300000-0000-4000-8000-000000000001';
SELECT is(pg_temp.check_read()->'calendar_eligible', 'true'::jsonb, 'Current verified access allows the date');
SELECT ok(NOT EXISTS (SELECT 1 FROM public.care_tasks WHERE plant_id = '17300000-0000-4000-8000-000000000011'),
    'Reads do not create care tasks');

SELECT * FROM finish();
ROLLBACK;
