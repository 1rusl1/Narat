-- Actual production RPCs on synthetic fixtures; no bind/provider/API calls.
-- Controller separately runs clean/upgrade retention and six 20-connection rounds.
BEGIN;
SELECT plan(89);

CREATE FUNCTION pg_temp.final_id(n integer) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$
    SELECT ('16340000-0000-4000-8000-' || lpad(n::text,12,'0'))::uuid
$$;
CREATE FUNCTION pg_temp.seed_final_job(p_n integer, p_owner integer, p_mode text DEFAULT 'diagnosis')
RETURNS void LANGUAGE sql AS $$
    INSERT INTO public.analysis_jobs(id,owner_id,flow_id,intent,add_method,mode,kb_release_id,
        prompt_version,operation_id,payload_hash,locale,quota_kind,quota_state,created_at)
    VALUES(pg_temp.final_id(p_n),pg_temp.final_id(p_owner),pg_temp.final_id(p_n),'problem','scan',
        p_mode,pg_temp.final_id(100),'finalize-fixture',pg_temp.final_id(p_n),'hash-' || p_n,
        'en','none','not_applicable','2026-11-15 10:20Z')
$$;
CREATE FUNCTION pg_temp.final_admit(p_n integer, p_owner integer, p_install integer DEFAULT NULL,
    p_mode text DEFAULT 'diagnosis') RETURNS jsonb LANGUAGE sql AS $$
    SELECT public.admit_analysis_quota(p_mode,pg_temp.final_id(p_owner),
        pg_temp.final_id(p_install),pg_temp.final_id(p_n),'2026-11-15 10:20Z')
$$;
CREATE FUNCTION pg_temp.settle(p_n integer, p_outcome text DEFAULT 'succeeded',
    p_nonbillable boolean DEFAULT false, p_now timestamptz DEFAULT '2026-11-15 10:20Z')
RETURNS jsonb LANGUAGE sql AS $$
    SELECT public.finalize_analysis_quota(pg_temp.final_id(p_n),p_outcome,p_nonbillable,p_now)
$$;

INSERT INTO public.profiles(id,anonymous,created_at,starter_identification_consumed,starter_diagnosis_consumed)
SELECT pg_temp.final_id(n),n=3,'2026-01-31 10:20Z'::timestamptz,n IN (1,2,5,9),n IN (1,2,5,9)
FROM generate_series(1,9) n WHERE n<>4;
-- Historical owner with genuinely unknown registration. Restore the trigger
-- before exercising any RPC; production guards/functions are never replaced.
ALTER TABLE public.profiles DISABLE TRIGGER trg_profiles_registration_anchor;
INSERT INTO public.profiles(id,anonymous,created_at,starter_identification_consumed,starter_diagnosis_consumed)
VALUES(pg_temp.final_id(4),false,'2020-01-01',true,true);
ALTER TABLE public.profiles ENABLE TRIGGER trg_profiles_registration_anchor;
INSERT INTO public.account_quota_anchors VALUES(pg_temp.final_id(4),NULL,'unresolved');
INSERT INTO public.installation_access(id,credential_hash,linked_owner_ids)
SELECT pg_temp.final_id(n),'final-install-' || n,ARRAY[pg_temp.final_id(owner_n)]
FROM (VALUES(1303,3),(1306,6),(1308,8)) f(n,owner_n);
INSERT INTO public.kb_releases(id,version,state,manifest_sha256,published_at)
VALUES(pg_temp.final_id(100),'finalize-fixture','retired',repeat('a',64),'2026-01-01');
DO $seed$
DECLARE r record;
BEGIN
    FOR r IN SELECT * FROM (VALUES
        (101,1,'diagnosis'),(102,1,'identification'),(103,1,'diagnosis'),
        (104,1,'diagnosis'),(105,1,'diagnosis'),(106,1,'diagnosis'),
        (107,1,'diagnosis'),(108,1,'diagnosis'),(109,1,'identification'),(110,1,'diagnosis'),
        (301,3,'identification'),(302,3,'diagnosis'),(303,3,'diagnosis'),(305,3,'diagnosis'),
        (401,4,'diagnosis'),(402,4,'diagnosis'),(403,4,'diagnosis'),(404,4,'diagnosis'),
        (501,5,'follow_up'),(502,5,'diagnosis'),
        (601,6,'diagnosis'),(602,6,'diagnosis'),(603,6,'identification'),
        (701,7,'identification'),(801,8,'diagnosis'),
        (901,9,'diagnosis'),(902,9,'diagnosis'),(903,9,'diagnosis'),
        (904,9,'diagnosis'),(905,9,'diagnosis'),(906,9,'diagnosis'),(907,9,'diagnosis')
    ) f(n,owner_n,mode)
    LOOP
        PERFORM pg_temp.seed_final_job(r.n,r.owner_n,r.mode);
    END LOOP;
