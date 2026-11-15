BEGIN;
SELECT no_plan();

-- Synthetic evidence and facts are rolled back on both clean and upgrade paths.
INSERT INTO public.profiles(id,anonymous) VALUES
    ('19510000-0000-4000-8000-000000000001',false),
    ('19510000-0000-4000-8000-000000000002',false);
INSERT INTO public.plants(id,owner_id,creation_source,display_name)
VALUES('19510000-0000-4000-8000-000000000011','19510000-0000-4000-8000-000000000001',
    'identification','Synthetic soil check');
UPDATE public.plants p SET taxon_id=t.id,plant_id=t.plant_id
FROM public.catalogue_taxa t JOIN public.catalogue_releases r ON r.id=t.release_id
WHERE p.id='19510000-0000-4000-8000-000000000011'
  AND t.plant_id='monstera_deliciosa' AND t.status='published' AND r.state='published';
INSERT INTO public.condition_snapshots(id,owner_id,plant_id)
VALUES('19510000-0000-4000-8000-000000000012','19510000-0000-4000-8000-000000000001',
    '19510000-0000-4000-8000-000000000011');
UPDATE public.plants SET current_condition_snapshot_id='19510000-0000-4000-8000-000000000012'
WHERE id='19510000-0000-4000-8000-000000000011';
INSERT INTO public.basic_care_memberships(owner_id,plant_id,enabled)
VALUES('19510000-0000-4000-8000-000000000001','19510000-0000-4000-8000-000000000011',true);

INSERT INTO public.care_profiles(kb_release_id,taxon_id,version,profile,field_evidence,validation_report,state)
SELECT k.id,p.taxon_id,'soil-check-fixture',
    $fixture${"schema_version":"2.0","record_version":1,"plant_id":"monstera_deliciosa",
      "actions":[{"action_id":"fixture_soil_check","action_code":"check_soil","purpose":"routine_care",
        "prerequisite_check_ids":[],"contraindication_check_ids":[],"next_check_interval_days":7,
        "action_en":"Fixture: check soil.","action_pl":"Test: sprawdź podłoże."}],
      "provenance":{
        "source_documents":[{"source_id":"fixture","donor_id":"fixture","independence_group":"fixture",
          "url":"https://example.test/soil-check","retrieved_at":"2025-10-01T00:00:00Z",
          "content_hash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
          "use_basis":"Synthetic test data only.","allowed_for":["derived_records"]}],
        "field_evidence":{
          "/actions/0":[{"source_id":"fixture","locator":"Synthetic action","scope":"Test only"}],
          "/actions/0/next_check_interval_days":[{"source_id":"fixture","locator":"Synthetic interval","scope":"Test only"}],
          "/actions/0/refresh_conditions":[{"source_id":"fixture","locator":"Synthetic applicability","scope":"Test only"}]
        },
        "validation":{"method":"manual_review","validated_at":"2025-10-01T00:00:00Z","unresolved_conflicts":[]}
      }
    }$fixture$::jsonb||jsonb_build_object('kb_release_id',k.id),'{}'::jsonb,
    '{"refresh_conditions":{"fixture_soil_check":{"light_code":"unknown","light_source":"unknown",
      "light_confirmed":false,"watering_code":"unknown","drainage_code":"unknown","pot_type":"unknown"}}}'::jsonb,
    'published'
FROM public.plants p CROSS JOIN public.kb_releases k
WHERE p.id='19510000-0000-4000-8000-000000000011' AND k.state='published'
ON CONFLICT(kb_release_id,taxon_id) DO UPDATE
SET version=EXCLUDED.version,profile=EXCLUDED.profile,field_evidence=EXCLUDED.field_evidence,
    validation_report=EXCLUDED.validation_report,state=EXCLUDED.state;

SELECT public.execute_manual_care_command('19510000-0000-4000-8000-000000000001',
    gen_random_uuid(),'19510000-0000-4000-8000-000000000011','care.record',
    '{"action_code":"water","occurred_at":"2025-10-10T23:30:00Z","timezone":"Europe/Warsaw"}');
CREATE TEMP TABLE soil_fixture AS SELECT
    '19510000-0000-4000-8000-000000000099'::uuid AS rule_id,
    gen_random_uuid() AS operation_id,NULL::jsonb AS receipt,NULL::jsonb AS before_state,
    NULL::jsonb AS history_before,NULL::jsonb AS quota_before;
