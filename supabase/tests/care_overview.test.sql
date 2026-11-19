BEGIN;
SELECT no_plan();

-- All synthetic facts and temporary publication edits roll back. This suite is
-- explicitly invoked by the gate on clean and populated historical upgrades.
CREATE FUNCTION pg_temp.oid(n INTEGER) RETURNS UUID LANGUAGE SQL IMMUTABLE AS $$
    SELECT ('19910000-0000-4000-8000-' || lpad(n::text,12,'0'))::uuid
$$;
CREATE TEMP TABLE ov_fixture AS
SELECT k.id AS kb,r.id AS catalogue,t.id AS taxon,NULL::uuid AS rule
FROM public.kb_releases k
JOIN public.catalogue_releases r ON r.state='published'
JOIN public.catalogue_taxa t ON t.release_id=r.id AND t.plant_id='monstera_deliciosa'
WHERE k.state='published' AND t.status='published';
SELECT is((SELECT count(*) FROM ov_fixture),1::bigint,'published canonical Monstera fixture is unambiguous');
INSERT INTO public.profiles(id,anonymous,account_state) VALUES
    (pg_temp.oid(1),false,'active'),(pg_temp.oid(2),false,'active'),
    (pg_temp.oid(3),true,'active'),(pg_temp.oid(4),false,'deleting');
-- Create the oversized collection legitimately under paid access, then model
-- retained legacy rows without an entitlement. Keep the capacity trigger active.
INSERT INTO public.entitlements(owner_id,product_id,state,offer_kind,valid_until)
VALUES(pg_temp.oid(1),'app.narat.plants.pro.yearly','active','paid',
    statement_timestamp()+interval '1 day');
INSERT INTO public.plants(id,owner_id,creation_source,display_name)
SELECT pg_temp.oid(n),pg_temp.oid(CASE WHEN n=17 THEN 2 ELSE 1 END),
    'identification','Overview fixture '||n FROM generate_series(11,17) n;
UPDATE public.plants SET deleted_at=now() WHERE id=pg_temp.oid(16);
DELETE FROM public.entitlements WHERE owner_id=pg_temp.oid(1);
UPDATE public.plants SET taxon_id=f.taxon,plant_id='monstera_deliciosa'
FROM ov_fixture f WHERE id=pg_temp.oid(11);
INSERT INTO public.condition_snapshots(id,owner_id,plant_id)
VALUES(pg_temp.oid(21),pg_temp.oid(1),pg_temp.oid(11));
UPDATE public.plants SET current_condition_snapshot_id=pg_temp.oid(21) WHERE id=pg_temp.oid(11);
INSERT INTO public.basic_care_memberships(owner_id,plant_id,enabled)
VALUES(pg_temp.oid(1),pg_temp.oid(11),true);

INSERT INTO public.care_profiles(kb_release_id,taxon_id,version,profile,field_evidence,validation_report,state)
SELECT kb,taxon,'overview-fixture',
    '{"plant_id":"monstera_deliciosa","actions":[{
        "action_id":"fixture_check","action_code":"check_soil","purpose":"routine_care",
        "prerequisite_check_ids":[],"contraindication_check_ids":[],"next_check_interval_days":7,
        "action_en":"Fixture: check soil.","action_pl":"Test: sprawdź podłoże."}],
      "provenance":{"source_documents":[{"source_id":"fixture","url":"https://example.test/overview",
        "allowed_for":["derived_records"]}],"field_evidence":{
        "/actions/0":[{"source_id":"fixture","locator":"Action"}],
        "/actions/0/next_check_interval_days":[{"source_id":"fixture","locator":"Interval"}],
        "/actions/0/refresh_conditions":[{"source_id":"fixture","locator":"Applicability"}]}}}'::jsonb
        ||jsonb_build_object('kb_release_id',kb),'{}',
    '{"refresh_conditions":{"fixture_check":{"light_code":"unknown","light_source":"unknown",
        "light_confirmed":false,"watering_code":"unknown","drainage_code":"unknown","pot_type":"unknown"}}}',
    'published' FROM ov_fixture
