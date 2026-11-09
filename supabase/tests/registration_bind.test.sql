-- Actual bind/reserve/finalize on synthetic PostgreSQL fixtures, no RPC replacements.
-- The controller's --bind gate also runs clean/upgrade accounting, all reserve
-- tests and 99 actual settlements plus six 20-connection rounds. No live proof.
BEGIN;
SELECT plan(113);

CREATE FUNCTION pg_temp.bind_id(n integer) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$
    SELECT ('16350000-0000-4000-8000-' || lpad(n::text,12,'0'))::uuid
$$;
CREATE FUNCTION pg_temp.bind_owner(i integer, o integer,
    at_time timestamptz DEFAULT '2026-11-15 10:20Z')
RETURNS jsonb LANGUAGE sql AS $$
    SELECT public.bind_installation_to_owner(pg_temp.bind_id(i),pg_temp.bind_id(o),at_time)
$$;
CREATE FUNCTION pg_temp.bind_admit(j integer, o integer, i integer DEFAULT NULL,
    m text DEFAULT 'diagnosis') RETURNS jsonb LANGUAGE sql AS $$
    SELECT public.admit_analysis_quota(m,pg_temp.bind_id(o),pg_temp.bind_id(i),
        pg_temp.bind_id(j),'2026-11-15 10:20Z')
$$;
CREATE FUNCTION pg_temp.bind_finish(j integer, outcome text DEFAULT 'succeeded',
    nonbillable boolean DEFAULT false) RETURNS jsonb LANGUAGE sql AS $$
    SELECT public.finalize_analysis_quota(pg_temp.bind_id(j),outcome,nonbillable,'2026-11-16 10:20Z')
$$;

INSERT INTO public.profiles(id,anonymous,created_at,starter_identification_consumed,starter_diagnosis_consumed)
SELECT pg_temp.bind_id(n),n=2,'2026-01-31 10:20Z'::timestamptz,n IN (1,3),n=3
FROM generate_series(1,15) n WHERE n<>12;
-- A genuine pre-005 permanent owner with no verified registration evidence.
ALTER TABLE public.profiles DISABLE TRIGGER trg_profiles_registration_anchor;
INSERT INTO public.profiles(id,anonymous,created_at,starter_identification_consumed,starter_diagnosis_consumed)
VALUES(pg_temp.bind_id(12),false,'2020-01-01',true,true);
ALTER TABLE public.profiles ENABLE TRIGGER trg_profiles_registration_anchor;
INSERT INTO public.account_quota_anchors VALUES(pg_temp.bind_id(12),NULL,'unresolved');
UPDATE public.profiles SET account_state='deleting' WHERE id=pg_temp.bind_id(9);
UPDATE public.profiles SET account_state='deleted' WHERE id=pg_temp.bind_id(10);
UPDATE public.profiles SET first_starter_success_at='2026-10-05',quota_anchor_at='2026-07-01'
WHERE id=pg_temp.bind_id(1);
UPDATE public.profiles SET starter_diagnosis_consumed=true,first_starter_success_at='2026-09-01'
WHERE id=pg_temp.bind_id(8);
INSERT INTO public.installation_access(id,credential_hash,linked_owner_ids)
SELECT pg_temp.bind_id(i),'bind-fixture-' || i,ARRAY[pg_temp.bind_id(2)]
FROM unnest(ARRAY[1001,1004,1005,1006,1007,1008,1012,1013,1014,1015]) i;
UPDATE public.installation_access SET linked_owner_ids=ARRAY[pg_temp.bind_id(2),pg_temp.bind_id(3)],
    starter_diagnosis_consumed=true,first_starter_success_at='2026-10-01'
WHERE id=pg_temp.bind_id(1001);
UPDATE public.installation_access SET starter_identification_consumed=true,first_starter_success_at='2026-10-01'
WHERE id=pg_temp.bind_id(1008);
INSERT INTO public.kb_releases(id,version,state,manifest_sha256,published_at)
VALUES(pg_temp.bind_id(100),'bind-fixture','retired',repeat('a',64),'2026-01-01');
INSERT INTO public.analysis_jobs(id,owner_id,flow_id,intent,add_method,mode,kb_release_id,
    prompt_version,operation_id,payload_hash,locale,quota_kind,quota_state,created_at)