CREATE FUNCTION pg_temp.soil(
    op UUID DEFAULT gen_random_uuid(),rev INT DEFAULT 1,
    owner_id UUID DEFAULT '19510000-0000-4000-8000-000000000001',
    rule UUID DEFAULT NULL,due DATE DEFAULT '2025-10-18',
    happened TIMESTAMPTZ DEFAULT '2025-10-18T23:30:00Z',zone TEXT DEFAULT 'Europe/Warsaw'
) RETURNS JSONB LANGUAGE SQL AS $$
    SELECT public.execute_routine_soil_check(owner_id,op,
        '19510000-0000-4000-8000-000000000011',rev,coalesce(rule,f.rule_id),due,happened,zone)
    FROM soil_fixture f
$$;
-- Failed writes must preserve watermark, receipts, history and quota.
CREATE FUNCTION pg_temp.soil_state() RETURNS JSONB LANGUAGE SQL AS $$
    SELECT jsonb_build_object(
        'owner',(SELECT to_jsonb(p) FROM public.profiles p
            WHERE id='19510000-0000-4000-8000-000000000001'),
        'entries',(SELECT coalesce(jsonb_agg(to_jsonb(e) ORDER BY e.id),'[]') FROM public.care_entries e
            WHERE owner_id='19510000-0000-4000-8000-000000000001'),
        'tasks',(SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY t.id),'[]') FROM public.care_tasks t
            WHERE owner_id='19510000-0000-4000-8000-000000000001'),
        'receipts',(SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY r.operation_id),'[]') FROM public.operation_receipts r
            WHERE owner_id='19510000-0000-4000-8000-000000000001'),
        'quota',(SELECT coalesce(jsonb_agg(to_jsonb(q) ORDER BY to_jsonb(q)),'[]') FROM public.account_quota_usage q
            WHERE owner_id='19510000-0000-4000-8000-000000000001'))
$$;
SELECT is(public.resolve_basic_care_refresh_candidate('19510000-0000-4000-8000-000000000001',
    '19510000-0000-4000-8000-000000000011',1)->>'state','eligible','current sourced fixture is eligible');
UPDATE soil_fixture SET before_state=pg_temp.soil_state();
SELECT throws_ok('SELECT pg_temp.soil()','55000','CURRENT_REFRESHED_RULE_REQUIRED',
    'legacy calendar projection cannot complete without a refreshed rule');
SELECT is(pg_temp.soil_state(),(SELECT before_state FROM soil_fixture),'missing rule writes nothing');

SELECT public.execute_care_recommendation_refresh('19510000-0000-4000-8000-000000000001',
    gen_random_uuid(),'19510000-0000-4000-8000-000000000011','{"expected_care_revision":1}');
UPDATE soil_fixture SET rule_id=(SELECT id FROM public.task_rules
    WHERE plant_id='19510000-0000-4000-8000-000000000011' AND rule_state='active');
SELECT ok((SELECT rule_id IS NOT NULL FROM soil_fixture),'explicit refresh stored a real rule');
SELECT is(public.read_plant_care_profile('19510000-0000-4000-8000-000000000001',
    '19510000-0000-4000-8000-000000000011')->'routine_check',
    jsonb_build_object('rule_id',rule_id,'care_revision',1,
        'due_local_date','2025-10-18','anchor_local_date','2025-10-11','anchor_kind','water'),
    'routine projection starts from the stored watering local day')
FROM soil_fixture
WHERE to_regprocedure('public.resolve_routine_soil_check(uuid,uuid)') IS NOT NULL;
UPDATE soil_fixture SET before_state=pg_temp.soil_state(),
    history_before=pg_temp.soil_state()->'entries',quota_before=pg_temp.soil_state()->'quota';
SELECT throws_ok('SELECT pg_temp.soil(rev=>2)','23505','CARE_REVISION_CHANGED','stale revision is rejected');
SELECT throws_ok($$SELECT pg_temp.soil(owner_id=>'19510000-0000-4000-8000-000000000002')$$,
    'P0002','PLANT_NOT_FOUND','foreign owner cannot complete');
SELECT throws_ok($$SELECT pg_temp.soil(rule=>'19510000-0000-4000-8000-000000000099')$$,
    '55000','CURRENT_REFRESHED_RULE_REQUIRED','different rule is rejected');
SELECT throws_ok($$SELECT pg_temp.soil(due=>'2025-10-19')$$,
    '23505','SOIL_CHECK_OCCURRENCE_CHANGED','due date must match current anchor plus interval');
SELECT throws_ok($$SELECT pg_temp.soil(happened=>'2025-10-17T12:00:00Z')$$,
    '22023','SOIL_CHECK_NOT_DUE','cannot complete before the due local day');