END;
$seed$;
INSERT INTO public.monthly_quotas(id,owner_id,quota_kind,period_start,period_end,limit_count,consumed_count,reserved_count)
SELECT pg_temp.final_id(n),pg_temp.final_id(owner_n),kind,'2026-11-01','2026-12-01',
       CASE WHEN kind='paid_monthly' THEN 100 ELSE 1 END,consumed,reserved
FROM (VALUES(1401,4,'paid_monthly',7,3),(1501,5,'paid_monthly',0,2),
    (1901,9,'paid_monthly',0,0),(1902,2,'paid_monthly',0,1),
    (1903,9,'free_monthly',0,1)) f(n,owner_n,kind,consumed,reserved);
UPDATE public.analysis_jobs SET quota_kind='paid_monthly',quota_state='reserved',
    quota_owner_id=owner_id,state='running',lease_token=id,provider_started_at=created_at,
    monthly_quota_id=CASE WHEN owner_id=pg_temp.final_id(4) THEN pg_temp.final_id(1401)
                         ELSE pg_temp.final_id(1501) END
WHERE id IN (pg_temp.final_id(401),pg_temp.final_id(402),pg_temp.final_id(403),
             pg_temp.final_id(501),pg_temp.final_id(502));
INSERT INTO public.operation_receipts(owner_id,operation_id,command_name,payload_hash,response_payload)
VALUES(pg_temp.final_id(5),pg_temp.final_id(501),'analysis.start','fixture',
    jsonb_build_object('job_id',pg_temp.final_id(501),'receipt','signed-fixture'));
INSERT INTO public.provider_daily_budget(utc_date,started_calls,max_calls)
VALUES('2099-01-01',17,500);
CREATE TEMP VIEW final_unrelated AS SELECT jsonb_build_object(
    'budget',(SELECT jsonb_agg(to_jsonb(t) ORDER BY utc_date) FROM public.provider_daily_budget t),
    'receipts',(SELECT jsonb_agg(to_jsonb(t) ORDER BY owner_id,operation_id) FROM public.operation_receipts t),
    'ownerB',(SELECT to_jsonb(t) FROM public.profiles t WHERE id=pg_temp.final_id(2)),
    'quotaB',(SELECT to_jsonb(t) FROM public.monthly_quotas t WHERE id=pg_temp.final_id(1902)),
    'anchorA',(SELECT to_jsonb(t) FROM public.account_quota_anchors t WHERE owner_id=pg_temp.final_id(1))
) AS data;
CREATE TEMP TABLE final_unrelated_before AS SELECT data FROM final_unrelated;

SELECT ok((SELECT prosecdef AND proconfig @> ARRAY['search_path=""'] FROM pg_proc
    WHERE oid='public.finalize_analysis_quota(uuid,text,boolean,timestamptz)'::regprocedure),
    'Finalizer is a definer with pinned empty search_path');
SELECT ok(NOT EXISTS (SELECT 1 FROM pg_proc p,
    LATERAL aclexplode(COALESCE(p.proacl,acldefault('f',p.proowner))) a
    WHERE p.oid='public.finalize_analysis_quota(uuid,text,boolean,timestamptz)'::regprocedure
      AND a.grantee IN (0,'anon'::regrole::oid,'authenticated'::regrole::oid)
      AND a.privilege_type='EXECUTE'),'PUBLIC and client execution revoked');