SELECT pg_temp.bind_id(j),pg_temp.bind_id(o),pg_temp.bind_id(j),'problem','scan',m,
    pg_temp.bind_id(100),'bind-fixture',pg_temp.bind_id(j),'hash-' || j,'en','none','not_applicable',
    '2026-11-15 10:20Z'::timestamptz
FROM (VALUES
    (101,1,'identification'),(102,1,'diagnosis'),(103,1,'diagnosis'),(104,1,'diagnosis'),
    (201,2,'diagnosis'),(202,2,'identification'),(203,2,'diagnosis'),
    (204,4,'diagnosis'),(205,4,'diagnosis'),(206,5,'identification'),
    (207,2,'diagnosis'),(1501,15,'diagnosis'),
    (301,3,'diagnosis'),(302,3,'identification'),
    (601,6,'diagnosis'),(602,6,'diagnosis'),
    (701,7,'identification'),(702,7,'diagnosis'),(703,7,'diagnosis'),
    (704,7,'diagnosis'),(705,7,'diagnosis'),(706,7,'diagnosis'),
    (901,1,'diagnosis'),(1201,12,'diagnosis'),
    (1301,13,'identification'),(1302,13,'identification'),
    (1401,14,'identification'),(1402,14,'identification')
) f(j,o,m);
INSERT INTO public.monthly_quotas(id,owner_id,quota_kind,period_start,period_end,
    limit_count,consumed_count,reserved_count)
VALUES(pg_temp.bind_id(9001),pg_temp.bind_id(1),'paid_monthly','2026-09-01','2026-10-01',100,7,1);
UPDATE public.analysis_jobs SET quota_kind='paid_monthly',quota_state='reserved',
    monthly_quota_id=pg_temp.bind_id(9001),quota_owner_id=owner_id,state='running',
    created_at='2026-09-15',lease_token=id,provider_started_at='2026-09-15'
WHERE id=pg_temp.bind_id(901);
INSERT INTO public.purchase_ownership(environment,original_transaction_id,owner_id,
    app_account_token,first_verified_access_at)
VALUES('Sandbox','bind-fixture',pg_temp.bind_id(1),pg_temp.bind_id(8001),'2026-08-01');
INSERT INTO public.entitlements(owner_id,product_id,state,offer_kind,valid_until)
VALUES(pg_temp.bind_id(3),'app.narat.plants.pro.monthly','active','paid','2027-12-01');
INSERT INTO public.operation_receipts(owner_id,operation_id,command_name,payload_hash,response_payload)
VALUES(pg_temp.bind_id(2),pg_temp.bind_id(201),'analysis.start','bind-fixture','{"receipt":"guest-history"}');
INSERT INTO public.provider_daily_budget(utc_date,started_calls,max_calls)
VALUES('2099-02-01',23,500);

-- Snapshot every accounting/history source; the binder may only change the two
-- endpoint starter/binding fields. Foreign owners are also compared in full.
CREATE TEMP VIEW bind_protected AS SELECT jsonb_build_object(
    'jobs',(SELECT jsonb_agg(to_jsonb(t) ORDER BY id) FROM public.analysis_jobs t),
    'quotas',(SELECT jsonb_agg(to_jsonb(t) ORDER BY id) FROM public.monthly_quotas t),
    'usage',(SELECT jsonb_agg(to_jsonb(t) ORDER BY job_id) FROM public.account_quota_usage t),
    'reconciliation',(SELECT jsonb_agg(to_jsonb(t) ORDER BY monthly_quota_id) FROM public.quota_legacy_reconciliation t),
    'anchors',(SELECT jsonb_agg(to_jsonb(t) ORDER BY owner_id) FROM public.account_quota_anchors t),
    'purchases',(SELECT jsonb_agg(to_jsonb(t) ORDER BY environment,original_transaction_id) FROM public.purchase_ownership t),
    'entitlements',(SELECT jsonb_agg(to_jsonb(t) ORDER BY owner_id) FROM public.entitlements t),
    'events',(SELECT jsonb_agg(to_jsonb(t) ORDER BY notification_uuid) FROM public.subscription_events t),
    'receipts',(SELECT jsonb_agg(to_jsonb(t) ORDER BY owner_id,operation_id) FROM public.operation_receipts t),
    'budget',(SELECT jsonb_agg(to_jsonb(t) ORDER BY utc_date) FROM public.provider_daily_budget t),
    'results',(SELECT jsonb_agg(to_jsonb(t) ORDER BY id) FROM public.analysis_results t),
    'photos',(SELECT jsonb_agg(to_jsonb(t) ORDER BY id) FROM public.photo_assets t),
    'plants',(SELECT jsonb_agg(to_jsonb(t) ORDER BY id) FROM public.plants t),
    'drafts',(SELECT jsonb_agg(to_jsonb(t) ORDER BY id) FROM public.guest_drafts t),
    'profile_context',(SELECT jsonb_agg(to_jsonb(t)-ARRAY['starter_identification_consumed',
        'starter_diagnosis_consumed','starter_identification_job_id','starter_diagnosis_job_id',
        'first_starter_success_at','updated_at'] ORDER BY id) FROM public.profiles t),
    'other_owners',(SELECT jsonb_agg(to_jsonb(t) ORDER BY id) FROM public.profiles t
        WHERE anonymous OR id=pg_temp.bind_id(3))
) AS data;
CREATE TEMP TABLE bind_protected_before AS SELECT data FROM bind_protected;

