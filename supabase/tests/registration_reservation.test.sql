-- Reservation-only, real schema/RPCs. Historical fixture inserts are not settlement.
-- Controller additionally runs clean/upgrade preservation and four 20-connection races.
BEGIN;
SELECT plan(78);

CREATE FUNCTION pg_temp.reserve_id(n integer) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$
    SELECT ('16330000-0000-4000-8000-' || lpad(n::text,12,'0'))::uuid
$$;
CREATE FUNCTION pg_temp.seed_reserve_job(n integer, owner_n integer, mode text DEFAULT 'diagnosis',
    at_time timestamptz DEFAULT '2026-11-15 10:20Z') RETURNS void LANGUAGE sql AS $$
    INSERT INTO public.analysis_jobs(id,owner_id,flow_id,intent,add_method,mode,kb_release_id,
        prompt_version,operation_id,payload_hash,locale,quota_kind,quota_state,created_at)
    VALUES(pg_temp.reserve_id(n),pg_temp.reserve_id(owner_n),pg_temp.reserve_id(n),'problem','scan',
        mode,pg_temp.reserve_id(100),'reserve-fixture',pg_temp.reserve_id(n),'hash-' || n,
        'en','none','not_applicable',at_time)
$$;
-- Transparent convenience wrapper: every assertion executes the production RPC.
CREATE FUNCTION pg_temp.reserve(n integer, owner_n integer, installation_n integer DEFAULT NULL,
    mode text DEFAULT 'diagnosis', at_time timestamptz DEFAULT '2026-11-15 10:20Z')
RETURNS jsonb LANGUAGE sql AS $$
    SELECT public.admit_analysis_quota(mode,pg_temp.reserve_id(owner_n),
        pg_temp.reserve_id(installation_n),pg_temp.reserve_id(n),at_time)
$$;

INSERT INTO public.profiles(id,anonymous,created_at,starter_identification_consumed,starter_diagnosis_consumed)
SELECT pg_temp.reserve_id(n), n=5, '2026-01-31 10:20Z'::timestamptz,
       n NOT IN (3,4,5), n NOT IN (3,4,5)
FROM generate_series(1,16) n WHERE n NOT IN (6,15);
-- Emulate pre-005 permanent profiles without evidence; restore the real trigger
-- before assertions. No anchor guard or RPC is replaced.
ALTER TABLE public.profiles DISABLE TRIGGER trg_profiles_registration_anchor;
INSERT INTO public.profiles(id,anonymous,created_at,starter_identification_consumed,starter_diagnosis_consumed)
VALUES(pg_temp.reserve_id(6),false,'2020-01-01',true,true),
      (pg_temp.reserve_id(15),false,'2020-01-01',false,false);
ALTER TABLE public.profiles ENABLE TRIGGER trg_profiles_registration_anchor;
INSERT INTO public.account_quota_anchors(owner_id,registered_at,source)
VALUES(pg_temp.reserve_id(6),NULL,'unresolved'),(pg_temp.reserve_id(15),NULL,'unresolved');
UPDATE public.profiles SET account_state='deleting' WHERE id=pg_temp.reserve_id(14);
INSERT INTO public.installation_access(id,credential_hash,linked_owner_ids)
SELECT pg_temp.reserve_id(n),'reserve-installation-' || n,ARRAY[pg_temp.reserve_id(owner_n)]
FROM (VALUES(101,4),(102,2),(103,5),(104,4),(105,16)) f(n,owner_n);
INSERT INTO public.kb_releases(id,version,state,manifest_sha256,published_at)
VALUES(pg_temp.reserve_id(100),'reserve-fixture','retired',repeat('a',64),'2026-01-01');
INSERT INTO public.entitlements(owner_id,product_id,state,offer_kind,valid_until)
VALUES(pg_temp.reserve_id(3),'app.narat.plants.pro.monthly','active','paid','2027-12-01');

INSERT INTO public.monthly_quotas(id,owner_id,quota_kind,period_start,period_end,
    limit_count,consumed_count,reserved_count)
SELECT pg_temp.reserve_id(n),pg_temp.reserve_id(owner_n),'paid_monthly',start_at::timestamptz,
       end_at::timestamptz,100,consumed,0
