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

-- Exercise a full repeat with an independently marked synthetic published rule.
-- This transaction rolls back the catalogue binding, profile and care facts.
UPDATE public.plants p SET taxon_id = t.id, plant_id = t.plant_id
FROM public.catalogue_taxa t JOIN public.catalogue_releases r ON r.id=t.release_id
WHERE p.id='17300000-0000-4000-8000-000000000011' AND t.plant_id='monstera_deliciosa'
  AND t.status='published' AND r.state='published';
INSERT INTO public.care_profiles(kb_release_id, taxon_id, version, profile, field_evidence, state)
SELECT k.id, p.taxon_id, 'repeat-fixture',
    $fixture${
      "schema_version": "2.0", "record_version": 1, "plant_id": "monstera_deliciosa",
      "actions": [{"action_id":"fixture_soil_check","action_code":"check_soil","purpose":"routine_care",
        "prerequisite_check_ids":[],"contraindication_check_ids":[],"next_check_interval_days":7,
        "action_en":"Fixture: check the soil.","action_pl":"Test: sprawdź podłoże."}],
      "provenance": {
        "source_documents": [{"source_id":"fixture","donor_id":"fixture","independence_group":"fixture",
          "url":"https://example.test/repeat-fixture","retrieved_at":"2025-10-01T00:00:00Z",
          "content_hash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
          "use_basis":"Synthetic test data only.","allowed_for":["derived_records"]}],
        "field_evidence": {
          "/actions/0":[{"source_id":"fixture","locator":"Fixture action","scope":"Synthetic test data"}],
          "/actions/0/next_check_interval_days":[{"source_id":"fixture","locator":"Fixture interval","scope":"Synthetic test data"}]
        },
        "validation":{"method":"manual_review","validated_at":"2025-10-01T00:00:00Z","unresolved_conflicts":[]}
      }
    }$fixture$::jsonb || jsonb_build_object('kb_release_id',k.id), '{}'::jsonb, 'published'