SELECT ok((SELECT prosecdef AND proconfig @> ARRAY['search_path=""'] FROM pg_proc
    WHERE oid='public.bind_installation_to_owner(uuid,uuid,timestamptz)'::regprocedure),
    'Bind is a definer with a pinned empty search_path');
SELECT ok(NOT EXISTS(SELECT 1 FROM pg_proc p,
    LATERAL aclexplode(COALESCE(p.proacl,acldefault('f',p.proowner))) a
    WHERE p.oid='public.bind_installation_to_owner(uuid,uuid,timestamptz)'::regprocedure
      AND a.grantee IN (0,'anon'::regrole::oid,'authenticated'::regrole::oid)
      AND a.privilege_type='EXECUTE'),'PUBLIC and client execution revoked');
SELECT ok(has_function_privilege('service_role',
    'public.bind_installation_to_owner(uuid,uuid,timestamptz)','EXECUTE'),'Service can bind');
SELECT ok((SELECT bool_and(relrowsecurity) FROM pg_class WHERE oid IN
    ('public.installation_access'::regclass,'public.account_quota_anchors'::regclass,
     'public.account_quota_usage'::regclass,'public.quota_legacy_reconciliation'::regclass)),
    'Installation and private accounting tables retain RLS');
SELECT ok(NOT has_table_privilege('authenticated','public.account_quota_usage','INSERT')
    AND NOT has_table_privilege('authenticated','public.account_quota_anchors','UPDATE'),
    'Binding grants no client accounting writes');
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub='16350000-0000-4000-8000-000000000003';
SELECT throws_ok($$SELECT public.bind_installation_to_owner(
    '16350000-0000-4000-8000-000000001001','16350000-0000-4000-8000-000000000001')$$,
    '42501',NULL,'Authenticated B cannot bind to A');
SELECT throws_ok($$UPDATE public.installation_access SET linked_owner_ids='{}'$$,
    '42501',NULL,'Client cannot rewrite installation ownership');
RESET ROLE;
SET LOCAL ROLE anon;
SELECT throws_ok($$SELECT public.bind_installation_to_owner(
    '16350000-0000-4000-8000-000000001001','16350000-0000-4000-8000-000000000001')$$,
    '42501',NULL,'Anon cannot bind');
RESET ROLE;
SELECT throws_ok($$SELECT pg_temp.bind_owner(1001,999)$$,'P0002','OWNER_NOT_FOUND','Missing owner rejected');
SELECT throws_ok($$SELECT pg_temp.bind_owner(1001,NULL)$$,'P0002','OWNER_NOT_FOUND','Null owner rejected');
SELECT throws_ok($$SELECT pg_temp.bind_owner(1001,2)$$,'42501','ACTIVE_PERMANENT_OWNER_REQUIRED','Anonymous target rejected');
SELECT throws_ok($$SELECT pg_temp.bind_owner(1001,9)$$,'42501','ACTIVE_PERMANENT_OWNER_REQUIRED','Deleting target rejected');
SELECT throws_ok($$SELECT pg_temp.bind_owner(1001,10)$$,'42501','ACTIVE_PERMANENT_OWNER_REQUIRED','Deleted target rejected');
SELECT throws_ok($$SELECT pg_temp.bind_owner(999,1)$$,'P0002','INSTALLATION_NOT_FOUND','Missing installation rejected');
SELECT throws_ok($$SELECT pg_temp.bind_owner(NULL,1)$$,'P0002','INSTALLATION_NOT_FOUND','Null installation rejected');
SELECT throws_ok($$SELECT pg_temp.bind_owner(1001,1,NULL)$$,'22023','INVALID_QUOTA_TIME','Null time rejected');
SELECT throws_ok($$SELECT pg_temp.bind_owner(1001,1,'infinity')$$,'22023','INVALID_QUOTA_TIME','Infinite time rejected');
SELECT throws_ok($$SELECT pg_temp.bind_owner(1001,1,'-infinity')$$,'22023','INVALID_QUOTA_TIME','Negative infinite time rejected');
SELECT is((SELECT data FROM bind_protected),(SELECT data FROM bind_protected_before),'Rejected calls preserve accounting and history');