SELECT throws_ok($$SELECT pg_temp.soil(happened=>clock_timestamp()+interval '1 day')$$,
    '22023','FUTURE_CARE_ENTRY','future actual occurrence is rejected');
SELECT throws_ok($$SELECT pg_temp.soil(zone=>'Invalid/Zone')$$,
    '22023','INVALID_SOIL_CHECK_INPUT','unknown timezone is rejected');
UPDATE public.basic_care_memberships SET enabled=false
WHERE plant_id='19510000-0000-4000-8000-000000000011';
SELECT throws_ok('SELECT pg_temp.soil()','55000','ROUTINE_SOIL_CHECK_UNAVAILABLE','disabled membership is rejected');
UPDATE public.basic_care_memberships SET enabled=true
WHERE plant_id='19510000-0000-4000-8000-000000000011';
UPDATE public.care_profiles SET state='retired' WHERE version='soil-check-fixture';
SELECT throws_ok('SELECT pg_temp.soil()','55000','ROUTINE_SOIL_CHECK_UNAVAILABLE','withdrawn evidence is rejected');
UPDATE public.care_profiles SET state='published' WHERE version='soil-check-fixture';
INSERT INTO public.entitlements(owner_id,product_id,state,offer_kind,valid_until)
VALUES('19510000-0000-4000-8000-000000000001','app.narat.plants.pro.monthly','active','paid',now()-interval '1 day');
SELECT throws_ok('SELECT pg_temp.soil()','55000','ROUTINE_SOIL_CHECK_UNAVAILABLE','expired access is rejected');
DELETE FROM public.entitlements WHERE owner_id='19510000-0000-4000-8000-000000000001';
SELECT is(pg_temp.soil_state(),(SELECT before_state FROM soil_fixture),'rejections preserve facts, receipts, quota and watermark');

UPDATE soil_fixture SET receipt=pg_temp.soil(op=>operation_id);
SELECT is((SELECT pg_temp.soil(op=>operation_id) FROM soil_fixture),
    (SELECT receipt FROM soil_fixture),'exact replay returns original receipt');
SELECT is((SELECT count(*) FROM public.care_tasks
    WHERE plant_id='19510000-0000-4000-8000-000000000011'),1::bigint,'only one occurrence exists');
SELECT ok(EXISTS(
    SELECT 1 FROM public.care_tasks t JOIN public.care_entries e ON e.id=t.completed_entry_id
    CROSS JOIN soil_fixture f
    WHERE t.id=(f.receipt->>'task_id')::uuid AND e.id=(f.receipt->>'entry_id')::uuid
      AND t.owner_id=e.owner_id AND t.plant_id=e.plant_id AND e.task_id=t.id
      AND t.rule_id=f.rule_id AND t.occurrence_key=f.rule_id::text||':2025-10-18'
      AND t.state='completed' AND e.state='active' AND t.deleted_at IS NULL AND e.deleted_at IS NULL
      AND t.action_code='check_soil' AND e.action_code='check_soil'
      AND NOT t.reminder_eligible AND t.inactive_reason='completed'
      AND t.due_local_date='2025-10-18' AND e.occurred_local_date='2025-10-19'
      AND t.timezone='Europe/Warsaw' AND e.timezone=t.timezone
      AND e.occurred_at='2025-10-18T23:30:00Z' AND e.operation_id=f.operation_id
      AND t.updated_at=(f.receipt->>'watermark')::timestamptz AND e.updated_at=t.updated_at
      AND t.updated_at=(SELECT updated_at FROM public.profiles WHERE id=t.owner_id)
),'completed check and active fact link atomically with actual local date and watermark');
SELECT is((SELECT coalesce(jsonb_agg(to_jsonb(e) ORDER BY e.id),'[]') FROM public.care_entries e
    WHERE owner_id='19510000-0000-4000-8000-000000000001'
      AND id<>(SELECT (receipt->>'entry_id')::uuid FROM soil_fixture)),
    (SELECT history_before FROM soil_fixture),'existing watering history is unchanged');
SELECT is(pg_temp.soil_state()->'quota',(SELECT quota_before FROM soil_fixture),'quota is unchanged');
SELECT is((SELECT response_payload FROM public.operation_receipts
    WHERE owner_id='19510000-0000-4000-8000-000000000001'
      AND operation_id=(SELECT operation_id FROM soil_fixture)),
    (SELECT receipt FROM soil_fixture),'exact response is stored in the owner receipt');