FROM public.plants p CROSS JOIN public.kb_releases k
WHERE p.id='17300000-0000-4000-8000-000000000011' AND k.state='published';
CREATE TEMP TABLE before_repeat AS SELECT pg_temp.check_read() AS body;
SELECT is((SELECT body#>>'{profile,actions,0,next_check_interval_days}' FROM before_repeat), '7',
    'owner reads the interval of the isolated published fixture');
SELECT is(pg_temp.check_read(), (SELECT body FROM before_repeat), 'reading twice never advances an overdue anchor');

CREATE TEMP TABLE repeat_request AS SELECT gen_random_uuid() AS op,
    '{"action_code":"water","occurred_at":"2025-10-20T23:30:00Z","timezone":"Europe/Warsaw"}'::jsonb AS payload;
CREATE TEMP TABLE repeat_receipt AS
SELECT pg_temp.care(op, 'care.record', payload) AS body FROM repeat_request;
SELECT is((SELECT pg_temp.care(op, 'care.record', payload) FROM repeat_request),
    (SELECT body FROM repeat_receipt), 'one actual repeat has an exact receipt on retry');
SELECT is(pg_temp.check_read()->>'last_watered_on', '2025-10-21',
    'the later watering is the new factual local anchor');
SELECT is((SELECT count(*) FROM public.care_entries e JOIN repeat_request q ON e.operation_id=q.op),
    1::bigint, 'the later watering writes one journal fact');
SELECT is((SELECT state FROM public.care_entries WHERE id=(SELECT id FROM first_water)),
    'active', 'repeat preserves the previous factual watering');
SELECT is((SELECT state FROM public.care_entries WHERE id=(SELECT id FROM second_water)),
    'voided', 'repeat preserves previously voided history');

-- Use the real edit command before replaying its read projections through Edge.
CREATE TEMP TABLE v10_edit_get(wire JSONB);
DO $$
DECLARE
    v_owner UUID := '17300000-0000-4000-8000-000000000001';
    v_plant UUID := '17300000-0000-4000-8000-000000000011';
    v_snapshot UUID;
    v_plan UUID;
    v_before JSONB;
BEGIN
    IF to_regprocedure('public.execute_plant_edit_command(uuid,uuid,uuid,jsonb)') IS NULL THEN
        RETURN;
    END IF;
    INSERT INTO public.condition_snapshots(owner_id,plant_id)
    VALUES (v_owner,v_plant) RETURNING id INTO v_snapshot;
    UPDATE public.plants SET current_condition_snapshot_id=v_snapshot WHERE id=v_plant;
    INSERT INTO public.care_plans(operation_id,owner_id,plant_id,locale,plan_kind,access_tier,
        source_kind,snapshot_id,kb_release_id,context_revision,full_body)
    SELECT gen_random_uuid(),v_owner,v_plant,'en','routine','basic','catalogue',v_snapshot,id,1,'{}'
    FROM public.kb_releases WHERE state='published' RETURNING id INTO v_plan;
    INSERT INTO public.task_rules(plan_id,owner_id,plant_id,access_class,action_code,condition_code,interval_days)
    VALUES(v_plan,v_owner,v_plant,'basic_care','check_soil','check_soil_first',7);
    v_before := pg_temp.check_read();
    PERFORM public.execute_plant_edit_command(v_owner,gen_random_uuid(),v_plant,'{"conditions":{"light_code":"low"}}');
    INSERT INTO v10_edit_get SELECT jsonb_build_object(
        'owner',v_owner,'plant',v_plant,'before',v_before,'after',pg_temp.check_read());
END;
$$;
SELECT '# V10_EDIT_GET ' || wire::text FROM v10_edit_get;

-- Exercise the private refresh prerequisite on the same sourced test profile.
DO $$
DECLARE
    v_owner UUID := '17300000-0000-4000-8000-000000000001';
    v_plant UUID := '17300000-0000-4000-8000-000000000011';
    v_evidence JSONB;
BEGIN
    IF to_regprocedure('public.resolve_basic_care_refresh_evidence(uuid,uuid,integer)') IS NULL THEN
        RETURN;
    END IF;
    IF public.resolve_basic_care_refresh_evidence(v_owner,v_plant,2) IS NOT NULL THEN
        RAISE EXCEPTION 'Unsourced refresh context must be rejected';
    END IF;
    UPDATE public.care_profiles
    SET validation_report='{"refresh_conditions":{"fixture_soil_check":{"light_code":"low","light_source":"manual",
        "light_confirmed":true,"watering_code":"unknown","drainage_code":"unknown","pot_type":"unknown"}}}',
        profile=jsonb_set(profile,ARRAY['provenance','field_evidence','/actions/0/refresh_conditions'],
            profile#>ARRAY['provenance','field_evidence','/actions/0'])
    WHERE version='repeat-fixture';
    v_evidence := public.resolve_basic_care_refresh_evidence(v_owner,v_plant,2);
    IF v_evidence->>'action_id' IS DISTINCT FROM 'fixture_soil_check'
       OR v_evidence->>'interval_days' IS DISTINCT FROM '7'
       OR v_evidence->'applicability_source'->>'url' IS DISTINCT FROM 'https://example.test/repeat-fixture' THEN
        RAISE EXCEPTION 'Expected sourced evidence for the current snapshot';
    END IF;
    BEGIN
        PERFORM public.resolve_basic_care_refresh_evidence(v_owner,v_plant,1);
        RAISE EXCEPTION 'Expected stale revision rejection';
    EXCEPTION WHEN unique_violation THEN NULL;
    END;
    BEGIN
        PERFORM public.resolve_basic_care_refresh_evidence(
            '17300000-0000-4000-8000-000000000002',v_plant,2);
        RAISE EXCEPTION 'Expected foreign owner rejection';
    EXCEPTION WHEN no_data_found THEN NULL;
    END;
    IF to_regprocedure('public.resolve_basic_care_refresh_candidate(uuid,uuid,integer)') IS NOT NULL THEN
        IF public.resolve_basic_care_refresh_candidate(v_owner,v_plant,2)
           IS DISTINCT FROM v_evidence || '{"state":"eligible","anchor_on":"2025-10-21"}'::jsonb THEN
            RAISE EXCEPTION 'Expected a candidate tied to the existing watering fact';
        END IF;
        UPDATE public.entitlements SET valid_until=now()-interval '1 day' WHERE owner_id=v_owner;
        IF public.resolve_basic_care_refresh_candidate(v_owner,v_plant,2)->>'reason'
           IS DISTINCT FROM 'automatic_care_unavailable' THEN
            RAISE EXCEPTION 'Expected paused candidate after expiry';
        END IF;
        UPDATE public.entitlements SET valid_until=now()+interval '1 day' WHERE owner_id=v_owner;
        BEGIN
            UPDATE public.care_entries SET state='voided' WHERE owner_id=v_owner AND plant_id=v_plant;
            IF public.resolve_basic_care_refresh_candidate(v_owner,v_plant,2)->>'reason'
               IS DISTINCT FROM 'missing_watering_anchor' THEN
                RAISE EXCEPTION 'Expected pause without an active watering fact';
            END IF;
            RAISE SQLSTATE 'Z1001';
        EXCEPTION WHEN SQLSTATE 'Z1001' THEN NULL;
        END;
        BEGIN
            UPDATE public.care_profiles SET profile=profile #- ARRAY[
                'provenance','field_evidence','/actions/0/next_check_interval_days']
            WHERE version='repeat-fixture';
            IF public.resolve_basic_care_refresh_candidate(v_owner,v_plant,2)->>'reason'
               IS DISTINCT FROM 'insufficient_evidence' THEN
                RAISE EXCEPTION 'Expected pause without interval evidence';
            END IF;
            RAISE SQLSTATE 'Z1001';
        EXCEPTION WHEN SQLSTATE 'Z1001' THEN NULL;
        END;
    END IF;
    PERFORM public.execute_plant_edit_command(v_owner,gen_random_uuid(),v_plant,
        '{"conditions":{"light_code":"medium"}}');
    IF public.resolve_basic_care_refresh_evidence(v_owner,v_plant,3) IS NOT NULL THEN
        RAISE EXCEPTION 'Changed conditions must invalidate the evidence';
    END IF;