SELECT is(pg_temp.bind_admit(101,1,NULL,'identification')->>'quota_kind','free_monthly','A has real monthly spend before binding');
SELECT is(pg_temp.bind_finish(101)->>'quota_state','consumed','A initial monthly spend settled');
SELECT is(pg_temp.bind_admit(301,3)->>'quota_kind','paid_monthly','B has independent paid usage');
SELECT is(pg_temp.bind_finish(301)->>'quota_state','consumed','B paid usage settled');
SELECT is(pg_temp.bind_admit(302,3,NULL,'identification')->>'admitted','true','B active reservation retained separately');
UPDATE bind_protected_before SET data=(SELECT data FROM bind_protected);
SET LOCAL ROLE service_role;
SELECT is(public.bind_installation_to_owner('16350000-0000-4000-8000-000000001001',
    '16350000-0000-4000-8000-000000000001','2026-11-15 10:20Z')->>'owner_id',
    '16350000-0000-4000-8000-000000000001','Service executes actual bind on linked_owner_ids schema');
RESET ROLE;
SELECT ok((SELECT starter_identification_consumed AND starter_diagnosis_consumed
    AND first_starter_success_at='2026-10-01'::timestamptz FROM public.profiles WHERE id=pg_temp.bind_id(1))
    AND (SELECT starter_identification_consumed AND starter_diagnosis_consumed
    AND first_starter_success_at='2026-10-01'::timestamptz FROM public.installation_access WHERE id=pg_temp.bind_id(1001)),
    'Both modes OR across endpoints and share earliest installation success');
SELECT is((SELECT linked_owner_ids FROM public.installation_access WHERE id=pg_temp.bind_id(1001)),
    ARRAY[pg_temp.bind_id(2),pg_temp.bind_id(3),pg_temp.bind_id(1)],'Append target without losing existing owners or order');
SELECT is((SELECT data FROM bind_protected),(SELECT data FROM bind_protected_before),
    'Bind preserves all jobs, leases, monthly usage, old counters, registration, purchases, receipts and foreign owners');
CREATE TEMP TABLE bind_repeat_before AS SELECT
    (SELECT to_jsonb(t) FROM public.profiles t WHERE id=pg_temp.bind_id(1)) AS profile,
    (SELECT to_jsonb(t) FROM public.installation_access t WHERE id=pg_temp.bind_id(1001)) AS installation;
SELECT lives_ok($$SELECT pg_temp.bind_owner(1001,1,'2026-11-16'); SELECT pg_temp.bind_owner(1001,1,'2027-01-01')$$,'Repeated and later binds succeed');
SELECT is((SELECT to_jsonb(t) FROM public.profiles t WHERE id=pg_temp.bind_id(1)),
    (SELECT profile FROM bind_repeat_before),'Repeated bind leaves entire profile unchanged');
SELECT is((SELECT to_jsonb(t) FROM public.installation_access t WHERE id=pg_temp.bind_id(1001)),
    (SELECT installation FROM bind_repeat_before),'Repeated bind leaves entire installation unchanged');
SELECT is((SELECT data FROM bind_protected),(SELECT data FROM bind_protected_before),'Retry does not refill any accounting source');
SELECT is(pg_temp.bind_admit(102,1,1001)->>'remaining_after_reserve','1','Bind leaves original monthly charge in shared quota');
SELECT is(pg_temp.bind_finish(102)->>'quota_state','consumed','Second monthly charge settles');
SELECT lives_ok($$SELECT pg_temp.bind_owner(1001,1)$$,'Bind again after additional monthly usage');
SELECT is(pg_temp.bind_admit(103,1,1001)->>'remaining_after_reserve','0','Only third monthly slot remains after rebinding');
SELECT is(pg_temp.bind_admit(104,1,1001)->>'reason','free_monthly_exhausted','Binding cannot reset exhausted Free quota');
SELECT lives_ok($$SELECT pg_temp.bind_owner(1008,8)$$,'Reverse consumed-marker direction binds');
SELECT ok((SELECT starter_identification_consumed AND starter_diagnosis_consumed
    AND first_starter_success_at='2026-09-01'::timestamptz FROM public.profiles WHERE id=pg_temp.bind_id(8))
    AND (SELECT starter_identification_consumed AND starter_diagnosis_consumed
    AND first_starter_success_at='2026-09-01'::timestamptz FROM public.installation_access WHERE id=pg_temp.bind_id(1008)),
    'Reverse OR keeps earlier owner success on both endpoints');
