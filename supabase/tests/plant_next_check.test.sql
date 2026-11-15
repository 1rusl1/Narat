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
CREATE TEMP TABLE basic_care_enable_result AS
SELECT public.execute_basic_care_command(
    '17300000-0000-4000-8000-000000000001','17300000-0000-4000-8000-000000000020',
    'basic_care.enable','{"plant_id":"17300000-0000-4000-8000-000000000011"}') AS receipt;
SELECT is((SELECT receipt#>>'{state,memberships,0,enabled}' FROM basic_care_enable_result),'true',
    'enabling care confirms this owner membership');
SELECT is(public.execute_basic_care_command(
    '17300000-0000-4000-8000-000000000001','17300000-0000-4000-8000-000000000020',
    'basic_care.enable','{"plant_id":"17300000-0000-4000-8000-000000000011"}'),
    (SELECT receipt FROM basic_care_enable_result),'enabling care replays the original receipt');
SELECT is((SELECT count(*) FROM public.care_entries WHERE plant_id='17300000-0000-4000-8000-000000000011'),
    3::bigint,'enabling care adds no journal entries');
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

-- The everyday date is read from the journal even before any rule is stored.
DO $$
DECLARE
    v_owner UUID := '17300000-0000-4000-8000-000000000001';
    v_plant UUID := '17300000-0000-4000-8000-000000000011';
BEGIN
    IF pg_get_functiondef('public.read_plant_care_profile(uuid,uuid)'::regprocedure)
       NOT LIKE '%plan.full_body ? ''refresh_evidence''%' THEN
        RETURN;
    END IF;

    IF pg_temp.check_read()->'calendar_eligible' IS DISTINCT FROM 'true'::jsonb
       OR EXISTS (SELECT 1 FROM public.task_rules WHERE owner_id=v_owner AND plant_id=v_plant) THEN
        RAISE EXCEPTION 'Expected a calendar without a stored rule before edit';
    END IF;
    PERFORM public.execute_plant_edit_command(v_owner,gen_random_uuid(),v_plant,
        '{"conditions":{"light_code":"low"}}');
    IF pg_temp.check_read()->'calendar_eligible' IS DISTINCT FROM 'false'::jsonb
       OR pg_temp.check_read()->>'last_watered_on' IS DISTINCT FROM '2025-10-21' THEN
        RAISE EXCEPTION 'Edited context must hide the calendar date even without a stored rule';
    END IF;
    IF public.execute_care_recommendation_refresh(v_owner,gen_random_uuid(),v_plant,
        '{"expected_care_revision":2}')->>'reason' IS DISTINCT FROM 'insufficient_evidence'
       OR pg_temp.check_read()->'calendar_eligible' IS DISTINCT FROM 'false'::jsonb THEN
        RAISE EXCEPTION 'Unsupported refresh must leave the calendar paused';
    END IF;
    RAISE SQLSTATE 'Z1001';
EXCEPTION WHEN SQLSTATE 'Z1001' THEN NULL;
END;
$$;

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

DO $$
DECLARE
    v_owner UUID := '17300000-0000-4000-8000-000000000001';
    v_plant UUID := '17300000-0000-4000-8000-000000000011';
    v_op UUID := gen_random_uuid();
    v_receipt JSONB;
    v_before JSONB;
BEGIN
    IF to_regprocedure('public.execute_care_recommendation_refresh(uuid,uuid,uuid,jsonb)') IS NULL THEN
        RETURN;
    END IF;
    SELECT to_jsonb(r) INTO STRICT v_before FROM public.task_rules r WHERE plant_id=v_plant;
    IF v_before->>'rule_state' IS DISTINCT FROM 'paused' THEN
        RAISE EXCEPTION 'Expected the old rule to be paused by edit';
    END IF;
    v_receipt := public.execute_care_recommendation_refresh(v_owner,v_op,v_plant,'{"expected_care_revision":3}');
    IF v_receipt->>'state' IS DISTINCT FROM 'paused'
       OR v_receipt->>'reason' IS DISTINCT FROM 'insufficient_evidence' THEN
        RAISE EXCEPTION 'Expected pause without evidence for the edited conditions';
    END IF;
    IF (SELECT to_jsonb(r) FROM public.task_rules r WHERE plant_id=v_plant) IS DISTINCT FROM v_before
       OR EXISTS (SELECT 1 FROM public.care_tasks WHERE plant_id=v_plant)
       OR pg_temp.check_read()->>'last_watered_on' IS DISTINCT FROM '2025-10-21' THEN
        RAISE EXCEPTION 'Paused refresh changed automation or the watering anchor';
    END IF;
    PERFORM public.execute_plant_edit_command(v_owner,gen_random_uuid(),v_plant,'{"conditions":{"light_code":"low"}}');
    IF public.execute_care_recommendation_refresh(v_owner,v_op,v_plant,'{"expected_care_revision":3}')
       IS DISTINCT FROM v_receipt THEN
        RAISE EXCEPTION 'Exact refresh retry changed the stored receipt';
    END IF;
    BEGIN
        PERFORM public.execute_care_recommendation_refresh(v_owner,v_op,v_plant,'{"expected_care_revision":4}');
        RAISE EXCEPTION 'Expected conflict on changed refresh payload';
    EXCEPTION WHEN unique_violation THEN
        IF SQLERRM <> 'IDEMPOTENCY_CONFLICT' THEN RAISE; END IF;
    END;
    IF to_regprocedure('public.write_basic_care_refresh_rule(uuid,uuid,uuid,jsonb,timestamptz)') IS NULL THEN
        v_op := gen_random_uuid();
        BEGIN
            PERFORM public.execute_care_recommendation_refresh(v_owner,v_op,v_plant,'{"expected_care_revision":4}');
            RAISE EXCEPTION 'Expected unavailable writer for eligible refresh';
        EXCEPTION WHEN object_not_in_prerequisite_state THEN
            IF SQLERRM <> 'CARE_REFRESH_WRITER_UNAVAILABLE' THEN RAISE; END IF;
        END;
        IF EXISTS (SELECT 1 FROM public.operation_receipts WHERE owner_id=v_owner AND operation_id=v_op) THEN
            RAISE EXCEPTION 'Eligible refresh without writer recorded a receipt';
        END IF;
    END IF;
END;
$$;

SELECT to_regprocedure('public.write_basic_care_refresh_rule(uuid,uuid,uuid,jsonb,timestamptz)') IS NOT NULL
    AS has_refresh_rule \gset
\if :has_refresh_rule
CREATE TEMP TABLE v10_refresh_check(receipt JSONB, retry JSONB, second_receipt JSONB, operation_id UUID,
    old_rule UUID, open_task UUID, completed_task UUID, completed_before JSONB,
    journal_before JSONB, quota_before JSONB);
DO $$
DECLARE
    v_owner UUID := '17300000-0000-4000-8000-000000000001';
    v_plant UUID := '17300000-0000-4000-8000-000000000011';
    v_op UUID := gen_random_uuid();
    v_rule UUID;
    v_open UUID;
    v_completed UUID;
    v_journal JSONB;
    v_quota JSONB;
    v_receipt JSONB;
    v_retry JSONB;
    v_second JSONB;
BEGIN
    SELECT id INTO STRICT v_rule FROM public.task_rules WHERE plant_id=v_plant;
    INSERT INTO public.care_tasks(owner_id,plant_id,rule_id,occurrence_key,action_code,due_local_date)
    VALUES(v_owner,v_plant,v_rule,'refresh-old-open','check_soil','2025-10-28') RETURNING id INTO v_open;
    INSERT INTO public.care_tasks(owner_id,plant_id,rule_id,occurrence_key,action_code,due_local_date,state,
        reminder_eligible,inactive_reason)
    VALUES(v_owner,v_plant,v_rule,'refresh-old-completed','check_soil','2025-10-14','completed',false,'completed')
    RETURNING id INTO v_completed;

    SELECT jsonb_agg(to_jsonb(e) ORDER BY e.id) INTO v_journal
    FROM public.care_entries e WHERE e.owner_id=v_owner;
    SELECT coalesce(jsonb_agg(to_jsonb(q) ORDER BY to_jsonb(q)), '[]') INTO v_quota
    FROM public.account_quota_usage q WHERE q.owner_id=v_owner;

    INSERT INTO v10_refresh_check(old_rule,open_task,completed_task,completed_before,journal_before,quota_before)
    SELECT v_rule,v_open,v_completed,to_jsonb(t),v_journal,v_quota FROM public.care_tasks t WHERE id=v_completed;

    -- GET selects the first routine action. Never unpause on evidence for a different action.
    BEGIN
        UPDATE public.care_profiles
        SET profile=jsonb_set(profile,'{actions}',jsonb_build_array(
            profile#>'{actions,0}' || '{"action_id":"other_soil_check"}'::jsonb,
            profile#>'{actions,0}'
        )) || jsonb_build_object('provenance',
            jsonb_set(profile->'provenance','{field_evidence}',
                profile#>'{provenance,field_evidence}' || jsonb_build_object(
                    '/actions/1',profile#>ARRAY['provenance','field_evidence','/actions/0'],
                    '/actions/1/next_check_interval_days',
                        profile#>ARRAY['provenance','field_evidence','/actions/0/next_check_interval_days'],
                    '/actions/1/refresh_conditions',
                        profile#>ARRAY['provenance','field_evidence','/actions/0/refresh_conditions']
                )))
        WHERE version='repeat-fixture';
        IF public.resolve_basic_care_refresh_candidate(v_owner,v_plant,4)->>'state'
           IS DISTINCT FROM 'eligible' THEN
            RAISE EXCEPTION 'Expected eligible evidence for the second action';
        END IF;
        IF public.execute_care_recommendation_refresh(v_owner,gen_random_uuid(),v_plant,
                '{"expected_care_revision":4}')->>'reason' IS DISTINCT FROM 'insufficient_evidence'
           OR pg_temp.check_read()->'calendar_eligible' IS DISTINCT FROM 'false'::jsonb THEN
            RAISE EXCEPTION 'Refresh must not unpause the date for a different action';
        END IF;
        RAISE SQLSTATE 'Z1001';
    EXCEPTION WHEN SQLSTATE 'Z1001' THEN NULL;
    END;

    v_receipt := public.execute_care_recommendation_refresh(v_owner,v_op,v_plant,'{"expected_care_revision":4}');
    v_retry := public.execute_care_recommendation_refresh(v_owner,v_op,v_plant,'{"expected_care_revision":4}');
    v_second := public.execute_care_recommendation_refresh(v_owner,gen_random_uuid(),v_plant,
        '{"expected_care_revision":4}');
    UPDATE v10_refresh_check SET receipt=v_receipt,retry=v_retry,second_receipt=v_second,operation_id=v_op;
