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
SELECT throws_ok('SELECT pg_temp.soil()','23505','SOIL_CHECK_OCCURRENCE_CONFLICT',
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
SELECT ok(NOT has_function_privilege(role_name,
    'public.execute_routine_soil_check(uuid,uuid,uuid,integer,uuid,date,timestamp with time zone,text)','EXECUTE'),
    role_name||' cannot execute the private writer')
FROM unnest(ARRAY['anon','authenticated','service_role']) AS roles(role_name);
SELECT ok(NOT EXISTS(
    SELECT 1 FROM pg_catalog.pg_proc p
    CROSS JOIN LATERAL pg_catalog.aclexplode(coalesce(p.proacl,pg_catalog.acldefault('f',p.proowner))) a
    WHERE p.oid='public.execute_routine_soil_check(uuid,uuid,uuid,integer,uuid,date,timestamp with time zone,text)'::regprocedure
      AND a.grantee=0 AND a.privilege_type='EXECUTE'
),'PUBLIC has no execute permission');
SELECT * FROM finish();
ROLLBACK;