ON CONFLICT(kb_release_id,taxon_id) DO UPDATE SET version=EXCLUDED.version,
    profile=EXCLUDED.profile,field_evidence=EXCLUDED.field_evidence,
    validation_report=EXCLUDED.validation_report,state=EXCLUDED.state;

CREATE TEMP TABLE ov_saved(name TEXT PRIMARY KEY,body JSONB);
CREATE FUNCTION pg_temp.overview(owner UUID DEFAULT pg_temp.oid(1),
    after_id UUID DEFAULT NULL,lim INTEGER DEFAULT 100) RETURNS JSONB LANGUAGE SQL AS $$
    SELECT public.read_owner_care_overview(owner,after_id,lim)
$$;
CREATE FUNCTION pg_temp.card(n INTEGER DEFAULT 11) RETURNS JSONB LANGUAGE SQL AS $$
    SELECT item FROM jsonb_array_elements(pg_temp.overview()->'plants') item
    WHERE item->>'plant_id'=pg_temp.oid(n)::text
$$;
CREATE FUNCTION pg_temp.controls() RETURNS JSONB LANGUAGE SQL AS $$
    SELECT pg_temp.card()->'first_aid_controls'
$$;
CREATE FUNCTION pg_temp.generation() RETURNS JSONB LANGUAGE SQL AS $$
    SELECT pg_temp.overview()-'plants'-'next_after'-'server_now'
$$;
-- Compare typed facts consistently across the caller-time-zone regression.
-- Otherwise to_jsonb(timestamptz) changes text despite unchanged stored values.
CREATE FUNCTION pg_temp.facts() RETURNS JSONB LANGUAGE plpgsql SET timezone = 'UTC' AS $$
DECLARE result JSONB; tab TEXT; rows JSONB;
BEGIN
    SELECT to_jsonb(p) INTO result FROM public.profiles p WHERE id=pg_temp.oid(1);
    result := jsonb_build_object('profile',result);
    FOREACH tab IN ARRAY ARRAY['plants','condition_snapshots','care_entries','care_tasks',
        'care_plans','task_rules','basic_care_memberships','first_aid_followups','care_observations',
        'care_reversals','operation_receipts','account_quota_usage','monthly_quotas','entitlements','analysis_jobs']
    LOOP
        EXECUTE format('SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY to_jsonb(t)),''[]''::jsonb)
            FROM public.%I t WHERE owner_id=$1',tab) INTO rows USING pg_temp.oid(1);
        result := result || jsonb_build_object(tab,rows);
    END LOOP;
    RETURN result;
END $$;

SELECT ok(has_function_privilege(role_name,
    'public.read_owner_care_overview(uuid,uuid,integer)','EXECUTE')=(role_name='service_role'),
    role_name||' has precisely the required RPC access')
FROM unnest(ARRAY['anon','authenticated','service_role']) role_name;
SELECT ok(NOT EXISTS(SELECT 1 FROM pg_proc p,
    LATERAL aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) a
    WHERE p.oid='public.read_owner_care_overview(uuid,uuid,integer)'::regprocedure
        AND a.grantee=0 AND a.privilege_type='EXECUTE'),'PUBLIC cannot execute overview');
SELECT ok(p.prosecdef AND p.provolatile='s'
    AND p.proconfig @> ARRAY['search_path=""']::text[],
    'RPC is STABLE SECURITY DEFINER with empty search_path')
FROM pg_proc p WHERE p.oid='public.read_owner_care_overview(uuid,uuid,integer)'::regprocedure;
SELECT throws_ok(format('SELECT pg_temp.overview(%L::uuid)',pg_temp.oid(n)),
    '42501','ACTIVE_PERMANENT_OWNER_REQUIRED','reject unknown/guest/inactive owner '||n)
FROM unnest(ARRAY[3,4,99]) n;
SELECT throws_ok('SELECT pg_temp.overview(NULL)','42501','ACTIVE_PERMANENT_OWNER_REQUIRED','null owner rejected');
SELECT throws_ok('SELECT pg_temp.overview(lim=>'||bad||')',
    '22023','INVALID_CARE_OVERVIEW_LIMIT','reject limit '||bad)
FROM unnest(ARRAY['NULL','0','-1','201']) bad;