SELECT ok(has_function_privilege('service_role',
    'public.finalize_analysis_quota(uuid,text,boolean,timestamptz)','EXECUTE'),'Service can finalize');
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub='16340000-0000-4000-8000-000000000002';
SELECT throws_ok($$SELECT public.finalize_analysis_quota('16340000-0000-4000-8000-000000000101','succeeded')$$,
    '42501',NULL,'Authenticated B cannot finalize A');
RESET ROLE;
SET LOCAL ROLE anon;
SELECT throws_ok($$SELECT public.finalize_analysis_quota('16340000-0000-4000-8000-000000000101','succeeded')$$,
    '42501',NULL,'Anon cannot finalize');
RESET ROLE;

SELECT throws_ok($$SELECT pg_temp.settle(106,'unknown')$$,'22023','INVALID_QUOTA_OUTCOME','Invalid outcome rejected');
SELECT throws_ok($$SELECT pg_temp.settle(106,NULL)$$,'22023','INVALID_QUOTA_OUTCOME','Null outcome rejected');
SELECT throws_ok($$SELECT pg_temp.settle(106,'succeeded',NULL)$$,'22023','INVALID_QUOTA_OUTCOME','Null billing flag rejected');
SELECT throws_ok($$SELECT pg_temp.settle(106,'succeeded',false,NULL)$$,'22023','INVALID_QUOTA_TIME','Null time rejected');
SELECT throws_ok($$SELECT pg_temp.settle(106,'succeeded',false,'infinity')$$,'22023','INVALID_QUOTA_TIME','Infinite time rejected');
SELECT throws_ok($$SELECT pg_temp.settle(106,'succeeded',false,'-infinity')$$,'22023','INVALID_QUOTA_TIME','Negative infinity rejected');
SELECT throws_ok($$SELECT pg_temp.settle(999)$$,'P0002','JOB_NOT_FOUND','Missing job rejected');
SELECT throws_ok($$SELECT pg_temp.settle(NULL)$$,'P0002','JOB_NOT_FOUND','Null job rejected');
SELECT ok((SELECT state='queued' AND quota_state='not_applicable' FROM public.analysis_jobs
    WHERE id=pg_temp.final_id(106)),'Invalid inputs leave the job unmodified');

SELECT is(pg_temp.final_admit(101,1)->>'quota_kind','free_monthly','Reserve a genuine canonical job');
UPDATE public.analysis_jobs SET state='running',lease_token=pg_temp.final_id(9000),
    provider_started_at='2026-11-15 10:20Z',usage='{"classification":"unknown"}',error_code='fixture'
WHERE id=pg_temp.final_id(101);
CREATE TEMP TABLE final_job_before AS
SELECT to_jsonb(j)-ARRAY['quota_state','state','updated_at'] AS data
FROM public.analysis_jobs j WHERE id=pg_temp.final_id(101);
SET LOCAL ROLE service_role;
SELECT is(public.finalize_analysis_quota('16340000-0000-4000-8000-000000000101',
    'succeeded',false,'2026-11-15 10:20Z')->>'quota_state','consumed','Service settles unknown successful result as billable');
RESET ROLE;
SELECT ok((SELECT quota_state='consumed' AND state='succeeded' FROM public.analysis_jobs
    WHERE id=pg_temp.final_id(101)),'Source and ledger succeed together');
SELECT is((SELECT quota_state FROM public.account_quota_usage WHERE job_id=pg_temp.final_id(101)),
    'consumed','Canonical ledger consumed');
SELECT is((SELECT to_jsonb(j)-ARRAY['quota_state','state','updated_at'] FROM public.analysis_jobs j
    WHERE id=pg_temp.final_id(101)),(SELECT data FROM final_job_before),'Lease, pointers, usage and historical job fields preserved');