FROM (VALUES
    (900,7,'2026-09-01','2026-10-01',7),
    (909,8,'2026-11-01','2026-12-01',1),
    (910,11,'2026-11-01','2026-12-01',0),
    (911,12,'2026-09-01','2026-10-01',1),
    (912,13,'2026-11-01','2026-12-01',0)
) f(n,owner_n,start_at,end_at,consumed);
DO $fixtures$
DECLARE r record;
BEGIN
    FOR r IN SELECT * FROM (VALUES
        (200,1,'identification'),(201,1,'diagnosis'),(202,1,'diagnosis'),
        (203,1,'diagnosis'),(204,1,'diagnosis'),(205,1,'diagnosis'),(206,1,'diagnosis'),
        (207,2,'diagnosis'),(300,3,'identification'),(400,3,'diagnosis'),
        (500,4,'identification'),(501,4,'diagnosis'),(502,4,'diagnosis'),(503,4,'diagnosis'),
        (504,4,'diagnosis'),(505,4,'identification'),(506,4,'diagnosis'),
        (600,5,'diagnosis'),(601,5,'diagnosis'),(602,5,'diagnosis'),(603,5,'diagnosis'),
        (606,5,'identification'),(700,2,'diagnosis'),(701,2,'diagnosis'),(702,2,'diagnosis'),
        (703,2,'diagnosis'),(704,2,'diagnosis'),(800,6,'diagnosis'),(801,15,'diagnosis'),
        (802,7,'diagnosis'),(803,8,'diagnosis'),(804,9,'diagnosis'),(805,10,'diagnosis'),
        (806,11,'diagnosis'),(807,12,'diagnosis'),(808,13,'diagnosis'),(809,13,'diagnosis'),
        (810,9,'diagnosis'),(820,10,'diagnosis'),(830,11,'diagnosis'),(840,12,'diagnosis'),
        (850,16,'diagnosis'),(901,16,'identification'),(950,14,'diagnosis')
    ) f(n,owner_n,mode) LOOP
        PERFORM pg_temp.seed_reserve_job(r.n,r.owner_n,r.mode);
    END LOOP;
END;
$fixtures$;
UPDATE public.analysis_jobs SET quota_installation_id=pg_temp.reserve_id(101)
WHERE id=pg_temp.reserve_id(503);
UPDATE public.analysis_jobs SET created_at='2026-10-30 10:20Z' WHERE id=pg_temp.reserve_id(808);
UPDATE public.analysis_jobs SET quota_kind='paid_monthly',quota_state='consumed',state='succeeded',
    quota_owner_id=owner_id WHERE id IN
    (pg_temp.reserve_id(700),pg_temp.reserve_id(810),pg_temp.reserve_id(820),
     pg_temp.reserve_id(830),pg_temp.reserve_id(840));
UPDATE public.analysis_jobs SET quota_kind='free_monthly',quota_state='released',state='failed'
WHERE id=pg_temp.reserve_id(701);
UPDATE public.analysis_jobs SET quota_kind='paid_monthly',quota_state='reserved',state='running',
    lease_token=id,provider_started_at='2026-11-15 10:20Z'
WHERE id IN (pg_temp.reserve_id(702),pg_temp.reserve_id(703));
UPDATE public.analysis_jobs SET state='running' WHERE id=pg_temp.reserve_id(704);
UPDATE public.analysis_jobs SET created_at='2026-09-15 10:20Z'
WHERE id IN (pg_temp.reserve_id(702),pg_temp.reserve_id(840));
UPDATE public.analysis_jobs SET created_at='-infinity' WHERE id=pg_temp.reserve_id(810);
UPDATE public.analysis_jobs SET quota_owner_id=pg_temp.reserve_id(2) WHERE id=pg_temp.reserve_id(820);
UPDATE public.analysis_jobs SET monthly_quota_id=pg_temp.reserve_id(910) WHERE id=pg_temp.reserve_id(830);
UPDATE public.analysis_jobs SET monthly_quota_id=pg_temp.reserve_id(911) WHERE id=pg_temp.reserve_id(840);
UPDATE public.analysis_jobs SET quota_kind='starter_identification',quota_state='consumed',state='succeeded'
WHERE id=pg_temp.reserve_id(901);
UPDATE public.profiles SET starter_identification_job_id=pg_temp.reserve_id(901)
WHERE id=pg_temp.reserve_id(16);
INSERT INTO public.account_quota_usage(job_id,owner_id,period_start,period_end,quota_state)
SELECT id,owner_id,'2026-10-31 10:20Z','2026-11-30 10:20Z',
       CASE WHEN id=pg_temp.reserve_id(701) THEN 'released' ELSE 'consumed' END
FROM public.analysis_jobs WHERE id IN
    (pg_temp.reserve_id(700),pg_temp.reserve_id(701),pg_temp.reserve_id(703));