UPDATE soil_fixture SET before_state=pg_temp.soil_state();
SELECT throws_ok('SELECT pg_temp.soil()','23505',
    CASE WHEN to_regprocedure('public.resolve_routine_soil_check(uuid,uuid)') IS NULL
        THEN 'SOIL_CHECK_OCCURRENCE_CONFLICT' ELSE 'SOIL_CHECK_OCCURRENCE_CHANGED' END,
    'distinct operation cannot duplicate a completed occurrence');
SELECT throws_ok($$SELECT pg_temp.soil(op=>operation_id,zone=>'UTC') FROM soil_fixture$$,
    '23505','IDEMPOTENCY_CONFLICT','changed payload cannot reuse the operation');
UPDATE public.care_profiles SET state='retired' WHERE version='soil-check-fixture';
SELECT is((SELECT pg_temp.soil(op=>operation_id) FROM soil_fixture),
    (SELECT receipt FROM soil_fixture),'receipt replays even after evidence withdrawal');
UPDATE public.care_profiles SET state='published' WHERE version='soil-check-fixture';
SELECT is(pg_temp.soil_state(),(SELECT before_state FROM soil_fixture),'duplicates and replay change no persisted state');
SELECT ok(NOT EXISTS(SELECT 1 FROM public.care_tasks
    WHERE plant_id='19510000-0000-4000-8000-000000000011' AND state<>'completed'),
    'no future task is created');
SELECT ok(has_function_privilege(role_name,
    'public.execute_routine_soil_check(uuid,uuid,uuid,integer,uuid,date,timestamp with time zone,text)','EXECUTE') =
    (role_name='service_role' AND coalesce(obj_description(
        'public.execute_routine_soil_check(uuid,uuid,uuid,integer,uuid,date,timestamp with time zone,text)'::regprocedure,
        'pg_proc')='private:routine-soil-check-owner-http:053',false)),
    role_name||' has the expected private writer permission')
FROM unnest(ARRAY['anon','authenticated','service_role']) AS roles(role_name);
SELECT ok(NOT EXISTS(
    SELECT 1 FROM pg_catalog.pg_proc p
    CROSS JOIN LATERAL pg_catalog.aclexplode(coalesce(p.proacl,pg_catalog.acldefault('f',p.proowner))) a
    WHERE p.oid='public.execute_routine_soil_check(uuid,uuid,uuid,integer,uuid,date,timestamp with time zone,text)'::regprocedure
      AND a.grantee=0 AND a.privilege_type='EXECUTE'
),'PUBLIC has no execute permission');
-- Additional recurrence checks are skipped at historical 051-only cutoffs.
CREATE FUNCTION pg_temp.routine() RETURNS JSONB LANGUAGE SQL AS $$
    SELECT public.read_plant_care_profile('19510000-0000-4000-8000-000000000001',
        '19510000-0000-4000-8000-000000000011')->'routine_check'
$$;
CREATE FUNCTION pg_temp.recurrence_checks() RETURNS SETOF TEXT LANGUAGE plpgsql AS $test$
DECLARE
    v_owner_id CONSTANT UUID := '19510000-0000-4000-8000-000000000001';
    v_plant_id CONSTANT UUID := '19510000-0000-4000-8000-000000000011';
    second_entry UUID;
    second_task UUID;
    historical_rule UUID;
    watering UUID;
    tied_water UUID;
    saved_profile JSONB;
    saved_history JSONB;
    before_replay JSONB;