SELECT is(pg_temp.settle(101,'failed')->>'quota_state','consumed','Contradictory retry preserves original success');
SELECT is(pg_temp.final_admit(101,1)->>'reason','job_already_finalized','Terminal admission cannot reserve again');
SELECT is(pg_temp.final_admit(102,1,NULL,'identification')->>'admitted','true','Both photo modes use monthly ledger');
SELECT is(pg_temp.settle(102,'failed')->>'quota_state','released','Technical failure releases');
SELECT is(pg_temp.settle(102)->>'quota_state','released','Released retry cannot consume');
SELECT is(pg_temp.final_admit(103,1)->>'admitted','true','Reserve timeout case');
SELECT is(pg_temp.settle(103,'timed_out')->>'quota_state','released','Timeout releases');
SELECT is((SELECT state FROM public.analysis_jobs WHERE id=pg_temp.final_id(103)),'timed_out','Real timeout state preserved');
SELECT is(pg_temp.final_admit(104,1)->>'admitted','true','Reserve nonbillable case');
SELECT is(pg_temp.settle(104,'succeeded',true)->>'quota_state','released','Explicit nonbillable result releases');
SELECT ok((SELECT state='succeeded' AND quota_state='released' FROM public.analysis_jobs
    WHERE id=pg_temp.final_id(104)),'Nonbillable success remains a successful job');
SELECT is(pg_temp.settle(105)->>'quota_state','not_applicable','Unreserved job gets no fabricated consumption');
SELECT is(pg_temp.settle(105,'failed')->>'already_finalized','true','Unreserved terminal job is stable');
SELECT is((SELECT count(*) FROM public.account_quota_usage WHERE job_id=pg_temp.final_id(105)),
    0::bigint,'Unreserved success creates no ledger row');
SELECT is(pg_temp.final_admit(107,1)->>'admitted','true','Reserve terminal-ledger replay fixture');
UPDATE public.account_quota_usage SET quota_state='released' WHERE job_id=pg_temp.final_id(107);
SELECT is(pg_temp.settle(107)->>'quota_state','released','Terminal ledger alone prevents another settlement');
SELECT is(pg_temp.final_admit(107,1)->>'reason','job_already_finalized','Terminal ledger also blocks readmission');

SELECT is(pg_temp.final_admit(108,1)->>'quota_kind','free_monthly','Free reservation precedes purchase');
INSERT INTO public.entitlements(owner_id,product_id,state,offer_kind,valid_until,trial_end_at)
VALUES(pg_temp.final_id(1),'app.narat.plants.pro.yearly','active','trial','2026-11-22','2026-11-22');
SELECT is(pg_temp.settle(108,'succeeded',false,'2026-12-01')->>'quota_kind','free_monthly','Trial cannot change original reservation kind');
SELECT is(pg_temp.final_admit(109,1,NULL,'identification')->>'quota_kind','paid_monthly','Trial reserves paid access');
UPDATE public.entitlements SET offer_kind='paid',trial_end_at=NULL WHERE owner_id=pg_temp.final_id(1);
UPDATE public.entitlements SET state='expired',valid_until='2026-11-22' WHERE owner_id=pg_temp.final_id(1);
SELECT is(pg_temp.settle(109,'succeeded',false,'2026-12-31')->>'quota_state','consumed','Reservation settles after reset and expiry');
SELECT ok((SELECT bool_and(period_start='2026-10-31 10:20Z'::timestamptz
    AND period_end='2026-11-30 10:20Z'::timestamptz AND legacy_quota_id IS NULL)
    FROM public.account_quota_usage WHERE job_id IN (pg_temp.final_id(108),pg_temp.final_id(109))),
    'Original registration windows and canonical null legacy pointers preserved');
SELECT is(pg_temp.final_admit(110,1)->>'reason','free_monthly_exhausted','Expiry does not reset shared three successful analyses');
SELECT is((SELECT count(*) FROM public.monthly_quotas WHERE owner_id=pg_temp.final_id(1)),
    0::bigint,'Canonical jobs never rewrite or fabricate legacy counters');