INSERT INTO ov_saved VALUES('pure',pg_temp.facts()),('generation',pg_temp.generation());
CREATE TEMP TABLE ov_pages(n INTEGER,body JSONB);
INSERT INTO ov_pages VALUES(1,pg_temp.overview(lim=>2));
INSERT INTO ov_pages SELECT 2,pg_temp.overview(after_id=>(body->>'next_after')::uuid,lim=>2)
FROM ov_pages WHERE n=1;
INSERT INTO ov_pages SELECT 3,pg_temp.overview(after_id=>(body->>'next_after')::uuid,lim=>2)
FROM ov_pages WHERE n=2;
SELECT is((SELECT jsonb_agg(item->>'plant_id' ORDER BY n,position)
    FROM ov_pages,LATERAL jsonb_array_elements(body->'plants') WITH ORDINALITY a(item,position)),
    (SELECT jsonb_agg(pg_temp.oid(n)::text ORDER BY n) FROM generate_series(11,15) n),
    'UUID pages include all five plants once, including unscheduled plants; no Free-three cap');
SELECT is((SELECT body->>'next_after' FROM ov_pages WHERE n=1),pg_temp.oid(12)::text,'cursor is last emitted UUID');
SELECT is((SELECT body->>'next_after' FROM ov_pages WHERE n=2),pg_temp.oid(14)::text,'cursor advances');
SELECT is((SELECT body->'next_after' FROM ov_pages WHERE n=3),'null'::jsonb,'last page has no continuation');
SELECT ok((SELECT bool_and(body-'plants'-'next_after'-'server_now'=
    (SELECT body FROM ov_saved WHERE name='generation')) FROM ov_pages),'all pages share one generation');