BEGIN
    IF to_regprocedure('public.resolve_routine_soil_check(uuid,uuid)') IS NULL THEN
        RETURN;
    END IF;
    SELECT to_jsonb(e) INTO saved_history FROM public.care_entries e
        WHERE id=(SELECT (receipt->>'entry_id')::uuid FROM soil_fixture);
    RETURN NEXT is(pg_temp.routine()->>'due_local_date','2025-10-26',
        'actual first completion advances the ordinary due date');
    RETURN NEXT is(pg_temp.routine()->>'anchor_local_date','2025-10-19',
        'completion uses its stored local day');
    RETURN NEXT is(pg_temp.routine()->>'anchor_kind','check_soil','completion explains the next date');
    RETURN NEXT lives_ok(
        $$SELECT pg_temp.soil(due=>'2025-10-26',happened=>'2025-10-26T23:30:00Z')$$,
        'a second operation completes the projected occurrence');
    RETURN NEXT is(pg_temp.routine()->>'due_local_date','2025-11-03',
        'second completion advances again without creating a future task');
    SELECT e.id,e.task_id INTO second_entry,second_task FROM public.care_entries e
        WHERE e.plant_id=v_plant_id AND e.action_code='check_soil'
        ORDER BY e.occurred_at DESC LIMIT 1;

    INSERT INTO public.task_rules(plan_id,owner_id,plant_id,access_class,rule_state,
        action_code,condition_code,interval_days)
    SELECT plan_id,owner_id,plant_id,access_class,'superseded',action_code,condition_code,interval_days
    FROM public.task_rules WHERE id=(SELECT rule_id FROM soil_fixture)
    RETURNING id INTO historical_rule;
    UPDATE public.care_tasks SET rule_id=historical_rule WHERE id=second_task;
    RETURN NEXT is(pg_temp.routine()->>'due_local_date','2025-10-26',
        'completed history from another rule cannot anchor the current rule');
    UPDATE public.care_tasks SET rule_id=(SELECT rule_id FROM soil_fixture) WHERE id=second_task;
    DELETE FROM public.task_rules WHERE id=historical_rule;

    UPDATE public.care_entries SET state='voided' WHERE id=second_entry;
    RETURN NEXT is(pg_temp.routine()->>'due_local_date','2025-10-26','voided completion is excluded');
    UPDATE public.care_entries SET state='active',deleted_at=now() WHERE id=second_entry;
    RETURN NEXT is(pg_temp.routine()->>'due_local_date','2025-10-26','deleted completion is excluded');
    UPDATE public.care_entries SET deleted_at=NULL WHERE id=second_entry;
    UPDATE public.care_tasks SET deleted_at=now() WHERE id=second_task;
    RETURN NEXT is(pg_temp.routine()->>'due_local_date','2025-10-26','deleted completed task is excluded');
    UPDATE public.care_tasks SET deleted_at=NULL WHERE id=second_task;
    UPDATE public.care_tasks SET state='superseded' WHERE id=second_task;
    RETURN NEXT is(pg_temp.routine()->>'due_local_date','2025-10-26','only completed tasks anchor recurrence');
    UPDATE public.care_tasks SET state='completed' WHERE id=second_task;

    UPDATE public.care_entries SET state='voided'
        WHERE plant_id=v_plant_id AND owner_id=v_owner_id AND action_code='water';
    RETURN NEXT ok(pg_temp.routine() IS NULL,'checks alone cannot replace a qualifying initial watering');
    UPDATE public.care_entries SET state='active'
        WHERE plant_id=v_plant_id AND owner_id=v_owner_id AND action_code='water';

    UPDATE public.basic_care_memberships SET enabled=false WHERE plant_id=v_plant_id AND owner_id=v_owner_id;
    RETURN NEXT ok(pg_temp.routine() IS NULL,'disabled membership suppresses the routine projection');
    RETURN NEXT throws_ok(
        $$SELECT pg_temp.soil(due=>'2025-11-03',happened=>'2025-11-03T12:00:00Z')$$,
        '55000','ROUTINE_SOIL_CHECK_UNAVAILABLE','disabled membership also blocks recurrence writes');
    UPDATE public.basic_care_memberships SET enabled=true WHERE plant_id=v_plant_id AND owner_id=v_owner_id;

    INSERT INTO public.entitlements(owner_id,product_id,state,offer_kind,valid_until)
    VALUES(v_owner_id,'app.narat.plants.pro.monthly','active','paid',now()-interval '1 day');
    RETURN NEXT ok(pg_temp.routine() IS NULL,'expired access suppresses the routine projection');
    RETURN NEXT throws_ok(
        $$SELECT pg_temp.soil(due=>'2025-11-03',happened=>'2025-11-03T12:00:00Z')$$,
        '55000','ROUTINE_SOIL_CHECK_UNAVAILABLE','expired access also blocks recurrence writes');
    DELETE FROM public.entitlements e WHERE e.owner_id=v_owner_id;

    SELECT profile INTO saved_profile FROM public.care_profiles WHERE version='soil-check-fixture';
    UPDATE public.care_profiles SET profile=profile #- '{provenance,field_evidence,/actions/0}'
        WHERE version='soil-check-fixture';
    RETURN NEXT ok(pg_temp.routine() IS NULL,'revoked action source suppresses the routine projection');
    RETURN NEXT throws_ok(
        $$SELECT pg_temp.soil(due=>'2025-11-03',happened=>'2025-11-03T12:00:00Z')$$,
        '55000','ROUTINE_SOIL_CHECK_UNAVAILABLE','revoked source also blocks recurrence writes');
    UPDATE public.care_profiles SET profile=saved_profile WHERE version='soil-check-fixture';

    UPDATE public.plants SET care_revision=2 WHERE id=v_plant_id;
    RETURN NEXT ok(pg_temp.routine() IS NULL,'previous context cannot project a routine date');
    UPDATE public.plants SET care_revision=1 WHERE id=v_plant_id;

    watering := (public.execute_manual_care_command(v_owner_id,gen_random_uuid(),v_plant_id,'care.record',
        '{"action_code":"water","occurred_at":"2025-11-05T23:30:00Z","timezone":"Europe/Warsaw"}')
        ->>'entry_id')::uuid;
    RETURN NEXT is(pg_temp.routine()->>'due_local_date','2025-11-13','newer actual watering wins');
    RETURN NEXT is(pg_temp.routine()->>'anchor_kind','water','newer watering explains the date');
    PERFORM public.execute_manual_care_command(v_owner_id,gen_random_uuid(),v_plant_id,'care.record',
        '{"action_code":"water","occurred_at":"2025-11-01T23:30:00Z","timezone":"Europe/Warsaw"}');
    RETURN NEXT is(pg_temp.routine()->>'due_local_date','2025-11-13',
        'later-recorded backdated watering cannot displace a newer actual occurrence');
    RETURN NEXT throws_ok(
        $$SELECT pg_temp.soil(due=>'2025-11-03',happened=>'2025-11-13T12:00:00Z')$$,
        '23505','SOIL_CHECK_OCCURRENCE_CHANGED','write rejects a due date displaced by newer watering');
    tied_water := (public.execute_manual_care_command(v_owner_id,gen_random_uuid(),v_plant_id,'care.record',
        '{"action_code":"water","occurred_at":"2025-11-05T23:30:00Z","timezone":"UTC"}')
        ->>'entry_id')::uuid;
    RETURN NEXT is(pg_temp.routine()->>'anchor_local_date','2025-11-05',
        'equal actual timestamps use recorded time and retain the winning stored local day');
    UPDATE public.care_entries SET state='voided' WHERE id=tied_water;
    RETURN NEXT is(pg_temp.routine()->>'due_local_date','2025-11-13','voided watering is excluded');
    UPDATE public.care_entries SET deleted_at=now() WHERE id=watering;
    RETURN NEXT is(pg_temp.routine()->>'due_local_date','2025-11-09','deleted watering is excluded');
    UPDATE public.care_entries SET deleted_at=NULL WHERE id=watering;

    before_replay := pg_temp.soil_state();
    RETURN NEXT is((SELECT pg_temp.soil(op=>operation_id) FROM soil_fixture),
        (SELECT receipt FROM soil_fixture),'original receipt replays after multiple anchor advances');
    RETURN NEXT is(pg_temp.soil_state(),before_replay,'advanced replay writes no duplicate facts or receipts');
    RETURN NEXT is((SELECT to_jsonb(e) FROM public.care_entries e
        WHERE id=(SELECT (receipt->>'entry_id')::uuid FROM soil_fixture)),
        saved_history,'older completed history is retained verbatim');
    RETURN NEXT is((SELECT count(*) FROM public.care_tasks t WHERE t.plant_id=v_plant_id),
        2::bigint,'exactly two factual occurrences and no future task exist');