SELECT lives_ok($$SELECT pg_temp.bind_owner(1012,12)$$,'Legacy unknown registration can bind without inventing evidence');
SELECT is(pg_temp.bind_admit(1201,12,1012)->>'reason','quota_registration_required','Bind cannot repair unknown registration by refilling monthly access');
SELECT ok((SELECT registered_at IS NULL AND source='unresolved' FROM public.account_quota_anchors
    WHERE owner_id=pg_temp.bind_id(12)),'Unknown anchor remains unchanged');

SELECT is(pg_temp.bind_admit(201,2,1004)->>'quota_kind','starter_diagnosis','Guest reserves real diagnosis starter');
SELECT is(pg_temp.bind_finish(201,'failed')->>'quota_state','released','Guest technical failure releases starter');
SELECT lives_ok($$SELECT pg_temp.bind_owner(1004,4)$$,'Bind after guest failure');
SELECT ok((SELECT NOT starter_diagnosis_consumed AND starter_diagnosis_job_id IS NULL FROM public.profiles
    WHERE id=pg_temp.bind_id(4)),'Released guest starter grants no consumption or stale block');
SELECT is(pg_temp.bind_admit(204,4,1004)->>'quota_kind','starter_diagnosis','Permanent target can retry failed guest starter');
SELECT is(pg_temp.bind_finish(204,'failed')->>'quota_state','released','Target technical failure releases too');

SELECT is(pg_temp.bind_admit(202,2,1005,'identification')->>'admitted','true','Guest identification lease reserved');
UPDATE public.analysis_jobs SET state='running',lease_token=id,provider_started_at='2026-11-15 10:20Z',
    deadline_at='2026-11-15 10:21Z',usage='{"fixture":"lease"}'
WHERE id=pg_temp.bind_id(202);
UPDATE bind_protected_before SET data=(SELECT data FROM bind_protected);
SELECT lives_ok($$SELECT pg_temp.bind_owner(1005,5,'2026-11-16')$$,'Binding preserves a running guest lease even past its deadline');
SELECT ok((SELECT starter_identification_job_id=pg_temp.bind_id(202) AND NOT starter_identification_consumed
    FROM public.profiles WHERE id=pg_temp.bind_id(5)) AND
    (SELECT starter_identification_job_id=pg_temp.bind_id(202) FROM public.installation_access WHERE id=pg_temp.bind_id(1005)),
    'Same live reservation is mirrored, without consuming or replacing it');
SELECT is((SELECT data FROM bind_protected),(SELECT data FROM bind_protected_before),'Guest job owner, lease, payload and history stay byte-for-byte intact');
SELECT is(pg_temp.bind_admit(206,5,1005,'identification')->>'reason','starter_in_progress','Bound target cannot start a second lease');
SELECT is(pg_temp.bind_admit(206,5,NULL,'identification')->>'reason','starter_in_progress','Omitting installation cannot evade copied lease');
SELECT lives_ok($$SELECT pg_temp.bind_owner(1005,5)$$,'Repeat while guest is running preserves the same reservation');
SELECT is(pg_temp.bind_finish(202,'failed')->>'quota_state','released','Original guest finalizer releases source after binding');
SELECT lives_ok($$SELECT pg_temp.bind_owner(1005,5)$$,'Rebind resolves target pointer after source release');
SELECT ok((SELECT starter_identification_job_id IS NULL AND NOT starter_identification_consumed
    FROM public.profiles WHERE id=pg_temp.bind_id(5)) AND
    (SELECT starter_identification_job_id IS NULL AND NOT starter_identification_consumed
    FROM public.installation_access WHERE id=pg_temp.bind_id(1005)),'Released source cannot leave permanent target starter blocked');