CREATE TEMP TABLE reserve_anchors_before AS
SELECT jsonb_agg(to_jsonb(a) ORDER BY owner_id) data FROM public.account_quota_anchors a;
CREATE TEMP TABLE reserve_legacy_before AS
SELECT jsonb_agg(to_jsonb(q) ORDER BY id) data FROM public.monthly_quotas q;
CREATE TEMP VIEW reserve_independent_state AS
SELECT jsonb_build_object(
    'budget',(SELECT COALESCE(jsonb_agg(to_jsonb(t) ORDER BY utc_date),'[]') FROM public.provider_daily_budget t),
    'receipts',(SELECT COALESCE(jsonb_agg(to_jsonb(t) ORDER BY owner_id,operation_id),'[]') FROM public.operation_receipts t),
    'plants',(SELECT COALESCE(jsonb_agg(to_jsonb(t) ORDER BY id),'[]') FROM public.plants t),
    'care',(SELECT COALESCE(jsonb_agg(to_jsonb(t) ORDER BY id),'[]') FROM public.basic_care_memberships t)
) data;
CREATE TEMP TABLE reserve_independent_before AS SELECT data FROM reserve_independent_state;

SELECT ok((SELECT prosecdef AND proconfig @> ARRAY['search_path=""'] FROM pg_proc
    WHERE oid='public.admit_analysis_quota(text,uuid,uuid,uuid,timestamptz)'::regprocedure),
    'Admission pins an empty definer search_path');
SELECT ok(NOT EXISTS (
    SELECT 1 FROM pg_proc p,
    LATERAL aclexplode(COALESCE(p.proacl,acldefault('f',p.proowner))) a
    WHERE p.oid='public.admit_analysis_quota(text,uuid,uuid,uuid,timestamptz)'::regprocedure
      AND a.grantee IN (0,'anon'::regrole::oid,'authenticated'::regrole::oid)
      AND a.privilege_type='EXECUTE'), 'PUBLIC and clients cannot reserve');
SELECT ok(has_function_privilege('service_role',
    'public.admit_analysis_quota(text,uuid,uuid,uuid,timestamptz)','EXECUTE'), 'Service can reserve');
SELECT is(pg_temp.reserve(200,1,NULL,'identification')->>'remaining_after_reserve','2',
    'Free gets three immediately, without first starter success or calendar wait');
SELECT is(pg_temp.reserve(201,1)->>'remaining_after_reserve','1','Diagnosis shares identification usage');
SELECT is(pg_temp.reserve(202,1)->>'remaining_after_reserve','0','The third shared reservation is admitted');
SELECT is(pg_temp.reserve(203,1)->>'reason','free_monthly_exhausted','Fourth reservation is denied');
SELECT is((SELECT count(*) FROM public.account_quota_usage WHERE owner_id=pg_temp.reserve_id(1)),
    3::bigint,'Exactly three Free ledger rows exist');
SELECT ok((SELECT bool_and(quota_kind='free_monthly' AND quota_state='reserved'
    AND quota_owner_id=owner_id AND monthly_quota_id IS NULL)
    FROM public.analysis_jobs WHERE id IN (pg_temp.reserve_id(200),pg_temp.reserve_id(201),pg_temp.reserve_id(202))),
    'Admission atomically persists canonical jobs without a fabricated legacy pointer');
SELECT ok((SELECT bool_and(period_start='2026-10-31 10:20Z'::timestamptz
    AND period_end='2026-11-30 10:20Z'::timestamptz) FROM public.account_quota_usage
    WHERE owner_id=pg_temp.reserve_id(1)), 'Registration UTC window is returned and recorded');
SELECT is((SELECT jsonb_build_object('admitted',q->'admitted','remaining',q->'remaining_after_reserve')
    FROM (SELECT pg_temp.reserve(207,2) AS q) result),
    '{"admitted":true,"remaining":0}'::jsonb,
    'B admits its third own charge; A usage does not affect B');
CREATE TEMP TABLE reserve_replay_before AS SELECT to_jsonb(j) data FROM public.analysis_jobs j
WHERE id=pg_temp.reserve_id(200);
SELECT is(pg_temp.reserve(200,1,NULL,'identification')->>'admitted','true','Reserved job replay is admitted');
SELECT is((SELECT count(*) FROM public.account_quota_usage WHERE owner_id=pg_temp.reserve_id(1)),
    3::bigint,'Replay does not create usage');