SELECT is(pg_temp.final_admit(301,3,1303,'identification')->>'quota_kind','starter_identification','Guest identification starter reserved');
SELECT is(pg_temp.final_admit(302,3,1303)->>'quota_kind','starter_diagnosis','Independent diagnosis starter reserved concurrently');
SELECT is(pg_temp.settle(301,'succeeded',false,'2026-11-16 10:20Z')->>'quota_state','consumed','First starter consumes once');
SELECT ok((SELECT starter_identification_consumed AND NOT starter_diagnosis_consumed
    AND starter_identification_job_id IS NULL AND starter_diagnosis_job_id=pg_temp.final_id(302)
    FROM public.profiles WHERE id=pg_temp.final_id(3)) AND
    (SELECT starter_identification_consumed AND NOT starter_diagnosis_consumed
    AND starter_identification_job_id IS NULL AND starter_diagnosis_job_id=pg_temp.final_id(302)
    FROM public.installation_access WHERE id=pg_temp.final_id(1303)),
    'Only matching mode pointer cleared on owner and installation');
SELECT is(pg_temp.settle(302,'failed')->>'quota_state','released','Failed starter releases');
SELECT ok((SELECT NOT starter_diagnosis_consumed AND starter_diagnosis_job_id IS NULL FROM public.profiles WHERE id=pg_temp.final_id(3))
    AND (SELECT NOT starter_diagnosis_consumed AND starter_diagnosis_job_id IS NULL FROM public.installation_access WHERE id=pg_temp.final_id(1303)),
    'Failed starter consumes neither owner nor installation marker');
SELECT is(pg_temp.final_admit(303,3,1303)->>'admitted','true','Fresh job can retry released starter');
SELECT is(pg_temp.settle(303,'succeeded',true)->>'quota_state','released','Nonbillable starter releases');
SELECT is(pg_temp.final_admit(305,3,1303)->>'admitted','true','Nonbillable starter remains available');
SELECT is(pg_temp.settle(305)->>'quota_state','consumed','Independent second successful starter consumes');
SELECT ok((SELECT starter_identification_consumed AND starter_diagnosis_consumed
    AND first_starter_success_at='2026-11-15 10:20Z'::timestamptz FROM public.profiles WHERE id=pg_temp.final_id(3))
    AND (SELECT starter_identification_consumed AND starter_diagnosis_consumed
    AND first_starter_success_at='2026-11-15 10:20Z'::timestamptz FROM public.installation_access WHERE id=pg_temp.final_id(1303)),
    'Both markers remain consumed and earliest success is shared');
SELECT is(pg_temp.final_admit(302,3,1303)->>'reason','job_already_finalized','Released starter job cannot be readmitted');
SELECT is(pg_temp.final_admit(601,6,1306)->>'admitted','true','Reserve old starter lease');
UPDATE public.profiles SET starter_diagnosis_job_id=pg_temp.final_id(602),starter_identification_job_id=pg_temp.final_id(603)
WHERE id=pg_temp.final_id(6);
UPDATE public.installation_access SET starter_diagnosis_job_id=pg_temp.final_id(602),starter_identification_job_id=pg_temp.final_id(603)
WHERE id=pg_temp.final_id(1306);
SELECT is(pg_temp.settle(601,'failed')->>'quota_state','released','Old starter failure can finish');
SELECT ok((SELECT starter_diagnosis_job_id=pg_temp.final_id(602) AND starter_identification_job_id=pg_temp.final_id(603)
    AND NOT starter_diagnosis_consumed FROM public.profiles WHERE id=pg_temp.final_id(6))
    AND (SELECT starter_diagnosis_job_id=pg_temp.final_id(602) AND starter_identification_job_id=pg_temp.final_id(603)
    AND NOT starter_diagnosis_consumed FROM public.installation_access WHERE id=pg_temp.final_id(1306)),
    'Old finalizer preserves newer pointers and other mode');