SELECT is(pg_temp.bind_admit(206,5,1005,'identification')->>'quota_kind','starter_identification','Target can retry after released source reconciliation');

SELECT is(pg_temp.bind_admit(601,6)->>'quota_kind','starter_diagnosis','Owner-only conflicting lease reserved');
SELECT is(pg_temp.bind_admit(203,2,1006)->>'quota_kind','starter_diagnosis','Independent guest lease reserved on installation');
CREATE TEMP TABLE bind_conflict_before AS SELECT jsonb_build_object(
    'owner',(SELECT to_jsonb(t) FROM public.profiles t WHERE id=pg_temp.bind_id(6)),
    'installation',(SELECT to_jsonb(t) FROM public.installation_access t WHERE id=pg_temp.bind_id(1006)),
    'protected',(SELECT data FROM bind_protected)) AS data;
SELECT throws_ok($$SELECT pg_temp.bind_owner(1006,6)$$,'23514','STARTER_RESERVATION_CONFLICT','Two distinct live pointers fail closed');
SELECT is(jsonb_build_object(
    'owner',(SELECT to_jsonb(t) FROM public.profiles t WHERE id=pg_temp.bind_id(6)),
    'installation',(SELECT to_jsonb(t) FROM public.installation_access t WHERE id=pg_temp.bind_id(1006)),
    'protected',(SELECT data FROM bind_protected)),
    (SELECT data FROM bind_conflict_before),'Conflict preserves both pointers and all source rows atomically');
SELECT is(pg_temp.bind_finish(203,'timed_out')->>'quota_state','released','Guest source can end its conflicting lease');
SELECT lives_ok($$SELECT pg_temp.bind_owner(1006,6)$$,'Binding succeeds when only one reservation remains');
SELECT ok((SELECT starter_diagnosis_job_id=pg_temp.bind_id(601) FROM public.profiles WHERE id=pg_temp.bind_id(6))
    AND (SELECT starter_diagnosis_job_id=pg_temp.bind_id(601) FROM public.installation_access WHERE id=pg_temp.bind_id(1006)),
    'Owner-only reservation survives conflict resolution and is mirrored');
SELECT lives_ok($$SELECT pg_temp.bind_owner(1006,6)$$,'Mirrored owner-only pointer is valid on repeat bind');

SELECT is(pg_temp.bind_admit(701,7,NULL,'identification')->>'admitted','true','Reserve historical success fixture with actual RPC');
SELECT is(pg_temp.bind_finish(701)->>'quota_state','consumed','Historical source successfully consumed');
-- Emulate historical lagging markers/pointers, never substitute a production RPC.
UPDATE public.profiles SET starter_identification_consumed=false,first_starter_success_at=NULL,
    starter_identification_job_id=pg_temp.bind_id(701) WHERE id=pg_temp.bind_id(7);
UPDATE public.installation_access SET starter_identification_job_id=pg_temp.bind_id(701)
WHERE id=pg_temp.bind_id(1007);
SELECT lives_ok($$SELECT pg_temp.bind_owner(1007,7)$$,'Terminal consumed pointer reconciled');
SELECT ok((SELECT starter_identification_consumed AND starter_identification_job_id IS NULL
    AND first_starter_success_at='2026-11-16 10:20Z'::timestamptz FROM public.profiles WHERE id=pg_temp.bind_id(7))
    AND (SELECT starter_identification_consumed AND starter_identification_job_id IS NULL
    FROM public.installation_access WHERE id=pg_temp.bind_id(1007)),'Historical consumed source cannot grant a new starter');