END;
$test$;
-- The undo core is absent at the supported 051-053 cutoffs.
CREATE FUNCTION pg_temp.soil_undo(
    op UUID DEFAULT gen_random_uuid(),
    owner_id UUID DEFAULT '19510000-0000-4000-8000-000000000001',
    entry UUID DEFAULT NULL
) RETURNS JSONB LANGUAGE plpgsql AS $$
BEGIN
    RETURN public.execute_routine_soil_check_undo(owner_id,op,
        '19510000-0000-4000-8000-000000000011',
        coalesce(entry,(SELECT (receipt->>'entry_id')::uuid FROM soil_fixture)));
END;
$$;
CREATE FUNCTION pg_temp.undo_checks() RETURNS SETOF TEXT LANGUAGE plpgsql AS $test$
DECLARE
    v_owner_id CONSTANT UUID := '19510000-0000-4000-8000-000000000001';
    v_plant_id CONSTANT UUID := '19510000-0000-4000-8000-000000000011';
    undo_op UUID := gen_random_uuid();
    redo_op UUID := gen_random_uuid();
    undone JSONB;
    redone JSONB;
    saved_state JSONB;
    saved_entry JSONB;
    saved_reversal JSONB;
    saved_water JSONB;
    saved_quota JSONB;
    role_name TEXT;