SELECT is(pg_temp.final_admit(701,7,NULL,'identification')->>'admitted','true','Permanent owner starter needs no installation');
SELECT is(pg_temp.settle(701)->>'quota_state','consumed','Owner-only starter settles');
SELECT is(pg_temp.final_admit(801,8,1308)->>'admitted','true','Reserve marker OR fixture');
UPDATE public.installation_access SET starter_diagnosis_consumed=true,first_starter_success_at='2026-10-01'
WHERE id=pg_temp.final_id(1308);
SELECT is(pg_temp.settle(801,'failed')->>'quota_state','released','Failure cannot undo a prior consumed marker');
SELECT ok((SELECT starter_diagnosis_consumed AND first_starter_success_at='2026-10-01'::timestamptz
    FROM public.profiles WHERE id=pg_temp.final_id(8)) AND
    (SELECT starter_diagnosis_consumed AND first_starter_success_at='2026-10-01'::timestamptz
    FROM public.installation_access WHERE id=pg_temp.final_id(1308)),
    'Existing consumed marker is OR-merged and earliest time retained');

SELECT is(pg_temp.settle(401,'succeeded',false,'2026-12-31')->>'quota_state','consumed','Legacy job settles without new registration anchor');
SELECT is(pg_temp.settle(402,'failed')->>'quota_state','released','Unknown-anchor legacy failure releases source');
SELECT is(pg_temp.settle(403,'succeeded',true)->>'quota_state','released','Unknown-anchor legacy nonbillable releases source');
SELECT ok((SELECT consumed_count=8 AND reserved_count=0 FROM public.monthly_quotas WHERE id=pg_temp.final_id(1401)),
    'Original source counter decrements once per reserve and consumes only one');
SELECT is(pg_temp.settle(401,'failed')->>'quota_state','consumed','Legacy terminal replay is stable');
SELECT is(pg_temp.settle(402)->>'quota_state','released','Legacy failure replay cannot decrement again');
SELECT ok((SELECT consumed_count=8 AND reserved_count=0 FROM public.monthly_quotas WHERE id=pg_temp.final_id(1401))
    AND NOT EXISTS(SELECT 1 FROM public.account_quota_usage WHERE owner_id=pg_temp.final_id(4))
    AND (SELECT registered_at IS NULL FROM public.account_quota_anchors WHERE owner_id=pg_temp.final_id(4)),
    'Replay preserves source, unknown anchor and deferred import');
SELECT is(pg_temp.final_admit(404,4)->>'reason','quota_registration_required','Finishing legacy work grants no new monthly access');
SELECT lives_ok($$SELECT public.set_registration_quota_anchor(pg_temp.final_id(4),'2026-01-31 10:20Z','fixture verified registration');
    SELECT public.reconcile_registration_quota(pg_temp.final_id(4));
    SELECT public.reconcile_registration_quota(pg_temp.final_id(4));$$,'Later verified evidence imports terminal states idempotently');
SELECT ok((SELECT count(*)=3 AND count(*) FILTER(WHERE quota_state='consumed')=1
    AND count(*) FILTER(WHERE quota_state='released')=2 FROM public.account_quota_usage WHERE owner_id=pg_temp.final_id(4))
    AND (SELECT unallocated_consumed=7 AND unallocated_reserved=0 FROM public.quota_legacy_reconciliation
         WHERE monthly_quota_id=pg_temp.final_id(1401)),'Late import counts settled jobs once and preserves historical residual');

SELECT lives_ok($$SELECT public.reconcile_registration_quota(pg_temp.final_id(5))$$,'Import existing reserved follow_up and diagnosis');
SELECT is(pg_temp.settle(501,'succeeded',false,'2026-12-31')->>'quota_state','consumed','Historical follow_up can settle original reservation');
SELECT is(pg_temp.settle(502,'timed_out')->>'quota_state','released','Imported legacy timeout releases');
SELECT ok((SELECT consumed_count=1 AND reserved_count=0 FROM public.monthly_quotas WHERE id=pg_temp.final_id(1501))
    AND (SELECT quota_state='consumed' AND legacy_quota_id=pg_temp.final_id(1501)
    AND period_start='2026-10-31 10:20Z'::timestamptz FROM public.account_quota_usage WHERE job_id=pg_temp.final_id(501)),
    'Imported ledger and original source agree across reset');