SELECT is((SELECT to_jsonb(j) FROM public.analysis_jobs j WHERE id=pg_temp.reserve_id(200)),
    (SELECT data FROM reserve_replay_before),'Replay preserves the entire job');

INSERT INTO public.entitlements(owner_id,product_id,state,offer_kind,valid_until,trial_end_at)
VALUES(pg_temp.reserve_id(1),'app.narat.plants.pro.yearly','active','trial','2027-12-01','2027-01-01');
SELECT is(pg_temp.reserve(204,1)->>'remaining_after_reserve','96','Trial shares the three Free reservations');
UPDATE public.entitlements SET offer_kind='paid',trial_end_at=NULL WHERE owner_id=pg_temp.reserve_id(1);
SELECT is(pg_temp.reserve(205,1)->>'remaining_after_reserve','95','Trial to paid does not reset usage');
UPDATE public.entitlements SET state='expired' WHERE owner_id=pg_temp.reserve_id(1);
SELECT is(pg_temp.reserve(206,1)->>'reason','free_monthly_exhausted','Expiry does not refill Free');
SELECT is(pg_temp.reserve(206,1,NULL,'diagnosis','2026-11-30 10:20Z')->>'remaining_after_reserve','2',
    'Exact period end starts a fresh registration month');

SELECT is(pg_temp.reserve(300,3,NULL,'identification')->>'quota_kind','paid_monthly',
    'Verified paid bypasses unused starter and permits no installation');
-- 99 HISTORICAL consumed fixtures plus one actual reservation; no finalizer calls.
DO $$DECLARE n integer; BEGIN FOR n IN 301..399 LOOP
    PERFORM pg_temp.seed_reserve_job(n,3);
END LOOP; END$$;
UPDATE public.analysis_jobs SET quota_kind='paid_monthly',quota_state='consumed',state='succeeded'
WHERE owner_id=pg_temp.reserve_id(3) AND id<>pg_temp.reserve_id(300) AND id<>pg_temp.reserve_id(400);
INSERT INTO public.account_quota_usage(job_id,owner_id,period_start,period_end,quota_state)
SELECT id,owner_id,'2026-10-31 10:20Z','2026-11-30 10:20Z','consumed'
FROM public.analysis_jobs WHERE owner_id=pg_temp.reserve_id(3) AND quota_state='consumed';
SELECT is(pg_temp.reserve(400,3)->>'reason','paid_monthly_exhausted','Paid 100 has no starter or Free fallback');
SELECT ok((SELECT NOT starter_identification_consumed AND NOT starter_diagnosis_consumed
    AND starter_identification_job_id IS NULL AND starter_diagnosis_job_id IS NULL
    FROM public.profiles WHERE id=pg_temp.reserve_id(3)), 'Paid leaves both unused starters intact');
SELECT is((SELECT count(*) FROM public.account_quota_usage WHERE owner_id=pg_temp.reserve_id(3)),
    100::bigint,'Paid exhaustion cannot add a 101st usage row');

SELECT is(pg_temp.reserve(500,4,101,'identification')->>'quota_kind','starter_identification',
    'Free reserves its unused identification starter first');
SELECT is(pg_temp.reserve(501,4,101)->>'quota_kind','starter_diagnosis','Diagnosis starter is independent');
SELECT is(pg_temp.reserve(502,4,101)->>'reason','starter_in_progress','Second diagnosis cannot reserve in parallel');
SELECT is(pg_temp.reserve(502,4,101)->>'in_progress_job_id',pg_temp.reserve_id(501)::text,
    'Conflict identifies the actual in-progress diagnosis');
SELECT ok((SELECT starter_identification_job_id=pg_temp.reserve_id(500)
    AND starter_diagnosis_job_id=pg_temp.reserve_id(501)
    AND NOT starter_identification_consumed AND NOT starter_diagnosis_consumed
    FROM public.profiles WHERE id=pg_temp.reserve_id(4)), 'Profile retains separate pointers and unconsumed markers');
SELECT ok((SELECT starter_identification_job_id=pg_temp.reserve_id(500)
    AND starter_diagnosis_job_id=pg_temp.reserve_id(501)
    AND NOT starter_identification_consumed AND NOT starter_diagnosis_consumed
    FROM public.installation_access WHERE id=pg_temp.reserve_id(101)), 'Installation retains separate reservation pointers');
SELECT ok((SELECT quota_state='reserved' AND quota_kind='starter_diagnosis'
    AND quota_installation_id=pg_temp.reserve_id(101) AND quota_owner_id=owner_id
    FROM public.analysis_jobs WHERE id=pg_temp.reserve_id(501)), 'Starter persists job reservation identity');