SELECT is(pg_temp.bind_admit(702,7,1007)->>'quota_kind','starter_diagnosis','Other mode remains independent');
SELECT is(pg_temp.bind_finish(702,'failed')->>'quota_state','released','Terminal failure fixture released');
UPDATE public.profiles SET starter_diagnosis_job_id=pg_temp.bind_id(702) WHERE id=pg_temp.bind_id(7);
UPDATE public.installation_access SET starter_diagnosis_job_id=pg_temp.bind_id(702) WHERE id=pg_temp.bind_id(1007);
SELECT lives_ok($$SELECT pg_temp.bind_owner(1007,7)$$,'Stale released pointers cleared on both sides');
SELECT is(pg_temp.bind_admit(703,7,1007)->>'quota_kind','starter_diagnosis','Stale terminal pointer does not block retry');
SELECT is(pg_temp.bind_finish(703,'succeeded',true)->>'quota_state','released','Nonbillable success is a released source');
UPDATE public.profiles SET starter_diagnosis_job_id=pg_temp.bind_id(703) WHERE id=pg_temp.bind_id(7);
SELECT lives_ok($$SELECT pg_temp.bind_owner(1007,7)$$,'Nonbillable success pointer resolves without spending starter');
SELECT is(pg_temp.bind_admit(704,7,1007)->>'quota_kind','starter_diagnosis','Released success cannot become historical consumption');
UPDATE public.analysis_jobs SET state='failed' WHERE id=pg_temp.bind_id(704);
SELECT lives_ok($$SELECT pg_temp.bind_owner(1007,7)$$,'Terminal failure pending settlement releases only pointers');
SELECT is(pg_temp.bind_admit(705,7,1007)->>'quota_kind','starter_diagnosis','Technical failure can retry before deferred settlement');
SELECT is(pg_temp.bind_finish(704,'failed')->>'quota_state','released','Original terminal source still settles with 009');
SELECT ok((SELECT starter_diagnosis_job_id=pg_temp.bind_id(705) FROM public.profiles WHERE id=pg_temp.bind_id(7)),
    'Deferred finalizer preserves newer retry reservation');

SELECT is(pg_temp.bind_admit(1301,13,NULL,'identification')->>'admitted','true','Reserve unsettled owner-only success');
UPDATE public.analysis_jobs SET state='succeeded',updated_at='2026-11-15 10:21Z'
WHERE id=pg_temp.bind_id(1301);
SELECT lives_ok($$SELECT pg_temp.bind_owner(1013,13)$$,'Bind success awaiting billability settlement');
SELECT ok((SELECT NOT starter_identification_consumed AND starter_identification_job_id=pg_temp.bind_id(1301)
    AND first_starter_success_at IS NULL FROM public.profiles WHERE id=pg_temp.bind_id(13))
    AND (SELECT NOT starter_identification_consumed AND starter_identification_job_id=pg_temp.bind_id(1301)
    AND first_starter_success_at IS NULL FROM public.installation_access WHERE id=pg_temp.bind_id(1013)),
    'Unsettled success preserves both pointers without inventing consumption or first success');
SELECT is(pg_temp.bind_admit(1302,13,1013,'identification')->>'reason','starter_in_progress',
    'Unsettled success blocks another starter until billability is known');
CREATE TEMP TABLE bind_unsettled_before AS SELECT jsonb_build_object(
    'owner',(SELECT to_jsonb(t) FROM public.profiles t WHERE id=pg_temp.bind_id(13)),
    'installation',(SELECT to_jsonb(t) FROM public.installation_access t WHERE id=pg_temp.bind_id(1013))) AS data;
SELECT lives_ok($$SELECT pg_temp.bind_owner(1013,13,'2026-11-16')$$,'Repeat bind before settlement succeeds');
SELECT is(jsonb_build_object(
    'owner',(SELECT to_jsonb(t) FROM public.profiles t WHERE id=pg_temp.bind_id(13)),
    'installation',(SELECT to_jsonb(t) FROM public.installation_access t WHERE id=pg_temp.bind_id(1013))),
    (SELECT data FROM bind_unsettled_before),'Repeat bind retains unsettled endpoints byte-for-byte');
SELECT is(pg_temp.bind_finish(1301,'succeeded',true)->>'quota_state','released',
    'Nonbillable success after bind releases the original owner-only reservation');
SELECT lives_ok($$SELECT pg_temp.bind_owner(1013,13)$$,'Rebind resolves copied owner-only released pointer');
SELECT ok((SELECT NOT starter_identification_consumed AND starter_identification_job_id IS NULL
    AND first_starter_success_at IS NULL FROM public.profiles WHERE id=pg_temp.bind_id(13))
    AND (SELECT NOT starter_identification_consumed AND starter_identification_job_id IS NULL
    AND first_starter_success_at IS NULL FROM public.installation_access WHERE id=pg_temp.bind_id(1013)),
    'Nonbillable settlement leaves both starters unspent and unblocked');
SELECT is(pg_temp.bind_admit(1302,13,1013,'identification')->>'quota_kind','starter_identification',
    'Nonbillable owner-only success can retry a starter after bind');
SELECT is(pg_temp.bind_finish(1302)->>'quota_state','consumed','Billable retry consumes the starter');
SELECT is(pg_temp.bind_owner(1013,13)->>'starter_identification_consumed','true',
    'Rebinding after billable retry preserves permanent consumption');