SELECT lives_ok($$SELECT pg_temp.settle(501,'failed'); SELECT pg_temp.settle(502);
    SELECT public.reconcile_registration_quota(pg_temp.final_id(5));$$,'Legacy replays and reconciliation remain safe');
SELECT ok((SELECT consumed_count=1 AND reserved_count=0 FROM public.monthly_quotas WHERE id=pg_temp.final_id(1501))
    AND (SELECT NOT requires_review AND unallocated_consumed=0 AND unallocated_reserved=0
    FROM public.quota_legacy_reconciliation WHERE monthly_quota_id=pg_temp.final_id(1501)),
    'Reconciliation finds no double spend or phantom reserve');

UPDATE public.analysis_jobs SET quota_kind='paid_monthly',quota_state='reserved',quota_owner_id=owner_id,
    monthly_quota_id=CASE WHEN id=pg_temp.final_id(901) THEN pg_temp.final_id(1901)
                         WHEN id=pg_temp.final_id(903) THEN pg_temp.final_id(1903)
                         WHEN id=pg_temp.final_id(904) THEN pg_temp.final_id(1902) END
WHERE owner_id=pg_temp.final_id(9);
UPDATE public.analysis_jobs SET quota_owner_id=pg_temp.final_id(2) WHERE id=pg_temp.final_id(906);
INSERT INTO public.account_quota_usage(job_id,owner_id,period_start,period_end,quota_state)
VALUES(pg_temp.final_id(905),pg_temp.final_id(2),'2026-10-31 10:20Z','2026-11-30 10:20Z','reserved');
UPDATE public.analysis_jobs SET state='failed' WHERE id=pg_temp.final_id(907);
INSERT INTO public.account_quota_usage(job_id,owner_id,period_start,period_end,quota_state)
VALUES(pg_temp.final_id(907),pg_temp.final_id(9),'2026-10-31 10:20Z','2026-11-30 10:20Z','reserved');
SELECT throws_ok($$SELECT pg_temp.settle(907)$$,'23514','QUOTA_TERMINAL_CONFLICT','Terminal failed source cannot be reopened as success');
SELECT is(pg_temp.settle(907,'failed')->>'quota_state','released','Existing terminal failure can release its unsettled reserve');
SELECT throws_ok($$SELECT pg_temp.settle(901)$$,'23514','QUOTA_RESERVATION_INCONSISTENT','Zero legacy reserve explicitly rejected, never clamped');
SELECT throws_ok($$SELECT pg_temp.settle(902)$$,'23514','QUOTA_HISTORY_UNRESOLVED','Missing canonical reservation rejected');
SELECT throws_ok($$SELECT pg_temp.settle(903)$$,'23514','QUOTA_HISTORY_UNRESOLVED','Legacy kind mismatch rejected');
SELECT throws_ok($$SELECT pg_temp.settle(904)$$,'23514','QUOTA_HISTORY_UNRESOLVED','Foreign source owner rejected');
SELECT throws_ok($$SELECT pg_temp.settle(905)$$,'23514','QUOTA_HISTORY_UNRESOLVED','Foreign ledger owner rejected');
SELECT throws_ok($$SELECT pg_temp.settle(906)$$,'23514','QUOTA_OWNER_MISMATCH','Foreign quota owner rejected');
SELECT ok((SELECT bool_and(quota_state='reserved' AND state='queued') FROM public.analysis_jobs
    WHERE owner_id=pg_temp.final_id(9) AND id<>pg_temp.final_id(907)),'Rejected settlements leave every source reservation intact');
SELECT is((SELECT data FROM final_unrelated),(SELECT data FROM final_unrelated_before),
    'Provider budget, receipts, B history and registration anchor remain byte-for-byte unchanged');
SELECT * FROM finish();
ROLLBACK;