END;
$$;

UPDATE public.care_profiles SET state='draft' WHERE version='repeat-fixture';
SELECT is(pg_temp.check_read()->'profile', 'null'::jsonb, 'withdrawn profile cannot support the next repeat');
SELECT is(pg_temp.check_read()->>'last_watered_on', '2025-10-21', 'withdrawal leaves journal history available');
UPDATE public.care_profiles SET state='published' WHERE version='repeat-fixture';
UPDATE public.entitlements SET valid_until=now()-interval '1 day'
WHERE owner_id='17300000-0000-4000-8000-000000000001';
SELECT pg_temp.care(gen_random_uuid(), 'care.record',
    '{"action_code":"water","occurred_at":"2025-10-30T12:30:00Z","timezone":"UTC"}');
SELECT is(pg_temp.check_read()->'calendar_eligible', 'false'::jsonb,
    'manual watering after expiry does not restart the calendar');
SELECT is(pg_temp.check_read()->>'last_watered_on', '2025-10-30',
    'manual journal still records an actual watering after expiry');
SELECT is((SELECT pg_temp.care(op, 'care.record', payload) FROM repeat_request),
    (SELECT body FROM repeat_receipt), 'the existing repeat receipt survives expiry');
SELECT ok(NOT EXISTS (SELECT 1 FROM public.care_tasks WHERE plant_id = '17300000-0000-4000-8000-000000000011'),
    'repeat, withdrawal and expiry create no scheduled tasks');

SELECT * FROM finish();
ROLLBACK;