SELECT is(pg_temp.generation(),(SELECT body FROM ov_saved WHERE name='generation'),'unchanged reads have stable generation');
SET LOCAL TIME ZONE 'Pacific/Auckland';
SELECT is(pg_temp.generation(),(SELECT body FROM ov_saved WHERE name='generation'),'generation is independent of caller time zone');
SET LOCAL TIME ZONE 'UTC';
SELECT is(pg_temp.overview()->>'owner_watermark',
    (SELECT to_jsonb(updated_at)#>>'{}' FROM public.profiles WHERE id=pg_temp.oid(1)),'watermark is persisted profile clock');
SELECT ok(pg_temp.overview()->>'publication_fingerprint' ~ '^[0-9a-f]{64}$','fingerprint contains only a digest');
SELECT is(jsonb_array_length(pg_temp.overview()->'plants'),5,'default page includes entire legacy collection');
SELECT is(jsonb_array_length(pg_temp.overview(lim=>200)->'plants'),5,'maximum limit accepted');
SELECT is(pg_temp.overview(after_id=>pg_temp.oid(17))->'plants','[]'::jsonb,'cursor beyond owner collection returns empty');
SELECT is(pg_temp.overview(owner=>pg_temp.oid(2))->'plants'->0->>'plant_id',pg_temp.oid(17)::text,'foreign owner sees only own plant');
SELECT ok((SELECT bool_and(item->'care_profile'=coalesce(
    public.read_plant_care_profile(pg_temp.oid(1),(item->>'plant_id')::uuid),'null'::jsonb))
    FROM jsonb_array_elements(pg_temp.overview()->'plants') item),'raw care_profile preserves existing 056 authority exactly');
SELECT is(pg_temp.card(12)#>'{care_profile,profile}','null'::jsonb,'unscheduled plant remains in page');
SELECT is(pg_temp.facts(),(SELECT body FROM ov_saved WHERE name='pure'),'paging changes no watermarks, receipts, facts or quotas');

-- Real canonical care commands, not fabricated completion dates.
INSERT INTO ov_saved VALUES('water',public.execute_manual_care_command(pg_temp.oid(1),gen_random_uuid(),
    pg_temp.oid(11),'care.record','{"action_code":"water","occurred_at":"2025-10-10T23:30:00Z","timezone":"Europe/Warsaw"}'));
SELECT public.execute_care_recommendation_refresh(pg_temp.oid(1),gen_random_uuid(),pg_temp.oid(11),
    '{"expected_care_revision":1}');
UPDATE ov_fixture SET rule=(SELECT id FROM public.task_rules WHERE owner_id=pg_temp.oid(1)
    AND plant_id=pg_temp.oid(11) AND rule_state='active' AND action_code='check_soil');
SELECT is(pg_temp.card()#>>'{care_profile,routine_check,due_local_date}','2025-10-18','routine uses verified local watering anchor');
SELECT is(pg_temp.card()#>'{care_profile,routine_check}',public.resolve_routine_soil_check(pg_temp.oid(1),pg_temp.oid(11)),
    'overview delegates rule identity and recurrence to accepted resolver');
SELECT isnt(pg_temp.generation()->>'owner_watermark',
    (SELECT body->>'owner_watermark' FROM ov_saved WHERE name='generation'),'canonical care changes generation watermark');
SELECT public.execute_manual_care_command(pg_temp.oid(1),gen_random_uuid(),pg_temp.oid(11),'care.correct_date',
    jsonb_build_object('entry_id',body->>'entry_id','occurred_at','2025-10-12T23:30:00Z','timezone','Europe/Warsaw'))
FROM ov_saved WHERE name='water';
SELECT is(pg_temp.card()#>>'{care_profile,routine_check,due_local_date}','2025-10-20','date correction updates current routine date');
INSERT INTO ov_saved SELECT 'check',public.execute_routine_soil_check(pg_temp.oid(1),gen_random_uuid(),
    pg_temp.oid(11),1,rule,'2025-10-20','2025-10-20T23:30:00Z','Europe/Warsaw') FROM ov_fixture;
SELECT is(pg_temp.card()#>>'{care_profile,routine_check,due_local_date}','2025-10-28','completion advances recurrence from actual local day');
SELECT public.execute_routine_soil_check_undo(pg_temp.oid(1),gen_random_uuid(),pg_temp.oid(11),(body->>'entry_id')::uuid)
FROM ov_saved WHERE name='check';
SELECT is(pg_temp.card()#>>'{care_profile,routine_check,due_local_date}','2025-10-20','undo restores the watering-based current occurrence');
SELECT ok(NOT EXISTS(SELECT 1 FROM public.care_tasks WHERE owner_id=pg_temp.oid(1) AND state='open'),
    'reads and canonical recurrence do not materialize future tasks');

INSERT INTO public.condition_profiles(kb_release_id,condition_id,version,state,protocol,field_evidence)
SELECT kb,'overwatering','overview-fixture','published',
    '{"condition_id":"overwatering","first_help_action_id":"check_moisture","contraindication_check_ids":[],
      "actions":[{"action_id":"check_moisture","action_code":"check_soil","purpose":"diagnostic_check",
        "action_en":"Fixture: check the potting mix.","prerequisite_check_ids":[],
        "contraindication_check_ids":[],"next_check_interval_days":3}],
      "provenance":{"source_documents":[{"source_id":"fixture","url":"https://example.test/first-aid",
        "allowed_for":["derived_records"]}],"field_evidence":{
        "/actions/0":[{"source_id":"fixture","locator":"Action"}],
        "/actions/0/next_check_interval_days":[{"source_id":"fixture","locator":"Interval"}]}}}'::jsonb
        ||jsonb_build_object('kb_release_id',kb),'{}' FROM ov_fixture
ON CONFLICT(kb_release_id,condition_id) DO UPDATE SET version=EXCLUDED.version,
    state=EXCLUDED.state,protocol=EXCLUDED.protocol,field_evidence=EXCLUDED.field_evidence;
CREATE TEMP TABLE ov_jobs AS SELECT n,gen_random_uuid() AS job,gen_random_uuid() AS analysis,
    NULL::jsonb AS receipt FROM generate_series(1,4) n;
INSERT INTO public.analysis_jobs(id,owner_id,flow_id,intent,add_method,plant_id,mode,kb_release_id,
    prompt_version,operation_id,payload_hash,locale,snapshot_id,quota_kind,quota_state,state)
SELECT job,pg_temp.oid(1),gen_random_uuid(),'problem','scan',pg_temp.oid(11),'diagnosis',kb,
    'fixture',gen_random_uuid(),'fixture','en',pg_temp.oid(21),'none','not_applicable','succeeded'
FROM ov_jobs CROSS JOIN ov_fixture;
INSERT INTO public.diagnosis_job_runtime(job_id,catalogue_release_id,projection,repeat_context)
SELECT job,catalogue,jsonb_build_object('analysis_id',analysis,'diagnosis_status','problem_detected',
    'selected_condition_id','overwatering','identification_status','identified','plant_id','monstera_deliciosa',
    'plan_availability','available','first_action_summary','Fixture: check the potting mix.','control_interval_days',3),
    jsonb_build_object('target_plant_id',pg_temp.oid(11)) FROM ov_jobs CROSS JOIN ov_fixture;
UPDATE ov_jobs SET receipt=public.execute_manual_care_command(pg_temp.oid(1),gen_random_uuid(),pg_temp.oid(11),
    'care.first_aid.record',jsonb_build_object('job_id',job,'occurred_at','2025-10-11T23:30:00Z','timezone','Europe/Warsaw')) WHERE n<=3;
SELECT is(jsonb_array_length(pg_temp.controls()),3,'canonical supported first aid controls are included');
SELECT public.complete_first_aid_control(pg_temp.oid(1),gen_random_uuid(),pg_temp.oid(11),
    jsonb_build_object('control_id',receipt->>'control_id','status_code','unchanged')) FROM ov_jobs WHERE n=2;
SELECT public.execute_manual_care_command(pg_temp.oid(1),gen_random_uuid(),pg_temp.oid(11),
    'care.undo',jsonb_build_object('entry_id',receipt->>'entry_id')) FROM ov_jobs WHERE n=3;
SELECT is(jsonb_array_length(pg_temp.controls()),1,'observed/completed and undone controls excluded');
SELECT is(pg_temp.controls()->0->>'control_id',(SELECT receipt->>'control_id' FROM ov_jobs WHERE n=1),'remaining control keeps canonical identity');
SELECT is(pg_temp.controls()#>>'{0,policy,due_on}','2025-10-15','first aid date uses performed local day plus current verified interval');
SELECT is(pg_temp.controls()#>'{0,policy,source}','{"url":"https://example.test/first-aid","locator":"Interval"}'::jsonb,
    'compact control contains current approved interval source');
SELECT ok(NOT (pg_temp.controls()->0 ?| ARRAY['protocol','first_action_snapshot','projection']),
    'control does not expose private diagnosis/protocol bodies');

INSERT INTO ov_saved SELECT 'control',to_jsonb(f) FROM public.first_aid_followups f
WHERE id=(SELECT (receipt->>'control_id')::uuid FROM ov_jobs WHERE n=1);
INSERT INTO ov_saved SELECT 'protocol',protocol FROM public.condition_profiles
WHERE version='overview-fixture' AND condition_id='overwatering';
INSERT INTO ov_saved SELECT 'profile',profile FROM public.care_profiles WHERE version='overview-fixture';
CREATE FUNCTION pg_temp.bad_policies() RETURNS SETOF TEXT LANGUAGE plpgsql AS $$
DECLARE bad JSONB;
BEGIN
    FOR bad IN SELECT value FROM jsonb_array_elements(
        '["not-a-date","2025-02-30","2025-10-16",42,null,{},[]]'::jsonb)
    LOOP
        UPDATE public.first_aid_followups SET check_policy_snapshot=jsonb_set(
            (SELECT body->'check_policy_snapshot' FROM ov_saved WHERE name='control'),'{due_on}',bad)
        WHERE id=(SELECT (receipt->>'control_id')::uuid FROM ov_jobs WHERE n=1);
        RETURN NEXT is(pg_temp.controls(),'[]'::jsonb,'untrusted due_on is rejected without cast: '||bad::text);
    END LOOP;
    UPDATE public.first_aid_followups SET check_policy_snapshot=
        (SELECT body->'check_policy_snapshot' FROM ov_saved WHERE name='control')
    WHERE id=(SELECT (receipt->>'control_id')::uuid FROM ov_jobs WHERE n=1);
END $$;
SELECT * FROM pg_temp.bad_policies();

-- Independently violate each 031 identity/lifecycle guard, then restore it.
CREATE FUNCTION pg_temp.control_guards() RETURNS SETOF TEXT LANGUAGE plpgsql AS $$
DECLARE assignment TEXT; control UUID;
BEGIN
    SELECT (receipt->>'control_id')::uuid INTO control FROM ov_jobs WHERE n=1;
    FOREACH assignment IN ARRAY ARRAY[
        'deleted_at=now()','state=''completed''','context_revision=2',
        'control_task_id=(SELECT (body->>''task_id'')::uuid FROM ov_saved WHERE name=''check'')','origin_analysis_id=gen_random_uuid()',
        'action_code=''water''','first_action_snapshot=''{}''::jsonb']
    LOOP
        EXECUTE 'UPDATE public.first_aid_followups SET '||assignment||' WHERE id=$1' USING control;
        RETURN NEXT is(pg_temp.controls(),'[]'::jsonb,'current control guard: '||assignment);
        UPDATE public.first_aid_followups f SET deleted_at=NULL,state='active',context_revision=1,
            control_task_id=NULL,origin_analysis_id=(s.body->>'origin_analysis_id')::uuid,
            action_code='check_soil',first_action_snapshot=s.body->'first_action_snapshot'
        FROM ov_saved s WHERE s.name='control' AND f.id=control;
    END LOOP;
END $$;
SELECT * FROM pg_temp.control_guards();
UPDATE public.care_entries SET state='voided' WHERE id=(SELECT (receipt->>'entry_id')::uuid FROM ov_jobs WHERE n=1);
SELECT is(pg_temp.controls(),'[]'::jsonb,'voided linked fact excluded');
UPDATE public.care_entries SET state='active' WHERE id=(SELECT (receipt->>'entry_id')::uuid FROM ov_jobs WHERE n=1);
UPDATE public.analysis_jobs SET snapshot_id=NULL WHERE id=(SELECT job FROM ov_jobs WHERE n=1);
SELECT is(pg_temp.controls(),'[]'::jsonb,'stale diagnosis snapshot excluded');
UPDATE public.analysis_jobs SET snapshot_id=pg_temp.oid(21) WHERE id=(SELECT job FROM ov_jobs WHERE n=1);
UPDATE public.diagnosis_job_runtime SET projection=jsonb_set(projection,'{analysis_id}','"bad-uuid"')
WHERE job_id=(SELECT job FROM ov_jobs WHERE n=1);
SELECT is(pg_temp.controls(),'[]'::jsonb,'malformed diagnosis identity fails closed without throwing');
UPDATE public.diagnosis_job_runtime r SET projection=jsonb_set(projection,'{analysis_id}',to_jsonb(j.analysis))
FROM ov_jobs j WHERE r.job_id=j.job AND j.n=1;

INSERT INTO ov_saved VALUES('before_withdrawal',pg_temp.generation());
UPDATE public.condition_profiles SET protocol=protocol #- '{provenance,field_evidence,/actions/0/next_check_interval_days}'
WHERE version='overview-fixture' AND condition_id='overwatering';
SELECT is(pg_temp.controls(),'[]'::jsonb,'missing current interval evidence yields no dated control');
SELECT isnt(pg_temp.generation()->>'publication_fingerprint',
    (SELECT body->>'publication_fingerprint' FROM ov_saved WHERE name='before_withdrawal'),
    'same-release in-place protocol evidence withdrawal invalidates generation');
SELECT is(pg_temp.generation()->>'owner_watermark',
    (SELECT body->>'owner_watermark' FROM ov_saved WHERE name='before_withdrawal'),'publication withdrawal does not manufacture owner mutation');
UPDATE ov_jobs SET receipt=public.execute_manual_care_command(pg_temp.oid(1),gen_random_uuid(),pg_temp.oid(11),
    'care.first_aid.record',jsonb_build_object('job_id',job,'occurred_at','2025-10-11T23:30:00Z','timezone','Europe/Warsaw'))
WHERE n=4;
SELECT ok((SELECT receipt->'control_id'='null'::jsonb AND receipt->>'entry_id' IS NOT NULL FROM ov_jobs WHERE n=4),
    'canonical action without current interval stays journal-only, without an invented dated control');
UPDATE public.condition_profiles SET protocol=(SELECT body FROM ov_saved WHERE name='protocol')
WHERE version='overview-fixture' AND condition_id='overwatering';
UPDATE public.condition_profiles SET protocol=jsonb_set(protocol,'{actions,0,next_check_interval_days}','4')
WHERE version='overview-fixture' AND condition_id='overwatering';
SELECT is(pg_temp.controls(),'[]'::jsonb,'changed current interval cannot reuse snapshot policy');
UPDATE public.condition_profiles SET protocol=jsonb_set(
    (SELECT body FROM ov_saved WHERE name='protocol'),'{actions,0,action_code}','"water"')
WHERE version='overview-fixture' AND condition_id='overwatering';
SELECT is(pg_temp.controls(),'[]'::jsonb,'unsupported current action cannot reuse an active stored control');
UPDATE public.condition_profiles SET protocol=(SELECT body FROM ov_saved WHERE name='protocol'),state='retired'
WHERE version='overview-fixture' AND condition_id='overwatering';
SELECT is(pg_temp.controls(),'[]'::jsonb,'withdrawn protocol yields no dated control');
UPDATE public.condition_profiles SET state='published' WHERE version='overview-fixture' AND condition_id='overwatering';
SELECT is(jsonb_array_length(pg_temp.controls()),1,'restored exact evidence restores supported pending control');

UPDATE public.care_profiles SET profile=profile #- '{provenance,field_evidence,/actions/0}'
WHERE version='overview-fixture';
SELECT is(pg_temp.card()#>'{care_profile,calendar_eligible}','false'::jsonb,'routine source withdrawal suppresses current calendar');
SELECT isnt(pg_temp.generation()->>'publication_fingerprint',
    (SELECT body->>'publication_fingerprint' FROM ov_saved WHERE name='before_withdrawal'),
    'same-release in-place routine source withdrawal changes generation');
UPDATE public.care_profiles SET profile=(SELECT body FROM ov_saved WHERE name='profile') WHERE version='overview-fixture';
UPDATE public.catalogue_taxa SET status='deprecated' WHERE id=(SELECT taxon FROM ov_fixture);
SELECT isnt(pg_temp.generation()->>'publication_fingerprint',
    (SELECT body->>'publication_fingerprint' FROM ov_saved WHERE name='before_withdrawal'),'catalogue withdrawal changes generation without new release');
UPDATE public.catalogue_taxa SET status='published' WHERE id=(SELECT taxon FROM ov_fixture);

-- Access matrix uses persisted entitlement shapes permitted by the billing
-- schema. Nonfinite timestamps cover malformed legacy data without weakening it.
CREATE FUNCTION pg_temp.access_case(s TEXT,o TEXT,v TIMESTAMPTZ,t TIMESTAMPTZ,
    deadline TIMESTAMPTZ,allowed BOOLEAN) RETURNS SETOF TEXT LANGUAGE plpgsql AS $$
DECLARE envelope JSONB; before_read JSONB;
BEGIN
    INSERT INTO public.entitlements(owner_id,product_id,state,offer_kind,valid_until,trial_end_at,grace_until)
    VALUES(pg_temp.oid(1),'app.narat.plants.pro.yearly',s,o,v,t,'2101-01-01')
    ON CONFLICT(owner_id) DO UPDATE SET state=EXCLUDED.state,offer_kind=EXCLUDED.offer_kind,
        valid_until=EXCLUDED.valid_until,trial_end_at=EXCLUDED.trial_end_at,grace_until=EXCLUDED.grace_until;
    before_read := pg_temp.facts();
    envelope := pg_temp.overview();
    RETURN NEXT is(envelope->'automation_allowed',to_jsonb(allowed),'automation: '||s||'/'||o||'/'||v);
    RETURN NEXT is(envelope->'verified_access_until',coalesce(to_jsonb(deadline),'null'::jsonb),
        'wire verified deadline: '||s||'/'||o||'/'||v);
    RETURN NEXT is(jsonb_array_length(envelope#>'{plants,0,first_aid_controls}'),
        CASE WHEN allowed THEN 1 ELSE 0 END,'access gates controls while retaining plants');
    RETURN NEXT is(jsonb_array_length(envelope->'plants'),5,'access never truncates collection');
    IF isfinite(v) THEN
        RETURN NEXT is(envelope#>'{plants,0,care_profile,calendar_eligible}',to_jsonb(allowed),
            'accepted routine access gate agrees for valid entitlement');
    END IF;
    RETURN NEXT is(pg_temp.facts(),before_read,'access read changes no facts, receipts or quota');
END $$;
SELECT * FROM pg_temp.access_case('active','paid','2100-01-01',NULL,'2100-01-01',true);
SELECT * FROM pg_temp.access_case('grace','paid','2100-01-01',NULL,'2100-01-01',true);
SELECT * FROM pg_temp.access_case('grace','paid','2025-01-01',NULL,'2025-01-01',false);
SELECT * FROM pg_temp.access_case('active','trial','2100-01-01','2099-01-01','2099-01-01',true);
SELECT * FROM pg_temp.access_case('active','trial','2099-01-01','2100-01-01','2099-01-01',true);
SELECT * FROM pg_temp.access_case('active','trial','2100-01-01','2025-01-01','2025-01-01',false);
SELECT * FROM pg_temp.access_case('expired','paid','2100-01-01',NULL,NULL,false);
SELECT * FROM pg_temp.access_case('billing_retry','paid','2100-01-01',NULL,NULL,false);
SELECT * FROM pg_temp.access_case('revoked','paid','2100-01-01',NULL,NULL,false);
SELECT * FROM pg_temp.access_case('active','paid','infinity',NULL,NULL,false);
SELECT isnt(pg_temp.generation()->'automation_allowed',
    (SELECT body->'automation_allowed' FROM ov_saved WHERE name='before_withdrawal'),'access metadata invalidates unchanged owner generation');

-- Expiry suppresses automation but the canonical manual journal stays usable.
SELECT public.execute_manual_care_command(pg_temp.oid(1),gen_random_uuid(),pg_temp.oid(12),'care.record',
    '{"action_code":"water","occurred_at":"2025-10-11T12:00:00Z","timezone":"UTC"}');
SELECT is(pg_temp.card(12)->>'plant_id',pg_temp.oid(12)::text,'expired owner can record manual history and still sees plant');
DELETE FROM public.entitlements WHERE owner_id=pg_temp.oid(1);
SELECT is(pg_temp.overview()->'automation_allowed','true'::jsonb,'only absent entitlement is true Free');
SELECT is(pg_temp.overview()->'verified_access_until','null'::jsonb,'true Free has no verified deadline');
INSERT INTO ov_saved VALUES('before_hour',pg_temp.generation());
UPDATE public.profiles SET reminder_hour_local=17 WHERE id=pg_temp.oid(1);
SELECT is(pg_temp.overview()->'reminder_hour_local','17'::jsonb,'hour is exposed as generation metadata');
SELECT isnt(pg_temp.generation(),(SELECT body FROM ov_saved WHERE name='before_hour'),'hour change prevents mixing pages');
SELECT public.execute_plant_edit_command(pg_temp.oid(1),gen_random_uuid(),pg_temp.oid(11),'{"conditions":{"light_code":"low"}}');
SELECT is(pg_temp.card()#>'{care_profile,calendar_eligible}','false'::jsonb,'canonical condition edit pauses routine calendar');
SELECT ok(pg_temp.card()#>'{care_profile,routine_check}' IS NULL,'paused context exposes no routine occurrence');
SELECT is(pg_temp.controls(),'[]'::jsonb,'condition edit invalidates previous first aid context');
INSERT INTO ov_saved VALUES('final_pure',pg_temp.facts());
SELECT pg_temp.overview();
SELECT pg_temp.overview(lim=>1);
SELECT is(pg_temp.facts(),(SELECT body FROM ov_saved WHERE name='final_pure'),
    'final reads preserve owner clock, journal, controls, task history, receipts and quota');

SELECT * FROM finish();
ROLLBACK;
