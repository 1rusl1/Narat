-- B2 real credential RPC fixtures; no live Auth/credential or provider.
BEGIN;
SELECT no_plan();
CREATE FUNCTION pg_temp.install_id(n integer) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$
 SELECT ('16370000-0000-4000-8000-' || lpad(n::text,12,'0'))::uuid $$;
INSERT INTO public.profiles(id,anonymous,created_at)
VALUES(pg_temp.install_id(1),true,'2026-10-31 10:20Z'),
      (pg_temp.install_id(2),false,'2026-10-31 10:20Z'),
      (pg_temp.install_id(3),false,'2026-10-31 10:20Z');
UPDATE public.profiles SET account_state='deleting' WHERE id=pg_temp.install_id(3);
CREATE TEMP TABLE api_result(label text PRIMARY KEY,value jsonb);
INSERT INTO api_result VALUES('guest',public.register_installation_access(repeat('a',64),pg_temp.install_id(1),'2026-11-15 10:20Z'));
SELECT ok((SELECT value->>'owner_id'=pg_temp.install_id(1)::text FROM api_result WHERE label='guest'),'anonymous JWT owner associated');
SELECT is((SELECT count(*) FROM public.installation_access WHERE credential_hash=repeat('a',64)),1::bigint,'one hash identity');
SELECT ok((SELECT pg_temp.install_id(1)=ANY(linked_owner_ids) FROM public.installation_access WHERE credential_hash=repeat('a',64)),'guest linked for actual008 admission');
SELECT is((SELECT value->>'starter_identification_consumed' FROM api_result WHERE label='guest'),'false','fresh ID unused');
SELECT is((SELECT value->>'starter_diagnosis_consumed' FROM api_result WHERE label='guest'),'false','fresh diagnosis unused');
SELECT is(public.register_installation_access(repeat('a',64),pg_temp.install_id(1),'2026-11-15 10:20Z'),(SELECT value FROM api_result WHERE label='guest'),'register exact replay');
SELECT throws_ok(format('SELECT public.register_installation_access(NULL,%L)',pg_temp.install_id(1)),'22023','INVALID_INSTALLATION_CREDENTIAL','missing hash rejected');
SELECT throws_ok(format('SELECT public.register_installation_access(%L,%L)',repeat('a',63),pg_temp.install_id(1)),'22023','INVALID_INSTALLATION_CREDENTIAL','short hash rejected');
SELECT throws_ok(format('SELECT public.register_installation_access(%L,%L)',repeat('A',64),pg_temp.install_id(1)),'22023','INVALID_INSTALLATION_CREDENTIAL','noncanonical hash rejected');
SELECT throws_ok(format('SELECT public.register_installation_access(%L,%L)',repeat('b',64),pg_temp.install_id(3)),'42501','ACTIVE_OWNER_REQUIRED','deleting owner rejected');
SELECT throws_ok(format('SELECT public.register_installation_access(%L,NULL)',repeat('b',64)),'42501','ACTIVE_OWNER_REQUIRED','no owner rejected');
SELECT is((SELECT count(*) FROM public.installation_access WHERE credential_hash=repeat('b',64)),0::bigint,'rejections create no identity');
SELECT throws_ok(format('SELECT public.register_installation_access(%L,%L,NULL)',repeat('a',64),pg_temp.install_id(1)),'22023','INVALID_QUOTA_TIME','null clock rejected');
INSERT INTO public.kb_releases(id,version,state,manifest_sha256,published_at)
VALUES(pg_temp.install_id(100),'installation-api-fixture','retired',repeat('f',64),'2026-01-01');
INSERT INTO public.analysis_jobs(id,owner_id,flow_id,intent,add_method,mode,kb_release_id,prompt_version,operation_id,payload_hash,locale,quota_kind,quota_state,created_at)
VALUES(pg_temp.install_id(101),pg_temp.install_id(1),pg_temp.install_id(101),'problem','scan','diagnosis',pg_temp.install_id(100),'fixture',pg_temp.install_id(101),'fixture','en','none','not_applicable','2026-11-15 10:20Z');
INSERT INTO api_result SELECT 'admit',public.admit_analysis_quota('diagnosis',pg_temp.install_id(1),(value->>'installation_id')::uuid,pg_temp.install_id(101),'2026-11-15 10:20Z') FROM api_result WHERE label='guest';
SELECT ok((SELECT (value->>'admitted')::boolean FROM api_result WHERE label='admit'),'actual008 guest admission with registered identity');
SELECT is((SELECT value->>'quota_kind' FROM api_result WHERE label='admit'),'starter_diagnosis','guest uses diagnosis starter');
CREATE TEMP TABLE preserved AS SELECT
 (SELECT to_jsonb(t) FROM public.account_quota_anchors t WHERE owner_id=pg_temp.install_id(2)) anchor,
 (SELECT to_jsonb(t) FROM public.analysis_jobs t WHERE id=pg_temp.install_id(101)) job,
 (SELECT quota_anchor_at FROM public.profiles WHERE id=pg_temp.install_id(2)) purchase;