SELECT is(pg_temp.reserve(500,4,101,'identification')->>'admitted','true','Starter replay is admitted');
SELECT is((SELECT count(*) FROM public.account_quota_usage WHERE owner_id=pg_temp.reserve_id(4)),
    0::bigint,'Starters never charge monthly usage');
SELECT is(pg_temp.reserve(850,16,105)->>'quota_kind','free_monthly',
    'Consumed profile marker wins over an unused installation marker');
SELECT is(pg_temp.reserve(600,5,103)->>'quota_kind','starter_diagnosis','Guest with its own installation can reserve');
SELECT is(pg_temp.reserve(601,5)->>'reason','installation_required','Guest cannot omit installation');
SELECT is(pg_temp.reserve(602,5,999)->>'reason','installation_not_found','Unknown installation is rejected');
SELECT is(pg_temp.reserve(603,5,102)->>'reason','installation_owner_mismatch','Guest cannot borrow B installation');
UPDATE public.profiles SET starter_identification_consumed=true WHERE id=pg_temp.reserve_id(5);
SELECT is(pg_temp.reserve(606,5,103,'identification')->>'reason','starter_exhausted',
    'Consumed guest starter never unlocks monthly quota');
SELECT is(pg_temp.reserve(504,4,102)->>'reason','installation_owner_mismatch','Permanent owner cannot borrow B installation');
SELECT is(pg_temp.reserve(503,4,104)->>'reason','job_installation_mismatch','Existing job installation cannot change');
SELECT is(pg_temp.reserve(500,4,NULL,'identification')->>'reason','job_installation_mismatch',
    'Replay cannot erase original installation identity');
SELECT is(pg_temp.reserve(200,2,NULL,'identification')->>'reason','job_not_found','B cannot use A job');
SELECT is(pg_temp.reserve(200,1)->>'reason','job_mode_mismatch','Job mode must match request');
SELECT is(pg_temp.reserve(999,1)->>'reason','job_not_found','Unknown job is rejected');
SELECT is(pg_temp.reserve(950,14)->>'reason','account_inactive','Inactive owner is rejected');
SELECT is(pg_temp.reserve(200,999,NULL,'identification')->>'reason','account_inactive','Unknown owner is rejected');
SELECT throws_ok($$SELECT pg_temp.reserve(200,1,NULL,NULL)$$,'22023','INVALID_ANALYSIS_MODE','NULL mode is rejected');
SELECT throws_ok($$SELECT pg_temp.reserve(200,1,NULL,'follow_up')$$,'22023','INVALID_ANALYSIS_MODE','New follow_up is rejected');
SELECT throws_ok($$SELECT pg_temp.reserve(200,1,NULL,'plan')$$,'22023','INVALID_ANALYSIS_MODE','Plan cannot reserve quota');
SELECT throws_ok($$SELECT pg_temp.reserve(200,1,NULL,'identification','infinity')$$,
    '22023','INVALID_QUOTA_TIME','Infinite service clock is rejected');
SELECT throws_ok($$SELECT pg_temp.seed_reserve_job(999,1,'identification');
    UPDATE public.analysis_jobs SET operation_id=pg_temp.reserve_id(200) WHERE id=pg_temp.reserve_id(999)$$,
    '23505',NULL,'Existing owner/operation uniqueness preserves operation identity');
SELECT is((SELECT count(*) FROM public.analysis_jobs WHERE id=pg_temp.reserve_id(999)),0::bigint,
    'Rejected duplicate operation leaves no second job');

SELECT is(pg_temp.reserve(700,2)->>'admitted','false','Consumed job cannot reserve again');
SELECT is(pg_temp.reserve(701,2)->>'admitted','false','Released job cannot reserve again');
SELECT is(pg_temp.reserve(703,2)->>'admitted','false','Terminal ledger blocks a stale reserved job');
SELECT is(pg_temp.reserve(704,2)->>'reason','job_not_reservable','Unreserved running job cannot start a reservation');
CREATE TEMP TABLE reserve_running_before AS SELECT to_jsonb(j) data FROM public.analysis_jobs j
WHERE id=pg_temp.reserve_id(702);
SELECT is(pg_temp.reserve(702,2)->>'admitted','true','Existing running reservation is imported and replayed');
SELECT is((pg_temp.reserve(702,2)->>'period_start')::timestamptz,'2026-08-31 10:20Z'::timestamptz,
    'Running replay retains its original reservation window');
