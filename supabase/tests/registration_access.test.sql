-- B2 snapshot/admission parity on synthetic DB identities, actual RPCs only.
BEGIN;
SELECT no_plan();
CREATE FUNCTION pg_temp.access_id(n integer) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$
 SELECT ('16380000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid $$;
INSERT INTO public.profiles(id,anonymous,created_at,starter_identification_consumed,starter_diagnosis_consumed)
VALUES(pg_temp.access_id(1),false,'2026-10-31 10:20:00.123456Z',false,true),
      (pg_temp.access_id(3),false,'2026-10-31 10:20:00.123456Z',true,true),
      (pg_temp.access_id(4),true,'2026-10-01',false,false),
      (pg_temp.access_id(5),false,'2026-10-31 10:20:00.123456Z',true,true);
ALTER TABLE public.profiles DISABLE TRIGGER trg_profiles_registration_anchor;
INSERT INTO public.profiles(id,anonymous,created_at,starter_diagnosis_consumed)
VALUES(pg_temp.access_id(2),false,'2020-01-01',true);
ALTER TABLE public.profiles ENABLE TRIGGER trg_profiles_registration_anchor;
INSERT INTO public.account_quota_anchors VALUES(pg_temp.access_id(2),NULL,'unresolved');
INSERT INTO public.kb_releases(id,version,state,manifest_sha256,published_at)
VALUES(pg_temp.access_id(100),'access-api-fixture','retired',repeat('f',64),'2026-01-01');
INSERT INTO public.analysis_jobs(id,owner_id,flow_id,intent,add_method,mode,kb_release_id,prompt_version,operation_id,payload_hash,locale,quota_kind,quota_state,created_at)
SELECT pg_temp.access_id(i),pg_temp.access_id(o),pg_temp.access_id(i),'problem','scan','diagnosis',pg_temp.access_id(100),'fixture',pg_temp.access_id(i),'hash-'||i,'en','none','not_applicable','2026-11-01'
FROM (VALUES(101,1),(102,1),(103,1),(104,1),(105,1),(106,1),(201,2),(301,3),(302,3),(501,5)) f(i,o);
SELECT public.admit_analysis_quota('diagnosis',pg_temp.access_id(1),NULL,pg_temp.access_id(101),'2026-11-15');
SELECT public.finalize_analysis_quota(pg_temp.access_id(101),'succeeded',false,'2026-11-15');
SELECT public.admit_analysis_quota('diagnosis',pg_temp.access_id(1),NULL,pg_temp.access_id(102),'2026-11-15');
CREATE TEMP TABLE snapshots(label text PRIMARY KEY,value jsonb);
INSERT INTO snapshots VALUES('free',public.get_analysis_access_snapshot(pg_temp.access_id(1),NULL,'2026-11-15'));
SELECT is((SELECT value->>'owner_id' FROM snapshots WHERE label='free'),pg_temp.access_id(1)::text,'response owner bound');
SELECT is((SELECT value->'monthly'->>'status' FROM snapshots WHERE label='free'),'ready','known free ready');
SELECT is((SELECT value->'monthly'->>'limit' FROM snapshots WHERE label='free'),'3','Free3 immediately in registration month');
SELECT is((SELECT value->'monthly'->>'consumed' FROM snapshots WHERE label='free'),'1','actual finalized consumption');
SELECT is((SELECT value->'monthly'->>'reserved' FROM snapshots WHERE label='free'),'1','pending reservation counted');
SELECT is((SELECT value->'monthly'->>'remaining' FROM snapshots WHERE label='free'),'1','one shared pool remaining');
SELECT is((SELECT (value->'monthly'->>'period_start')::timestamptz FROM snapshots WHERE label='free'),'2026-10-31 10:20:00.123456Z'::timestamptz,'raw microsecond anchor preserved');
SELECT is((SELECT (value->'monthly'->>'period_end')::timestamptz FROM snapshots WHERE label='free'),'2026-11-30 10:20:00.123456Z'::timestamptz,'day31 clamps to30 preservingmicroseconds');
SELECT is((SELECT value->'modes'->'identification'->>'activeQuotaKind' FROM snapshots WHERE label='free'),'starter_identification','unused free ID starter first');
SELECT is((SELECT value->'modes'->'identification'->>'remaining' FROM snapshots WHERE label='free'),'1','free ID independent of monthly spend');
SELECT is((SELECT value->'modes'->'diagnosis'->>'activeQuotaKind' FROM snapshots WHERE label='free'),'free_monthly','spent starter diagnosis monthly');
CREATE TEMP TABLE counts_before AS SELECT
 (SELECT count(*) FROM public.analysis_jobs) jobs,
 (SELECT jsonb_agg(to_jsonb(u) ORDER BY job_id) FROM public.account_quota_usage u) usage;
SELECT is(public.get_analysis_access_snapshot(pg_temp.access_id(1),NULL,'2026-11-15'),(SELECT value FROM snapshots WHERE label='free'),'repeat snapshot stable');
SELECT is((SELECT count(*) FROM public.analysis_jobs),(SELECT jobs FROM counts_before),'GET creates no job');
SELECT is((SELECT jsonb_agg(to_jsonb(u) ORDER BY job_id) FROM public.account_quota_usage u),(SELECT usage FROM counts_before),'GET reserves or debits nothing');
SELECT ok((public.admit_analysis_quota('diagnosis',pg_temp.access_id(1),NULL,pg_temp.access_id(103),'2026-11-15')->>'admitted')::boolean,'actual008 agrees allowed monthly');
SELECT is(public.get_analysis_access_snapshot(pg_temp.access_id(1),NULL,'2026-11-15')->'monthly'->>'remaining','0','shared pool reacheszero');
SELECT is(public.admit_analysis_quota('diagnosis',pg_temp.access_id(1),NULL,pg_temp.access_id(104),'2026-11-15')->>'reason','free_monthly_exhausted','actual008 agrees exhausted snapshot');
INSERT INTO public.entitlements(owner_id,product_id,state,offer_kind,valid_until,trial_end_at)
VALUES(pg_temp.access_id(1),'app.narat.plants.pro.yearly','active','trial','2026-12-01','2026-12-01');
INSERT INTO snapshots VALUES('trial',public.get_analysis_access_snapshot(pg_temp.access_id(1),NULL,'2026-11-15'));
SELECT is((SELECT value->'monthly'->>'remaining' FROM snapshots WHERE label='trial'),'97','trial lifts limit without refill');
SELECT is((SELECT value->'modes'->'identification'->>'activeQuotaKind' FROM snapshots WHERE label='trial'),'paid_monthly','paid ignores unused starter');
SELECT is((SELECT value->'modes'->'identification'->>'remaining' FROM snapshots WHERE label='trial'),'97','paid modes same shared remaining');
SELECT ok((public.admit_analysis_quota('diagnosis',pg_temp.access_id(1),NULL,pg_temp.access_id(104),'2026-11-15')->>'admitted')::boolean,'actual008 agrees trial allowance');
SELECT public.finalize_analysis_quota(pg_temp.access_id(104),'succeeded',false,'2026-11-15');
UPDATE public.entitlements SET state='expired',valid_until='2026-11-14',trial_end_at='2026-11-14' WHERE owner_id=pg_temp.access_id(1);
INSERT INTO snapshots VALUES('expired',public.get_analysis_access_snapshot(pg_temp.access_id(1),NULL,'2026-11-15'));
SELECT is((SELECT value->'monthly'->>'remaining' FROM snapshots WHERE label='expired'),'0','expiry keeps totalspend4 aboveFree3');
SELECT is((SELECT value->'modes'->'diagnosis'->>'reason' FROM snapshots WHERE label='expired'),'free_monthly_exhausted','expiry denies exhausted monthly');
SELECT is(public.admit_analysis_quota('diagnosis',pg_temp.access_id(1),NULL,pg_temp.access_id(105),'2026-11-15')->>'reason','free_monthly_exhausted','expiry actualadmission parity');
UPDATE public.entitlements SET state='active',offer_kind='paid',valid_until='2026-12-01' WHERE owner_id=pg_temp.access_id(1);
SELECT is(public.get_analysis_access_snapshot(pg_temp.access_id(1),NULL,'2026-11-15')->'monthly'->>'remaining','96','restore no refill');
INSERT INTO snapshots VALUES('unknown',public.get_analysis_access_snapshot(pg_temp.access_id(2),NULL,'2026-11-15'));
SELECT is((SELECT value->'monthly'->>'status' FROM snapshots WHERE label='unknown'),'registration_required','unknown legacy date explicit');
SELECT is((SELECT value->'monthly'->'consumed' FROM snapshots WHERE label='unknown'),'null'::jsonb,'unknown usage null');
SELECT is((SELECT value->'monthly'->'limit' FROM snapshots WHERE label='unknown'),'null'::jsonb,'unknown limit not fabricated3');
SELECT is((SELECT value->'monthly'->'remaining' FROM snapshots WHERE label='unknown'),'null'::jsonb,'unknown remaining not fabricated');
SELECT is((SELECT value->'monthly'->'period_end' FROM snapshots WHERE label='unknown'),'null'::jsonb,'unknown reset null');
SELECT is((SELECT value->'modes'->'identification'->>'allowed' FROM snapshots WHERE label='unknown'),'true','legacy unknown still allows unused starter');
SELECT is((SELECT value->'modes'->'diagnosis'->>'reason' FROM snapshots WHERE label='unknown'),'quota_registration_required','legacy spent mode denied explicit reason');
SELECT is(public.admit_analysis_quota('diagnosis',pg_temp.access_id(2),NULL,pg_temp.access_id(201),'2026-11-15')->>'reason','quota_registration_required','actual008 blocks unknown date');
INSERT INTO public.monthly_quotas(id,owner_id,quota_kind,period_start,period_end,limit_count,consumed_count,reserved_count)
VALUES(pg_temp.access_id(900),pg_temp.access_id(3),'paid_monthly','2026-09-01','2026-10-01',100,7,0);
SELECT is(public.get_analysis_access_snapshot(pg_temp.access_id(3),NULL,'2026-11-15')->'monthly'->>'status','ready','nonoverlap old residue does not deny currentmonth');
SELECT ok((public.admit_analysis_quota('diagnosis',pg_temp.access_id(3),NULL,pg_temp.access_id(301),'2026-11-15')->>'admitted')::boolean,'actual008 oldresidue parity');
UPDATE public.monthly_quotas SET period_start='2026-10-20',period_end='2026-11-20' WHERE id=pg_temp.access_id(900);
INSERT INTO snapshots VALUES('residue',public.get_analysis_access_snapshot(pg_temp.access_id(3),NULL,'2026-11-15'));
SELECT is((SELECT value->'monthly'->>'status' FROM snapshots WHERE label='residue'),'history_unresolved','current overlapping aggregate unknown');
SELECT is((SELECT value->'monthly'->'consumed' FROM snapshots WHERE label='residue'),'null'::jsonb,'currentunknown no pretend zero');
SELECT is(public.admit_analysis_quota('diagnosis',pg_temp.access_id(3),NULL,pg_temp.access_id(302),'2026-11-15')->>'reason','quota_history_unresolved','actual008 currentresidue parity');
SELECT public.register_installation_access(repeat('e',64),pg_temp.access_id(4),'2026-11-15');
INSERT INTO snapshots VALUES('guest',public.get_analysis_access_snapshot(pg_temp.access_id(4),repeat('e',64),'2026-11-15'));
SELECT is((SELECT value->>'is_guest' FROM snapshots WHERE label='guest'),'true','verified guest reflected');
SELECT is((SELECT value->'monthly'->>'status' FROM snapshots WHERE label='guest'),'not_applicable','guest has no monthlypool');
SELECT is((SELECT value->'monthly'->'remaining' FROM snapshots WHERE label='guest'),'null'::jsonb,'guest no fabricated monthly');
SELECT is((SELECT value->'modes'->'identification'->>'allowed' FROM snapshots WHERE label='guest'),'true','guest ID starter');
SELECT is((SELECT value->'modes'->'diagnosis'->>'allowed' FROM snapshots WHERE label='guest'),'true','guest diagnosis starter independent');
SELECT throws_ok(format('SELECT public.get_analysis_access_snapshot(%L)',pg_temp.access_id(4)),'22023','INSTALLATION_REQUIRED','guest credential required');
SELECT throws_ok(format('SELECT public.get_analysis_access_snapshot(%L,%L)',pg_temp.access_id(1),repeat('e',64)),'42501','INSTALLATION_CREDENTIAL_MISMATCH','GET cannot link foreign owner');
SELECT throws_ok(format('SELECT public.get_analysis_access_snapshot(%L,%L)',pg_temp.access_id(4),repeat('f',64)),'42501','INSTALLATION_CREDENTIAL_MISMATCH','unknown proof fails');
SELECT throws_ok(format('SELECT public.get_analysis_access_snapshot(%L,NULL,NULL)',pg_temp.access_id(1)),'22023','INVALID_QUOTA_TIME','null clock rejected');
SELECT ok((public.admit_analysis_quota('diagnosis',pg_temp.access_id(5),NULL,pg_temp.access_id(501),'2026-12-01')->>'admitted')::boolean,'delayed queuedjob reserved in later registrationwindow');
SELECT is(public.get_analysis_access_snapshot(pg_temp.access_id(5),NULL,'2026-12-01')->'monthly'->>'remaining','2','canonical pointerlesswindow authoritative despite earlier created_at');
SELECT is((public.get_analysis_access_snapshot(pg_temp.access_id(5),NULL,'2026-12-01')->'monthly'->>'period_end')::timestamptz,'2026-12-31 10:20:00.123456Z'::timestamptz,'clamp rebounds31');
SELECT is((public.get_analysis_access_snapshot(pg_temp.access_id(5),NULL,'2026-11-30 10:20:00.123456Z')->'monthly'->>'period_start')::timestamptz,'2026-11-30 10:20:00.123456Z'::timestamptz,'exact boundary belongsnewperiod');
SET LOCAL TIME ZONE 'Pacific/Auckland';
SELECT is((public.get_analysis_access_snapshot(pg_temp.access_id(5),NULL,'2026-12-01')->'monthly'->>'period_start')::timestamptz,'2026-11-30 10:20:00.123456Z'::timestamptz,'session timezone cannot moveUTC boundary');
SELECT ok(NOT has_function_privilege('anon','public.get_analysis_access_snapshot(uuid,text,timestamp with time zone)','EXECUTE'),'anon cannot spoof owner');
SELECT ok(NOT has_function_privilege('authenticated','public.get_analysis_access_snapshot(uuid,text,timestamp with time zone)','EXECUTE'),'JWTclient cannot spoof clock');
SELECT ok(has_function_privilege('service_role','public.get_analysis_access_snapshot(uuid,text,timestamp with time zone)','EXECUTE'),'service snapshot executable');
SELECT * FROM finish();
ROLLBACK;