SELECT throws_ok(format('SELECT public.bind_installation_credential(%L,%L,%L)',(SELECT value->>'installation_id' FROM api_result WHERE label='guest'),pg_temp.install_id(2),repeat('b',64)),'42501','INSTALLATION_CREDENTIAL_MISMATCH','body UUID cannot replace credential proof');
SELECT ok(NOT (SELECT pg_temp.install_id(2)=ANY(linked_owner_ids) FROM public.installation_access WHERE credential_hash=repeat('a',64)),'failed proof does not link owner');
INSERT INTO api_result SELECT 'bound',public.bind_installation_credential((value->>'installation_id')::uuid,pg_temp.install_id(2),repeat('a',64),'2026-11-15 10:20Z') FROM api_result WHERE label='guest';
SELECT is((SELECT value->>'owner_id' FROM api_result WHERE label='bound'),pg_temp.install_id(2)::text,'permanent owner bound');
SELECT is((SELECT value->>'starter_diagnosis_job_id' FROM api_result WHERE label='bound'),pg_temp.install_id(101)::text,'live guest reservation blocks bound account');
SELECT ok((SELECT linked_owner_ids @> ARRAY[pg_temp.install_id(1),pg_temp.install_id(2)] FROM public.installation_access WHERE credential_hash=repeat('a',64)),'both owner links retained');
SELECT is((SELECT to_jsonb(t) FROM public.analysis_jobs t WHERE id=pg_temp.install_id(101)),(SELECT job FROM preserved),'bind never reassigns guest job');
SELECT is((SELECT to_jsonb(t) FROM public.account_quota_anchors t WHERE owner_id=pg_temp.install_id(2)),(SELECT anchor FROM preserved),'registration immutable through bind');
SELECT is((SELECT quota_anchor_at FROM public.profiles WHERE id=pg_temp.install_id(2)),(SELECT purchase FROM preserved),'purchase anchor unchanged');
SELECT throws_ok(format('SELECT public.bind_installation_credential(%L,%L,%L)',(SELECT value->>'installation_id' FROM api_result WHERE label='guest'),pg_temp.install_id(1),repeat('a',64)),'42501','ACTIVE_PERMANENT_OWNER_REQUIRED','guest cannot permanent-bind');
SELECT public.finalize_analysis_quota(pg_temp.install_id(101),'succeeded',true,'2026-11-15 10:21Z');
INSERT INTO api_result SELECT 'released',public.register_installation_access(repeat('a',64),pg_temp.install_id(2),'2026-11-15 10:22Z');
SELECT is((SELECT value->>'starter_diagnosis_job_id' FROM api_result WHERE label='released'),NULL,'register normalizes released copied pointer');
SELECT is((SELECT value->>'starter_diagnosis_consumed' FROM api_result WHERE label='released'),'false','nonbillable release grants no consumed marker');
UPDATE public.profiles SET starter_identification_consumed=true,first_starter_success_at='2026-11-01 12:00Z' WHERE id=pg_temp.install_id(2);
SELECT public.register_installation_access(repeat('a',64),pg_temp.install_id(2),'2026-11-15 10:23Z');
SELECT ok((SELECT starter_identification_consumed FROM public.installation_access WHERE credential_hash=repeat('a',64)),'register ORs account expense into installation');
SELECT public.register_installation_access(repeat('a',64),pg_temp.install_id(1),'2026-11-15 10:24Z');
SELECT ok((SELECT starter_identification_consumed FROM public.profiles WHERE id=pg_temp.install_id(1)),'same physical installation cannot refill guest starter');
SELECT is((SELECT first_starter_success_at FROM public.profiles WHERE id=pg_temp.install_id(1)),'2026-11-01 12:00Z'::timestamptz,'earliest time preserved');
SELECT is((SELECT count(*) FROM public.account_quota_usage WHERE owner_id IN(pg_temp.install_id(1),pg_temp.install_id(2))),0::bigint,'no monthly reserve by register/bind');
SELECT ok(NOT has_function_privilege('service_role','public.merge_installation_starters(uuid,uuid,timestamp with time zone)','EXECUTE'),'private helper not service callable');
SELECT ok(NOT has_function_privilege('anon','public.register_installation_access(text,uuid,timestamp with time zone)','EXECUTE'),'anon cannot register RPC');
SELECT ok(NOT has_function_privilege('authenticated','public.register_installation_access(text,uuid,timestamp with time zone)','EXECUTE'),'client cannot spoof registration owner');
SELECT ok(has_function_privilege('service_role','public.register_installation_access(text,uuid,timestamp with time zone)','EXECUTE'),'service can register');
SELECT ok(NOT has_function_privilege('authenticated','public.bind_installation_credential(uuid,uuid,text,timestamp with time zone)','EXECUTE'),'client cannot bind arbitrary identity');
SELECT ok(has_function_privilege('service_role','public.bind_installation_credential(uuid,uuid,text,timestamp with time zone)','EXECUTE'),'service can credential bind');
SELECT * FROM finish();
ROLLBACK;