BEGIN
    IF to_regprocedure('public.execute_routine_soil_check_undo(uuid,uuid,uuid,uuid)') IS NULL THEN
        RETURN;
    END IF;
    FOREACH role_name IN ARRAY ARRAY['anon','authenticated','service_role'] LOOP
        RETURN NEXT ok(has_function_privilege(role_name,
            'public.execute_routine_soil_check_undo(uuid,uuid,uuid,uuid)','EXECUTE') =
            (role_name='service_role' AND coalesce(obj_description(
                'public.execute_routine_soil_check_undo(uuid,uuid,uuid,uuid)'::regprocedure,
                'pg_proc')='private:routine-soil-check-undo-owner-http:055',false)),
            role_name||' has the expected private undo permission');
    END LOOP;
    RETURN NEXT ok(NOT EXISTS (
        SELECT 1 FROM pg_catalog.pg_proc p
        CROSS JOIN LATERAL pg_catalog.aclexplode(coalesce(p.proacl,pg_catalog.acldefault('f',p.proowner))) a
        WHERE p.oid='public.execute_routine_soil_check_undo(uuid,uuid,uuid,uuid)'::regprocedure
          AND a.grantee=0 AND a.privilege_type='EXECUTE'),'PUBLIC cannot execute private undo');

    saved_state := pg_temp.soil_state();
    saved_quota := saved_state->'quota';
    SELECT jsonb_agg(to_jsonb(e) ORDER BY e.id) INTO saved_water
        FROM public.care_entries e WHERE e.plant_id=v_plant_id AND e.action_code='water';
    RETURN NEXT throws_ok(
        $$SELECT pg_temp.soil_undo(owner_id=>'19510000-0000-4000-8000-000000000002')$$,
        'P0002','PLANT_NOT_FOUND','foreign owner cannot undo');
    RETURN NEXT throws_ok(
        $$SELECT pg_temp.soil_undo(entry=>(SELECT id FROM public.care_entries
            WHERE plant_id='19510000-0000-4000-8000-000000000011' AND action_code='water'))$$,
        'P0002','CARE_ENTRY_NOT_FOUND','watering cannot be reversed by soil undo');
    UPDATE public.care_tasks SET state='open'
        WHERE id=(SELECT (receipt->>'task_id')::uuid FROM soil_fixture);
    RETURN NEXT throws_ok('SELECT pg_temp.soil_undo()','55000',
        'ROUTINE_SOIL_CHECK_ENTRY_REQUIRED','only a completed linked task can be undone');
    UPDATE public.care_tasks SET state='completed'
        WHERE id=(SELECT (receipt->>'task_id')::uuid FROM soil_fixture);
    UPDATE public.task_rules SET access_class='premium'
        WHERE id=(SELECT rule_id FROM soil_fixture);
    RETURN NEXT throws_ok('SELECT pg_temp.soil_undo()','55000',
        'ROUTINE_SOIL_CHECK_ENTRY_REQUIRED','premium rule cannot be undone as basic care');
    UPDATE public.task_rules SET access_class='basic_care'
        WHERE id=(SELECT rule_id FROM soil_fixture);
    RETURN NEXT is(pg_temp.soil_state(),saved_state,'rejected undo leaves state unchanged');

    INSERT INTO public.entitlements(owner_id,product_id,state,offer_kind,valid_until)
    VALUES(v_owner_id,'app.narat.plants.pro.monthly','active','paid',now()-interval '1 day');
    undone := pg_temp.soil_undo(op=>undo_op);
    RETURN NEXT is(undone->>'state','voided','undo remains available after expiry');
    RETURN NEXT ok(EXISTS (
        SELECT 1 FROM public.care_tasks t JOIN public.care_entries e ON e.id=t.completed_entry_id
        JOIN public.care_reversals r ON r.entry_id=e.id
        WHERE t.id=(undone->>'task_id')::uuid AND e.id=(undone->>'entry_id')::uuid
          AND e.task_id=t.id AND e.owner_id=t.owner_id AND e.plant_id=t.plant_id
          AND t.state='superseded' AND NOT t.reminder_eligible
          AND t.inactive_reason='first_action_undone' AND e.state='voided'
          AND r.id=(undone->>'reversal_id')::uuid AND r.owner_id=e.owner_id AND r.operation_id=undo_op
          AND e.updated_at=(undone->>'watermark')::timestamptz
          AND t.updated_at=e.updated_at AND r.updated_at=e.updated_at AND r.recorded_at=e.updated_at
          AND e.updated_at=(SELECT updated_at FROM public.profiles WHERE id=e.owner_id)
    ),'undo atomically retains linkage and records its reversal and watermark');
    UPDATE public.basic_care_memberships SET enabled=false WHERE plant_id=v_plant_id;
    RETURN NEXT is(pg_temp.soil_undo(op=>undo_op),undone,'exact undo replay survives later access changes');
    UPDATE public.basic_care_memberships SET enabled=true WHERE plant_id=v_plant_id;
    RETURN NEXT is((SELECT pg_temp.soil(op=>operation_id) FROM soil_fixture),
        (SELECT receipt FROM soil_fixture),'original completion replay survives undo and expiry');
    RETURN NEXT throws_ok('SELECT pg_temp.soil_undo()','23505',
        'CARE_ENTRY_ALREADY_VOIDED','different operation cannot reverse the same fact twice');
    RETURN NEXT throws_ok('SELECT pg_temp.soil()','55000',
        'ROUTINE_SOIL_CHECK_UNAVAILABLE','undo does not permit completion after expiry');
    RETURN NEXT ok(pg_temp.routine() IS NULL,'undo does not restart expired automatic care');
    DELETE FROM public.entitlements e WHERE e.owner_id=v_owner_id;
    RETURN NEXT is(pg_temp.routine()->>'due_local_date','2025-10-18','undo restores the prior due date');
    RETURN NEXT is(pg_temp.routine()->>'anchor_kind','water','voided check no longer anchors projection');

    SELECT to_jsonb(e) INTO saved_entry FROM public.care_entries e
        WHERE e.id=(undone->>'entry_id')::uuid;
    SELECT to_jsonb(r) INTO saved_reversal FROM public.care_reversals r
        WHERE r.id=(undone->>'reversal_id')::uuid;
    UPDATE public.care_reversals SET deleted_at=now() WHERE id=(undone->>'reversal_id')::uuid;
    RETURN NEXT throws_ok('SELECT pg_temp.soil()','23505',
        'SOIL_CHECK_OCCURRENCE_CONFLICT','task without its retained reversal cannot be reused');
    UPDATE public.care_reversals SET deleted_at=NULL WHERE id=(undone->>'reversal_id')::uuid;
    redone := pg_temp.soil(op=>redo_op);
    RETURN NEXT is(redone->>'task_id',undone->>'task_id','same due occurrence reuses exactly its task');
    RETURN NEXT isnt(redone->>'entry_id',undone->>'entry_id','re-completion records a new fact');
    RETURN NEXT is(pg_temp.soil(op=>redo_op),redone,'re-completion has its own exact receipt');
    RETURN NEXT is(pg_temp.soil_undo(op=>undo_op),undone,'old undo replay preserves the new completion');
    RETURN NEXT is((SELECT pg_temp.soil(op=>operation_id) FROM soil_fixture),
        (SELECT receipt FROM soil_fixture),'original completion receipt remains exact after re-completion');
    RETURN NEXT throws_ok(
        format('SELECT pg_temp.soil_undo(op=>%L,entry=>%L)',undo_op,redone->>'entry_id'),
        '23505','IDEMPOTENCY_CONFLICT','undo operation cannot be reused for a different fact');
    RETURN NEXT throws_ok('SELECT pg_temp.soil()','23505',
        'SOIL_CHECK_OCCURRENCE_CHANGED','another operation cannot duplicate the new active fact');
    RETURN NEXT is((SELECT count(*) FROM public.care_entries e
        WHERE e.task_id=(redone->>'task_id')::uuid AND e.state='active'),1::bigint,
        'one active fact remains for the reused task');
    RETURN NEXT ok(EXISTS (SELECT 1 FROM public.care_tasks t
        WHERE t.id=(redone->>'task_id')::uuid AND t.completed_entry_id=(redone->>'entry_id')::uuid
          AND t.state='completed' AND NOT t.reminder_eligible AND t.inactive_reason='completed'),
        're-completion keeps reminders off and links the new fact');
    RETURN NEXT is((SELECT to_jsonb(e) FROM public.care_entries e
        WHERE e.id=(undone->>'entry_id')::uuid),saved_entry,'voided journal fact is retained verbatim');
    RETURN NEXT is((SELECT to_jsonb(r) FROM public.care_reversals r
        WHERE r.id=(undone->>'reversal_id')::uuid),saved_reversal,'reversal history is retained verbatim');
    RETURN NEXT is((SELECT jsonb_agg(to_jsonb(e) ORDER BY e.id) FROM public.care_entries e
        WHERE e.plant_id=v_plant_id AND e.action_code='water'),saved_water,'undo and re-completion preserve watering');
    RETURN NEXT is(pg_temp.soil_state()->'quota',saved_quota,'undo and re-completion preserve quota');
    RETURN NEXT is(pg_temp.routine()->>'due_local_date','2025-10-26','re-completion advances the same rule again');
END;
$test$;
SELECT * FROM pg_temp.undo_checks();
SELECT * FROM pg_temp.recurrence_checks();
SELECT * FROM finish();
ROLLBACK;