SELECT is((SELECT to_jsonb(j) FROM public.analysis_jobs j WHERE id=pg_temp.reserve_id(702)),
    (SELECT data FROM reserve_running_before),'Import/replay preserve every running lease/job field');
SELECT is((SELECT count(*) FROM public.account_quota_usage WHERE job_id=pg_temp.reserve_id(702)),
    1::bigint,'Running replay has exactly one imported ledger row');
SELECT is(pg_temp.reserve(800,6)->>'reason','quota_registration_required','Unknown registration fails closed for monthly');
SELECT is(pg_temp.reserve(801,15)->>'quota_kind','starter_diagnosis','Missing anchor does not withhold an unused starter');
SELECT is(pg_temp.reserve(802,7)->>'remaining_after_reserve','2','Old nonoverlapping residual neither blocks nor charges current Free');
SELECT ok((SELECT unallocated_consumed=7 AND requires_review FROM public.quota_legacy_reconciliation
    WHERE monthly_quota_id=pg_temp.reserve_id(900)), 'Old unresolved aggregate is retained for investigation');
SELECT is(pg_temp.reserve(803,8)->>'reason','quota_history_unresolved','Overlapping current residual fails closed');
SELECT is(pg_temp.reserve(804,9)->>'reason','quota_history_unresolved','Unmappable pointerless job honors reconciliation result');
SELECT is(pg_temp.reserve(805,10)->>'reason','quota_history_unresolved','Contradictory quota owner fails closed without aggregate');
SELECT is(pg_temp.reserve(806,11)->>'reason','quota_history_unresolved','Counters smaller than known current jobs fail closed');
SELECT is(pg_temp.reserve(807,12)->>'remaining_after_reserve','2','Known old ledger consumption is not current spend');
SELECT is(pg_temp.reserve(808,13)->>'remaining_after_reserve','2','New canonical job uses actual reserve time across boundary');
SELECT is(pg_temp.reserve(809,13)->>'remaining_after_reserve','1',
    'Reconcile cannot remap canonical reservation to job creation window');
SELECT ok((SELECT requires_review AND unallocated_consumed=0 AND unallocated_reserved=0
    FROM public.quota_legacy_reconciliation WHERE monthly_quota_id=pg_temp.reserve_id(912)),
    'Inherited review flag alone is distinguished from real source contradictions');
SELECT ok(NOT EXISTS (SELECT 1 FROM public.account_quota_usage WHERE job_id IN
    (pg_temp.reserve_id(800),pg_temp.reserve_id(803),pg_temp.reserve_id(804),
     pg_temp.reserve_id(805),pg_temp.reserve_id(806))), 'Denied monthly jobs never acquire reservations');
SELECT is((SELECT jsonb_agg(to_jsonb(a) ORDER BY owner_id) FROM public.account_quota_anchors a),
    (SELECT data FROM reserve_anchors_before),'Admission, tariff changes and expiry leave all anchors unchanged');
SELECT is((SELECT jsonb_agg(to_jsonb(q) ORDER BY id) FROM public.monthly_quotas q),
    (SELECT data FROM reserve_legacy_before),'Legacy quota rows and counters remain byte-for-byte unchanged');
SELECT is((SELECT data FROM reserve_independent_state),(SELECT data FROM reserve_independent_before),
    'Provider budget, collection/care and receipts remain byte-for-byte unchanged');

SET LOCAL ROLE authenticated;
SELECT throws_ok($$SELECT public.admit_analysis_quota('diagnosis',
    '16330000-0000-4000-8000-000000000001',NULL,'16330000-0000-4000-8000-000000000201')$$,
    '42501',NULL,'Authenticated cannot reserve for any owner');
RESET ROLE;
SET LOCAL ROLE anon;
SELECT throws_ok($$SELECT public.admit_analysis_quota('diagnosis',
    '16330000-0000-4000-8000-000000000001',NULL,'16330000-0000-4000-8000-000000000201')$$,
    '42501',NULL,'Anon cannot invoke the trusted gate');
RESET ROLE;
SET LOCAL ROLE service_role;
SELECT lives_ok($$SELECT public.admit_analysis_quota('identification',
    '16330000-0000-4000-8000-000000000001',NULL,'16330000-0000-4000-8000-000000000200',
    '2026-11-15 10:20Z')$$,'Real service role can replay an existing reservation');
RESET ROLE;

SELECT * FROM finish();
ROLLBACK;