END;
$$;
SELECT is((SELECT receipt->>'state' FROM v10_refresh_check),'refreshed','sourced refresh commits');
SELECT is((SELECT retry FROM v10_refresh_check),(SELECT receipt FROM v10_refresh_check),'exact replay');
SELECT is((SELECT second_receipt FROM v10_refresh_check),(SELECT receipt FROM v10_refresh_check),
    'an identical refresh with a new operation ID does not change the watermark');
SELECT is((SELECT count(*) FROM public.task_rules r JOIN public.care_plans cp ON cp.id=r.plan_id
    JOIN public.plants p ON p.id=r.plant_id
    WHERE p.id='17300000-0000-4000-8000-000000000011' AND r.rule_state='active'
      AND r.action_code='check_soil' AND r.interval_days=7 AND cp.snapshot_id=p.current_condition_snapshot_id
      AND cp.context_revision=p.care_revision AND cp.full_body#>>'{refresh_evidence,action_id}'='fixture_soil_check'),
    1::bigint,'one active rule binds the current snapshot and published evidence');
SELECT is((SELECT count(*) FROM public.task_rules
    WHERE plant_id='17300000-0000-4000-8000-000000000011' AND rule_state='active'),
    1::bigint,'repeat with a different operation ID never adds an active rule');
SELECT is((SELECT r.rule_state FROM public.task_rules r JOIN v10_refresh_check c ON c.old_rule=r.id),
    'superseded','replaced rule stays in history');
SELECT ok((SELECT t.state='superseded' AND NOT t.reminder_eligible
    FROM public.care_tasks t JOIN v10_refresh_check c ON c.open_task=t.id),'old open reminder is retired');
SELECT is((SELECT to_jsonb(t) FROM public.care_tasks t JOIN v10_refresh_check c ON c.completed_task=t.id),
    (SELECT completed_before FROM v10_refresh_check),'completed task remains unchanged');
SELECT is((SELECT jsonb_agg(to_jsonb(e) ORDER BY e.id) FROM public.care_entries e
    WHERE e.owner_id='17300000-0000-4000-8000-000000000001'),
    (SELECT journal_before FROM v10_refresh_check),'refresh preserves the journal');
SELECT is((SELECT coalesce(jsonb_agg(to_jsonb(q) ORDER BY to_jsonb(q)), '[]') FROM public.account_quota_usage q
    WHERE q.owner_id='17300000-0000-4000-8000-000000000001'),
    (SELECT quota_before FROM v10_refresh_check),'refresh preserves quota usage');
SELECT is(pg_temp.check_read()->>'last_watered_on','2025-10-21','refresh retains the existing watering anchor');
SELECT is(pg_temp.check_read()->'calendar_eligible','true'::jsonb,'refresh clears the replaced rule pause');
SELECT '# V10_REFRESH_WIRE ' || jsonb_build_object('receipt',receipt,'operation',operation_id,
    'after_refresh',pg_temp.check_read())::text FROM v10_refresh_check;
-- Withdrawing applicability leaves the verified general advice and historical watering intact.
SAVEPOINT refresh_evidence_rollback;
UPDATE public.care_profiles
SET profile = profile #- ARRAY['provenance','field_evidence','/actions/0/refresh_conditions']
WHERE version = 'repeat-fixture';
DO $$
BEGIN
    IF pg_get_functiondef('public.read_plant_care_profile(uuid,uuid)'::regprocedure)
           LIKE '%refresh_evidence,applicability_source%'
       AND (pg_temp.check_read()->'calendar_eligible' IS DISTINCT FROM 'false'::jsonb
           OR pg_temp.check_read()#>>'{profile,actions,0,action_id}' IS DISTINCT FROM 'fixture_soil_check'
           OR pg_temp.check_read()->>'last_watered_on' IS DISTINCT FROM '2025-10-21') THEN
        RAISE EXCEPTION 'Withdrawing applicability must hide the date and retain the general advice and journal';
    END IF;
END;
$$;
ROLLBACK TO SAVEPOINT refresh_evidence_rollback;
RELEASE SAVEPOINT refresh_evidence_rollback;
SAVEPOINT refresh_membership_rollback;
UPDATE public.basic_care_memberships SET deleted_at = clock_timestamp()
WHERE plant_id = '17300000-0000-4000-8000-000000000011';
DO $$
BEGIN
    IF pg_get_functiondef('public.read_plant_care_profile(uuid,uuid)'::regprocedure)
           LIKE '%refresh_evidence,applicability_source%'
       AND pg_temp.check_read()->'calendar_eligible' IS DISTINCT FROM 'false'::jsonb THEN
        RAISE EXCEPTION 'A previously refreshed calendar requires current membership';
    END IF;
END;
$$;
ROLLBACK TO SAVEPOINT refresh_membership_rollback;
RELEASE SAVEPOINT refresh_membership_rollback;
SELECT ok(has_function_privilege('service_role',
    'public.execute_care_recommendation_refresh(uuid,uuid,uuid,jsonb)','execute'), 'trusted transport can call refresh');
SELECT ok(NOT has_function_privilege('authenticated',
    'public.execute_care_recommendation_refresh(uuid,uuid,uuid,jsonb)','execute'), 'authenticated cannot call refresh directly');
SELECT ok(NOT has_function_privilege('service_role','public.write_basic_care_refresh_rule(uuid,uuid,uuid,jsonb,timestamptz)',
    'execute'), 'transport cannot bypass candidate resolution');
\endif

CREATE TEMP TABLE scheduled_before_withdrawal AS
SELECT id FROM public.care_tasks WHERE plant_id='17300000-0000-4000-8000-000000000011';
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
SELECT is((SELECT array_agg(id ORDER BY id) FROM public.care_tasks WHERE plant_id='17300000-0000-4000-8000-000000000011'),
    (SELECT array_agg(id ORDER BY id) FROM scheduled_before_withdrawal),
    'repeat, withdrawal and expiry create no scheduled tasks');

SELECT * FROM finish();
ROLLBACK;