SELECT is(pg_temp.bind_admit(207,2,1015)->>'quota_kind','starter_diagnosis',
    'Guest reserves diagnosis before unsettled success bind');
UPDATE public.analysis_jobs SET state='succeeded',updated_at='2026-11-15 10:21Z'
WHERE id=pg_temp.bind_id(207);
SELECT lives_ok($$SELECT pg_temp.bind_owner(1015,15)$$,'Bind unsettled successful guest source');
SELECT ok((SELECT NOT starter_diagnosis_consumed AND starter_diagnosis_job_id=pg_temp.bind_id(207)
    AND first_starter_success_at IS NULL FROM public.profiles WHERE id=pg_temp.bind_id(15))
    AND (SELECT NOT starter_diagnosis_consumed AND starter_diagnosis_job_id=pg_temp.bind_id(207)
    AND first_starter_success_at IS NULL FROM public.installation_access WHERE id=pg_temp.bind_id(1015)),
    'Guest success awaiting settlement mirrors a blocking pointer without consumption');
SELECT is(pg_temp.bind_admit(1501,15,1015)->>'reason','starter_in_progress',
    'Target cannot bypass unsettled guest reservation');
SELECT is(pg_temp.bind_finish(207,'succeeded',true)->>'quota_state','released',
    'Guest nonbillable settlement releases source after binding');
SELECT lives_ok($$SELECT pg_temp.bind_owner(1015,15)$$,'Rebind resolves copied guest pointer after nonbillable release');
SELECT ok((SELECT NOT starter_diagnosis_consumed AND starter_diagnosis_job_id IS NULL
    AND first_starter_success_at IS NULL FROM public.profiles WHERE id=pg_temp.bind_id(15))
    AND (SELECT NOT starter_diagnosis_consumed AND starter_diagnosis_job_id IS NULL
    AND first_starter_success_at IS NULL FROM public.installation_access WHERE id=pg_temp.bind_id(1015)),
    'Released guest success cannot leave a consumed marker or permanent starter block');
SELECT is(pg_temp.bind_admit(1501,15,1015)->>'quota_kind','starter_diagnosis',
    'Permanent target can retry after guest nonbillable settlement');
SELECT is(pg_temp.bind_finish(1501)->>'quota_state','consumed','Target billable retry consumes diagnosis starter');
SELECT is(pg_temp.bind_owner(1015,15)->>'starter_diagnosis_consumed','true',
    'Guest-path retry consumption remains permanent after rebind');

SELECT is(pg_temp.bind_admit(1401,14,NULL,'identification')->>'admitted','true','Owner-only lease reserved without installation');
SELECT lives_ok($$SELECT pg_temp.bind_owner(1014,14); SELECT pg_temp.bind_owner(1014,14)$$,'Owner-only live pointer survives binding and retry');
SELECT is(pg_temp.bind_admit(1402,14,1014,'identification')->>'reason','starter_in_progress','Owner-only lease still blocks a second starter');
SELECT is(pg_temp.bind_finish(1401)->>'quota_state','consumed','Owner-only source settles successfully');
SELECT lives_ok($$SELECT pg_temp.bind_owner(1014,14)$$,'Rebind resolves copied pointer after owner-only source success');
SELECT ok((SELECT starter_identification_consumed AND starter_identification_job_id IS NULL
    FROM public.installation_access WHERE id=pg_temp.bind_id(1014)),'Owner-only success reaches installation without moving job ownership');

-- A pointer to an unrelated monthly job must not be silently erased or adopted.
UPDATE public.profiles SET starter_diagnosis_job_id=pg_temp.bind_id(301) WHERE id=pg_temp.bind_id(14);
UPDATE bind_protected_before SET data=(SELECT data FROM bind_protected);
SELECT throws_ok($$SELECT pg_temp.bind_owner(1014,14)$$,'23514','STARTER_HISTORY_UNRESOLVED','Non-starter pointer fails closed');
SELECT is((SELECT data FROM bind_protected),(SELECT data FROM bind_protected_before),'Invalid pointer does not mutate foreign monthly history');
SELECT ok((SELECT starter_diagnosis_job_id=pg_temp.bind_id(301) FROM public.profiles WHERE id=pg_temp.bind_id(14)),
    'Invalid pointer remains available for investigation');
SELECT * FROM finish();
ROLLBACK;
