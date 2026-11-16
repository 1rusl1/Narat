BEGIN;
SELECT no_plan();

CREATE FUNCTION pg_temp.owner_id(n integer) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$
 SELECT ('15410000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid
$$;

INSERT INTO auth.users(id,is_anonymous,created_at) VALUES
    (pg_temp.owner_id(1),true,clock_timestamp()-interval '7 days'),
    (pg_temp.owner_id(2),false,clock_timestamp()-interval '1 second'),
    (pg_temp.owner_id(3),true,clock_timestamp()-interval '1 hour'),
    (pg_temp.owner_id(4),true,clock_timestamp()-interval '1 hour');

SELECT is((SELECT anonymous FROM public.profiles WHERE id=pg_temp.owner_id(1)),true,
    'Auth anonymous signup provisions an active guest profile');
SELECT is((SELECT registered_at FROM public.account_quota_anchors WHERE owner_id=pg_temp.owner_id(1)),
    NULL::timestamptz,'anonymous signup does not anchor registration');
SELECT is((SELECT anonymous FROM public.profiles WHERE id=pg_temp.owner_id(2)),false,
    'Auth permanent signup provisions a permanent profile');
SELECT is((SELECT registered_at FROM public.account_quota_anchors WHERE owner_id=pg_temp.owner_id(2)),
    (SELECT created_at FROM auth.users WHERE id=pg_temp.owner_id(2)),
    'permanent signup anchors to server Auth creation');
SELECT is(public.get_analysis_access_snapshot(pg_temp.owner_id(2),NULL,clock_timestamp())->'monthly'->>'remaining',
    '3','the first permanent period is available immediately');

CREATE TEMP TABLE t154_installations AS
SELECT n,(public.register_installation_access(repeat(n::text,64),pg_temp.owner_id(n),clock_timestamp())->>'installation_id')::uuid id
FROM (VALUES (1),(3)) AS guest(n);

INSERT INTO public.analysis_jobs(id,owner_id,flow_id,intent,add_method,mode,prompt_version,
    operation_id,payload_hash,locale,quota_kind,quota_state)
SELECT pg_temp.owner_id(20+n),pg_temp.owner_id(n),pg_temp.owner_id(40+n),'care','scan',
    'identification','fixture',pg_temp.owner_id(60+n),'t154','en','none','not_applicable'
FROM t154_installations;
SELECT is(public.admit_analysis_quota('identification',pg_temp.owner_id(1),
    (SELECT id FROM t154_installations WHERE n=1),pg_temp.owner_id(21),clock_timestamp())->>'admitted',
    'true','guest consumes the real installation-bound starter');
SELECT is(public.finalize_analysis_quota(pg_temp.owner_id(21),'succeeded',false,clock_timestamp())->>'quota_state',
    'consumed','successful guest analysis settles the starter');
SELECT is(public.admit_analysis_quota('identification',pg_temp.owner_id(3),
    (SELECT id FROM t154_installations WHERE n=3),pg_temp.owner_id(23),clock_timestamp())->>'admitted',
    'true','another guest holds an in-flight starter during conversion');

CREATE TEMP TABLE t154_before AS SELECT id,created_at,updated_at,first_starter_success_at
FROM public.profiles WHERE id IN (pg_temp.owner_id(1),pg_temp.owner_id(3));
CREATE TEMP TABLE t154_transition AS SELECT clock_timestamp() AS started_at;
UPDATE auth.users SET is_anonymous=false WHERE id IN (pg_temp.owner_id(1),pg_temp.owner_id(3));
SELECT is((SELECT anonymous FROM public.profiles WHERE id=pg_temp.owner_id(1)),false,
    'same Auth UUID is now a permanent profile');
SELECT ok((SELECT a.registered_at>=t.started_at AND a.registered_at<=clock_timestamp()
    AND a.source='anonymous_conversion' FROM public.account_quota_anchors a CROSS JOIN t154_transition t
    WHERE a.owner_id=pg_temp.owner_id(1)),'anchor captures the conversion instant');
SELECT ok((SELECT p.created_at=b.created_at AND p.updated_at>b.updated_at AND
    p.first_starter_success_at=b.first_starter_success_at
    FROM public.profiles p JOIN t154_before b USING(id) WHERE p.id=pg_temp.owner_id(1)),
    'conversion preserves profile age and starter success and advances the sync watermark');
SELECT ok((SELECT j.quota_state='consumed' AND j.quota_owner_id=pg_temp.owner_id(1)
    AND j.quota_installation_id=i.id FROM public.analysis_jobs j JOIN t154_installations i ON i.n=1
    WHERE j.id=pg_temp.owner_id(21)), 'original consumed job remains bound to its owner and installation');

CREATE TEMP TABLE t154_access AS
SELECT public.get_analysis_access_snapshot(pg_temp.owner_id(1),repeat('1',64),clock_timestamp()) value;
SELECT is((SELECT value->>'is_guest' FROM t154_access),'false','access sees the permanent session');
SELECT is((SELECT value#>>'{starter,identification_remaining}' FROM t154_access),'0','spent starter remains spent');
SELECT is((SELECT value#>>'{starter,diagnosis_remaining}' FROM t154_access),'1','diagnosis starter remains independent');
SELECT is((SELECT value#>>'{modes,identification,activeQuotaKind}' FROM t154_access),'free_monthly',
    'converted guest uses monthly Free after the starter');
SELECT is((SELECT value#>>'{monthly,remaining}' FROM t154_access),'3','starter is not double-counted in the new monthly period');
SELECT ok((SELECT (value#>>'{monthly,period_start}')::timestamptz=a.registered_at
    AND value#>>'{monthly,period_end}'=value#>>'{modes,identification,nextResetAt}'
    FROM t154_access CROSS JOIN public.account_quota_anchors a WHERE a.owner_id=pg_temp.owner_id(1)),
    'monthly start and mode reset use the registration anchor');

SELECT is(public.finalize_analysis_quota(pg_temp.owner_id(23),'succeeded',false,clock_timestamp())->>'quota_state',
    'consumed','in-flight starter settles after same-owner conversion');
SELECT ok((SELECT starter_identification_consumed AND starter_identification_job_id IS NULL
    FROM public.installation_access WHERE id=(SELECT id FROM t154_installations WHERE n=3)),
    'settlement marks the original installation after conversion');

CREATE TEMP TABLE t154_once AS SELECT a.registered_at,p.updated_at
FROM public.account_quota_anchors a JOIN public.profiles p ON p.id=a.owner_id WHERE p.id=pg_temp.owner_id(1);
UPDATE auth.users SET is_anonymous=false,created_at=created_at+interval '1 minute' WHERE id=pg_temp.owner_id(1);
SELECT ok((SELECT a.registered_at=o.registered_at AND p.updated_at=o.updated_at
    FROM public.account_quota_anchors a JOIN public.profiles p ON p.id=a.owner_id CROSS JOIN t154_once o
    WHERE p.id=pg_temp.owner_id(1)), 'repeated permanent Auth update cannot move the anchor or profile');
SELECT throws_ok($q$UPDATE public.account_quota_anchors SET registered_at=registered_at-interval '1 second'
    WHERE owner_id=pg_temp.owner_id(1)$q$,'55000','REGISTRATION_ANCHOR_IMMUTABLE','direct anchor overwrite is rejected');

CREATE TEMP TABLE t154_legacy AS SELECT * FROM public.account_quota_anchors
WHERE owner_id='16300000-0000-4000-8000-000000000002';
INSERT INTO auth.users(id,is_anonymous,created_at)
VALUES ('16300000-0000-4000-8000-000000000002',false,clock_timestamp());
SELECT ok((SELECT a.registered_at IS NOT DISTINCT FROM l.registered_at AND a.source=l.source
    FROM public.account_quota_anchors a JOIN t154_legacy l USING(owner_id)),
    'existing profile and unknown legacy anchor are retained byte for byte');

UPDATE public.profiles SET account_state='deleting' WHERE id=pg_temp.owner_id(4);
UPDATE auth.users SET is_anonymous=false WHERE id=pg_temp.owner_id(4);
SELECT ok((SELECT anonymous AND account_state='deleting' FROM public.profiles WHERE id=pg_temp.owner_id(4)),
    'Auth update cannot revive a profile being deleted');
SELECT is((SELECT registered_at FROM public.account_quota_anchors WHERE owner_id=pg_temp.owner_id(4)),
    NULL::timestamptz,'deleting account has no newly inferred date');
SELECT ok(NOT has_function_privilege('authenticated','public.sync_auth_owner_profile()','execute')
    AND NOT has_function_privilege('service_role','public.sync_auth_owner_profile()','execute'),
    'only the installed Auth triggers invoke profile synchronization');

-- T083 SQL core only; HTTP/client/live acceptance (T083/T084) remains open.
INSERT INTO public.profiles(id,anonymous,preferred_locale) VALUES
    (pg_temp.owner_id(80),false,'pl'), (pg_temp.owner_id(81),false,'en'),
    (pg_temp.owner_id(82),true,'en'), (pg_temp.owner_id(83),false,'en'),
    (pg_temp.owner_id(84),false,'en'), (pg_temp.owner_id(85),false,'en');
UPDATE public.profiles SET account_state='deleting' WHERE id=pg_temp.owner_id(83);
UPDATE public.profiles SET account_state='deleted' WHERE id=pg_temp.owner_id(85);
UPDATE public.profiles SET reminder_hour_local=17 WHERE id=pg_temp.owner_id(81);
SELECT is(public.read_owner_profile_settings(pg_temp.owner_id(80)),
    '{"preferred_locale":"pl","reminder_hour_local":9}'::jsonb,'new owner defaults to 09:00');
SELECT is(public.read_owner_profile_settings(pg_temp.owner_id(81)),
    '{"preferred_locale":"en","reminder_hour_local":17}'::jsonb,'existing settings are not reset');
SELECT is(public.read_owner_profile_settings(id),NULL::jsonb,
    'private read hides absent, anonymous and inactive owner '||n)
FROM (VALUES (82),(83),(85),(86)) v(n) CROSS JOIN LATERAL (SELECT pg_temp.owner_id(n) id) i;
SELECT is(public.read_owner_profile_settings(NULL),NULL::jsonb,'null owner has no settings');

-- A future timestamp forces strict monotonicity independent of wall-clock time.
UPDATE public.profiles SET updated_at=clock_timestamp()+interval '1 day',
    trial_reminder_enabled=true WHERE id=pg_temp.owner_id(80);
INSERT INTO public.entitlements(owner_id,product_id,state,offer_kind,valid_until)
VALUES(pg_temp.owner_id(80),'app.narat.plants.pro.monthly','expired','paid',clock_timestamp()-interval '1 day');
CREATE TEMP TABLE t083_before AS
SELECT to_jsonb(p) AS profile,public.fetch_sync_delta(p.id) AS sync,
    (SELECT to_jsonb(e) FROM public.entitlements e WHERE e.owner_id=p.id) AS entitlement,
    (SELECT to_jsonb(a) FROM public.account_quota_anchors a WHERE a.owner_id=p.id) AS anchor
FROM public.profiles p WHERE p.id=pg_temp.owner_id(80);
CREATE TEMP TABLE t083_other AS SELECT to_jsonb(p) AS profile FROM public.profiles p
WHERE p.id=pg_temp.owner_id(81);

CREATE FUNCTION pg_temp.profile_hour(payload JSONB,
    operation UUID DEFAULT pg_temp.owner_id(100),
    owner UUID DEFAULT pg_temp.owner_id(80))
RETURNS JSONB LANGUAGE sql AS $$
    SELECT public.execute_profile_reminder_hour_update(owner,operation,payload)
$$;
CREATE TEMP TABLE t083_zero AS SELECT pg_temp.profile_hour('{"reminder_hour_local":0}') AS body;
SELECT is((SELECT body->'profile' FROM t083_zero),
    '{"preferred_locale":"pl","reminder_hour_local":0}'::jsonb,'midnight persists with the owner locale');
SELECT is(public.read_owner_profile_settings(pg_temp.owner_id(80)),
    (SELECT body->'profile' FROM t083_zero),'midnight is stored rather than only echoed');
SELECT ok((SELECT (z.body->>'watermark')::timestamptz>(b.profile->>'updated_at')::timestamptz
    FROM t083_zero z CROSS JOIN t083_before b),'real change advances a future owner watermark');
CREATE TEMP TABLE t083_last AS
SELECT pg_temp.profile_hour('{"reminder_hour_local":23}',pg_temp.owner_id(101)) AS body;
SELECT is(public.read_owner_profile_settings(pg_temp.owner_id(80)),
    '{"preferred_locale":"pl","reminder_hour_local":23}'::jsonb,'23:00 persists in the private read');
SELECT ok((SELECT (l.body->>'watermark')::timestamptz>(z.body->>'watermark')::timestamptz
    FROM t083_last l CROSS JOIN t083_zero z),'second change strictly advances the watermark');
SELECT is(pg_temp.profile_hour('{"reminder_hour_local":0}'),(SELECT body FROM t083_zero),
    'exact replay after a later change returns the original response and watermark');
SELECT is(public.read_owner_profile_settings(pg_temp.owner_id(80))->>'reminder_hour_local','23',
    'old replay does not overwrite the newer hour');
SELECT is(pg_temp.profile_hour('{"reminder_hour_local":23}',pg_temp.owner_id(102)),
    (SELECT body FROM t083_last),'new no-op operation preserves the current watermark');
SELECT ok((SELECT count(*)=3 AND bool_and(command_name='profile.update')
    FROM public.operation_receipts WHERE owner_id=pg_temp.owner_id(80)),
    'each successful operation including the no-op has a canonical receipt');
SELECT is((SELECT public.fetch_sync_delta(pg_temp.owner_id(80),
    (b.sync->>'until')::timestamptz)->'profile'->'reminder_hour_local' FROM t083_before b),
    '23'::jsonb,'new sync exposes the persisted reminder hour');
SELECT is(public.fetch_sync_delta(pg_temp.owner_id(80))->>'until',
    (SELECT body->>'watermark' FROM t083_last),'sync watermark matches the last genuine mutation');

-- Rejected requests cannot leave a receipt, mutate settings or claim local success.
CREATE TEMP TABLE t083_rejected_before AS
SELECT to_jsonb(p) AS profile,
    (SELECT count(*) FROM public.operation_receipts WHERE owner_id=p.id) AS receipts
FROM public.profiles p WHERE p.id=pg_temp.owner_id(80);
SELECT throws_ok(format('SELECT pg_temp.profile_hour(%L::jsonb)',payload),
    '22023','INVALID_PROFILE_UPDATE_INPUT','reject invalid profile payload: '||coalesce(payload,'SQL NULL'))
FROM (VALUES (NULL::text),('null'),('{}'),('[]'),('9'),
    ('{"reminder_hour_local":null}'),('{"reminder_hour_local":"9"}'),
    ('{"reminder_hour_local":true}'),('{"reminder_hour_local":[]}'),
    ('{"reminder_hour_local":{}}'),('{"reminder_hour_local":9.5}'),
    ('{"reminder_hour_local":9.0}'),('{"reminder_hour_local":-1}'),
    ('{"reminder_hour_local":24}'),('{"reminder_hour_local":1e1000}'),
    ('{"reminder_hour_local":8,"preferred_locale":"en"}'),
    ('{"reminder_hour_local":8,"owner_id":"15410000-0000-4000-8000-000000000081"}'),
    ('{"reminder_hour_local":8,"unknown":1}'),('{"preferred_locale":"en"}')) bad(payload);
SELECT throws_ok($q$SELECT pg_temp.profile_hour('{"reminder_hour_local":8}',NULL)$q$,
    '22023','INVALID_PROFILE_UPDATE_INPUT','operation UUID is required');
SELECT throws_ok($q$SELECT pg_temp.profile_hour('{"reminder_hour_local":8}')$q$,
    '23505','IDEMPOTENCY_CONFLICT','changed data cannot reuse the operation UUID');
SELECT throws_ok(format('SELECT pg_temp.profile_hour(''{"reminder_hour_local":8}'',%L::uuid,%L::uuid)',
    pg_temp.owner_id(103),id),'42501','ACTIVE_PERMANENT_OWNER_REQUIRED',
    'write rejects absent, anonymous or inactive owner '||n)
FROM (VALUES (82),(83),(85),(86)) v(n) CROSS JOIN LATERAL (SELECT pg_temp.owner_id(n) id) i;
SELECT throws_ok($q$SELECT pg_temp.profile_hour('{"reminder_hour_local":8}',pg_temp.owner_id(103),NULL)$q$,
    '42501','ACTIVE_PERMANENT_OWNER_REQUIRED','null owner cannot write');
SELECT ok((SELECT to_jsonb(p)=b.profile AND b.receipts=(
    SELECT count(*) FROM public.operation_receipts WHERE owner_id=p.id)
    FROM public.profiles p CROSS JOIN t083_rejected_before b WHERE p.id=pg_temp.owner_id(80)),
    'failed writes leave the profile, watermark and receipt count unchanged');

SELECT is((SELECT count(*) FROM public.operation_receipts
    WHERE owner_id IN (pg_temp.owner_id(82),pg_temp.owner_id(83),pg_temp.owner_id(85),pg_temp.owner_id(86))),
    0::bigint,'rejected owners receive no success receipts');

-- Even an otherwise matching hash cannot replay a receipt for another command.
INSERT INTO public.operation_receipts(owner_id,operation_id,command_name,payload_hash,response_payload)
VALUES(pg_temp.owner_id(80),pg_temp.owner_id(104),'plant.edit',
    encode(sha256(convert_to(jsonb_build_array('profile.update',
        '{"reminder_hour_local":8}'::jsonb)::text,'UTF8')),'hex'),'{"foreign":true}');
SELECT throws_ok($q$SELECT pg_temp.profile_hour('{"reminder_hour_local":8}',pg_temp.owner_id(104))$q$,
    '23505','IDEMPOTENCY_CONFLICT','different command conflicts even with a matching payload hash');
SELECT is(pg_temp.profile_hour('{"reminder_hour_local":0}',pg_temp.owner_id(100),pg_temp.owner_id(84))->'profile',
    '{"preferred_locale":"en","reminder_hour_local":0}'::jsonb,
    'operation UUID is owner-scoped and cannot return another owner locale or receipt');

-- Exercise every remaining integer hour with new operations.
CREATE TEMP TABLE t083_hours AS
SELECT n,pg_temp.profile_hour(jsonb_build_object('reminder_hour_local',n),
    pg_temp.owner_id(200+n)) AS body FROM generate_series(0,23) n ORDER BY n;
SELECT is(body->'profile'->'reminder_hour_local',to_jsonb(n),'valid integer hour '||n) FROM t083_hours;
SELECT ok((SELECT count(*)=24 AND count(DISTINCT body->>'watermark')=24
    AND min((body->>'watermark')::timestamptz)>(SELECT (body->>'watermark')::timestamptz FROM t083_last)
    FROM t083_hours),'all genuine hour changes get distinct increasing watermarks');
SELECT ok((SELECT to_jsonb(p)-'reminder_hour_local'-'updated_at'
    =b.profile-'reminder_hour_local'-'updated_at'
    AND (SELECT to_jsonb(e) FROM public.entitlements e WHERE e.owner_id=p.id)
        IS NOT DISTINCT FROM b.entitlement
    AND (SELECT to_jsonb(a) FROM public.account_quota_anchors a WHERE a.owner_id=p.id)
        IS NOT DISTINCT FROM b.anchor
    FROM public.profiles p CROSS JOIN t083_before b WHERE p.id=pg_temp.owner_id(80)),
    'hour updates preserve all other profile settings, entitlement and quota anchor');
SELECT is((SELECT to_jsonb(p) FROM public.profiles p WHERE p.id=pg_temp.owner_id(81)),
    (SELECT profile FROM t083_other),'another owner settings and watermark remain untouched');
SELECT is(public.read_owner_profile_settings(pg_temp.owner_id(80)),
    (public.fetch_sync_delta(pg_temp.owner_id(80))->'profile')-'trial_reminder_enabled'-'report_notifications_enabled',
    'private settings agree with both supported sync projection versions');

SELECT ok(has_function_privilege('service_role',signature,'EXECUTE')
    AND NOT has_function_privilege('anon',signature,'EXECUTE')
    AND NOT has_function_privilege('authenticated',signature,'EXECUTE')
    AND NOT EXISTS (SELECT 1 FROM pg_proc p,
        LATERAL aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) acl
        WHERE p.oid=signature::regprocedure AND acl.grantee=0 AND acl.privilege_type='EXECUTE'),
    'only service role can call '||signature)
FROM (VALUES ('public.read_owner_profile_settings(uuid)'),
    ('public.execute_profile_reminder_hour_update(uuid,uuid,jsonb)')) rpc(signature);

-- T083 internal deletion intent only. Direct authenticated data access, workers and
-- Auth revocation require review before any product route. T082/T083 remain open.
INSERT INTO public.plants(id,owner_id,personal_name,creation_source)
VALUES(pg_temp.owner_id(300),pg_temp.owner_id(1),'Deletion fixture','analysis');
INSERT INTO public.care_entries(id,owner_id,plant_id,action_code,occurred_at,
    occurred_local_date,timezone,operation_id)
VALUES(pg_temp.owner_id(301),pg_temp.owner_id(1),pg_temp.owner_id(300),'water',
    clock_timestamp(),current_date,'UTC',pg_temp.owner_id(302));
INSERT INTO public.purchase_ownership(environment,original_transaction_id,owner_id,
    app_account_token,first_verified_access_at)
VALUES('Xcode','t083-internal-deletion',pg_temp.owner_id(1),pg_temp.owner_id(303),clock_timestamp());
SELECT isnt(public.read_owner_profile_settings(pg_temp.owner_id(1)),NULL::jsonb,
    'deletion fixture initially has active profile service access');
SELECT lives_ok($q$SELECT public.fetch_sync_delta(pg_temp.owner_id(1))$q$,
    'deletion fixture initially has active sync access');
SELECT lives_ok($q$SELECT public.get_analysis_access_snapshot(pg_temp.owner_id(1))$q$,
    'deletion fixture initially has active quota access');

-- Matching command and matching hash are independently required for replay.
INSERT INTO public.operation_receipts(owner_id,operation_id,command_name,payload_hash,response_payload)
VALUES
    (pg_temp.owner_id(81),pg_temp.owner_id(312),'account.delete','wrong','{}'),
    (pg_temp.owner_id(81),pg_temp.owner_id(313),'plant.edit',
        encode(sha256(convert_to(jsonb_build_array('account.delete','{}'::jsonb)::text,'UTF8')),'hex'),'{}');
UPDATE public.profiles SET updated_at=clock_timestamp()+interval '2 days'
WHERE id=pg_temp.owner_id(1);

-- Snapshot actual rows, including existing clean/upgrade fixture history.
CREATE FUNCTION pg_temp.deletion_history() RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    relation_name text;
    rows jsonb;
    result jsonb := '{}'::jsonb;
BEGIN
    FOREACH relation_name IN ARRAY ARRAY[
        'catalogue_taxa','plants','care_entries','care_tasks','care_plans',
        'photo_assets','analysis_results','analysis_jobs','installation_access',
        'account_quota_anchors','account_quota_usage','monthly_quotas',
        'purchase_ownership','entitlements']
    LOOP
        EXECUTE format('SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY to_jsonb(r)::text),
            ''[]''::jsonb) FROM public.%I r',relation_name) INTO rows;
        result := result || jsonb_build_object(relation_name,rows);
    END LOOP;
    RETURN result;
END;
$$;
CREATE TEMP TABLE t083_delete_before AS
SELECT pg_temp.deletion_history() AS history,
    (SELECT jsonb_agg(to_jsonb(p) ORDER BY id) FROM public.profiles p) AS profiles,
    (SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY owner_id,operation_id),'[]'::jsonb)
        FROM public.operation_receipts r) AS receipts,
    (SELECT coalesce(jsonb_agg(to_jsonb(q) ORDER BY owner_id),'[]'::jsonb)
        FROM public.account_deletion_requests q) AS requests;
CREATE TEMP TABLE t083_delete_profile AS
SELECT to_jsonb(p) AS body FROM public.profiles p WHERE id=pg_temp.owner_id(1);

-- A failed queue write must roll back the canonical watermark as well.
CREATE FUNCTION pg_temp.reject_delete_intent() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'fixture_queue_failure' USING ERRCODE='P0001';
END;
$$;
CREATE TRIGGER t083_reject_delete_intent BEFORE INSERT ON public.account_deletion_requests
FOR EACH ROW EXECUTE FUNCTION pg_temp.reject_delete_intent();
SELECT throws_ok($q$SELECT public.request_account_deletion_internal(
    pg_temp.owner_id(1),pg_temp.owner_id(310))$q$,
    'P0001','fixture_queue_failure','queue failure rolls back the complete request');
DROP TRIGGER t083_reject_delete_intent ON public.account_deletion_requests;
SELECT is((SELECT to_jsonb(p) FROM public.profiles p WHERE id=pg_temp.owner_id(1)),
    (SELECT body FROM t083_delete_profile),'failed intent preserves active state and watermark');
SELECT is((SELECT count(*) FROM public.operation_receipts
    WHERE owner_id=pg_temp.owner_id(1) AND operation_id=pg_temp.owner_id(310)),
    0::bigint,'failed intent writes no receipt');
SELECT is((SELECT count(*) FROM public.account_deletion_requests WHERE owner_id=pg_temp.owner_id(1)),
    0::bigint,'failed intent writes no queue record');

CREATE TEMP TABLE t083_delete_result AS
SELECT public.request_account_deletion_internal(pg_temp.owner_id(1),pg_temp.owner_id(310)) AS body;
SELECT is((SELECT body FROM t083_delete_result),
    (SELECT jsonb_build_object('owner_id',p.id,'operation_id',pg_temp.owner_id(310),
        'state','deleting','watermark',p.updated_at)
     FROM public.profiles p WHERE p.id=pg_temp.owner_id(1)),
    'request returns the exact canonical owner, operation, state and watermark');
SELECT ok((SELECT p.account_state='deleting'
    AND p.updated_at=(b.body->>'updated_at')::timestamptz+interval '1 microsecond'
    AND to_jsonb(p)-'account_state'-'updated_at'=b.body-'account_state'-'updated_at'
    FROM public.profiles p CROSS JOIN t083_delete_profile b WHERE p.id=pg_temp.owner_id(1)),
    'retirement changes only state and the strictly monotonic owner watermark');
SELECT ok((SELECT count(*)=1 AND bool_and(q.operation_id=pg_temp.owner_id(310)
    AND q.requested_at=(r.body->>'watermark')::timestamptz)
    FROM public.account_deletion_requests q CROSS JOIN t083_delete_result r
    WHERE q.owner_id=pg_temp.owner_id(1)),'exactly one minimal owner intent is recorded');
SELECT ok((SELECT count(*)=1 AND bool_and(r.command_name='account.delete'
    AND r.payload_hash=encode(sha256(convert_to(
        jsonb_build_array('account.delete','{}'::jsonb)::text,'UTF8')),'hex')
    AND r.response_payload=d.body
    AND r.committed_at=(d.body->>'watermark')::timestamptz)
    FROM public.operation_receipts r CROSS JOIN t083_delete_result d
    WHERE r.owner_id=pg_temp.owner_id(1) AND r.operation_id=pg_temp.owner_id(310)),
    'exactly one owner-scoped account.delete receipt stores the original response');

SELECT is(public.read_owner_profile_settings(pg_temp.owner_id(1)),NULL::jsonb,
    'retired owner loses active profile service access');
SELECT throws_ok($q$SELECT public.fetch_sync_delta(pg_temp.owner_id(1))$q$,
    '42501','owner_forbidden','retired owner loses active sync access');
SELECT throws_ok($q$SELECT public.get_analysis_access_snapshot(pg_temp.owner_id(1))$q$,
    '42501','ACTIVE_OWNER_REQUIRED','retired owner loses active quota access');

-- Exercise the conversion trigger against the actual retired permanent profile.
UPDATE auth.users SET is_anonymous=true WHERE id=pg_temp.owner_id(1);
UPDATE auth.users SET is_anonymous=false WHERE id=pg_temp.owner_id(1);
SELECT is(public.request_account_deletion_internal(pg_temp.owner_id(1),pg_temp.owner_id(310)),
    (SELECT body FROM t083_delete_result),'exact retry remains valid after Auth sync in deleting state');
SELECT ok((SELECT account_state='deleting' AND NOT anonymous
    AND updated_at=(r.body->>'watermark')::timestamptz
    FROM public.profiles p CROSS JOIN t083_delete_result r WHERE p.id=pg_temp.owner_id(1)),
    'Auth profile sync cannot revive or advance the deleting owner');

SELECT throws_ok(format('SELECT public.request_account_deletion_internal(%L::uuid,%L::uuid)',
    pg_temp.owner_id(n),pg_temp.owner_id(310)),
    '42501','ACTIVE_PERMANENT_OWNER_REQUIRED','no foreign receipt or inactive owner disclosure: '||n)
FROM (VALUES (4),(82),(83),(85),(86)) rejected(n);
SELECT throws_ok($q$SELECT public.request_account_deletion_internal(NULL,pg_temp.owner_id(310))$q$,
    '42501','ACTIVE_PERMANENT_OWNER_REQUIRED','null owner cannot request deletion');
SELECT throws_ok($q$SELECT public.request_account_deletion_internal(pg_temp.owner_id(1),pg_temp.owner_id(311))$q$,
    '42501','ACTIVE_PERMANENT_OWNER_REQUIRED','new operation cannot retire an already deleting owner');
SELECT throws_ok($q$SELECT public.request_account_deletion_internal(pg_temp.owner_id(81),NULL)$q$,
    '22023','INVALID_ACCOUNT_DELETE_INPUT','active owner must supply an operation UUID');
SELECT throws_ok($q$SELECT public.request_account_deletion_internal(pg_temp.owner_id(80),pg_temp.owner_id(104))$q$,
    '23505','IDEMPOTENCY_CONFLICT','existing other-command receipt cannot request account deletion');
SELECT throws_ok($q$SELECT public.request_account_deletion_internal(pg_temp.owner_id(80),pg_temp.owner_id(100))$q$,
    '23505','IDEMPOTENCY_CONFLICT','profile.update receipt cannot replay as account.delete');

SELECT throws_ok($q$SELECT public.request_account_deletion_internal(pg_temp.owner_id(81),pg_temp.owner_id(312))$q$,
    '23505','IDEMPOTENCY_CONFLICT','matching command with a foreign hash cannot replay');
SELECT throws_ok($q$SELECT public.request_account_deletion_internal(pg_temp.owner_id(81),pg_temp.owner_id(313))$q$,
    '23505','IDEMPOTENCY_CONFLICT','matching hash with another command cannot replay');

SELECT is(pg_temp.deletion_history(),(SELECT history FROM t083_delete_before),
    'deletion preserves catalogue, journal, jobs, quota and purchase fixture history byte for byte');
SELECT is((SELECT jsonb_agg(to_jsonb(p) ORDER BY id) FROM public.profiles p
    WHERE id<>pg_temp.owner_id(1)),
    (SELECT jsonb_agg(value ORDER BY value->>'id') FROM t083_delete_before b,
        LATERAL jsonb_array_elements(b.profiles) WHERE value->>'id'<>pg_temp.owner_id(1)::text),
    'other owners including rejected owners retain their exact profile and watermark');
SELECT is((SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY owner_id,operation_id),'[]'::jsonb)
    FROM public.operation_receipts r
    WHERE NOT (owner_id=pg_temp.owner_id(1) AND operation_id=pg_temp.owner_id(310))),
    (SELECT receipts FROM t083_delete_before),'all prior receipts remain unchanged and no rejected receipt appears');
SELECT is((SELECT coalesce(jsonb_agg(to_jsonb(q) ORDER BY owner_id),'[]'::jsonb)
    FROM public.account_deletion_requests q WHERE owner_id<>pg_temp.owner_id(1)),
    (SELECT requests FROM t083_delete_before),'no cross-owner intent is created');
SELECT is((SELECT count(*) FROM public.account_deletion_requests WHERE owner_id=pg_temp.owner_id(1)),
    1::bigint,'retries and rejected requests leave exactly one intent');

SELECT ok(NOT has_function_privilege(role_name,
    'public.request_account_deletion_internal(uuid,uuid)','EXECUTE')
    AND NOT has_table_privilege(role_name,'public.account_deletion_requests',
        'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER'),
    'internal writer and queue grant no direct access to '||role_name)
FROM (VALUES ('anon'),('authenticated'),('service_role')) roles(role_name);
SELECT ok((SELECT relrowsecurity FROM pg_class
    WHERE oid='public.account_deletion_requests'::regclass)
    AND NOT EXISTS (SELECT 1 FROM pg_policy WHERE polrelid='public.account_deletion_requests'::regclass)
    AND NOT EXISTS (SELECT 1 FROM pg_class c,
        LATERAL aclexplode(coalesce(c.relacl,acldefault('r',c.relowner))) a
        WHERE c.oid='public.account_deletion_requests'::regclass AND a.grantee=0)
    AND NOT EXISTS (SELECT 1 FROM pg_proc p,
        LATERAL aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) a
        WHERE p.oid='public.request_account_deletion_internal(uuid,uuid)'::regprocedure
          AND a.grantee=0 AND a.privilege_type='EXECUTE'),
    'private queue enables RLS without policies and PUBLIC has no queue or writer grants');

-- Internal bounded media projection; fixture-only, no purge or product route.
INSERT INTO auth.users(id,is_anonymous,created_at) VALUES
    (pg_temp.owner_id(900),false,clock_timestamp()),
    (pg_temp.owner_id(901),false,clock_timestamp()),
    (pg_temp.owner_id(902),true,clock_timestamp());
SELECT is(public.read_account_deletion_media_inventory(pg_temp.owner_id(900)),NULL::jsonb,
    'active owner without a queued request has no inventory');
UPDATE public.profiles SET account_state='deleting' WHERE id=pg_temp.owner_id(900);
SELECT is(public.read_account_deletion_media_inventory(pg_temp.owner_id(900)),NULL::jsonb,
    'deleting state alone is not a canonical request');
UPDATE public.profiles SET account_state='active' WHERE id=pg_temp.owner_id(900);

INSERT INTO public.photo_assets(id,owner_id,purpose,original_key,analysis_key,content_hash)
SELECT pg_temp.owner_id(n),pg_temp.owner_id(CASE WHEN n IN (1028,1033) THEN 901 ELSE 900 END),
    'initial',
    CASE WHEN n=1022 THEN 'legacy/unsafe.jpg' ELSE
        pg_temp.owner_id(CASE WHEN n IN (1028,1033) THEN 901 ELSE 900 END)::text
        ||'/'||pg_temp.owner_id(n)::text END,
    CASE WHEN n=1023 THEN 'private/unsafe-thumbnail.jpg'
         WHEN n=1033 THEN pg_temp.owner_id(900)::text||'/'||pg_temp.owner_id(1030)::text
         ELSE NULL END,
    repeat('a',64)
FROM (SELECT generate_series(1001,1030) n UNION ALL SELECT 1032 UNION ALL SELECT 1033) ids;
INSERT INTO public.diagnosis_upload_tickets(photo_asset_id,mime_type,byte_size,expires_at)
SELECT id,'image/jpeg',4,
    CASE WHEN id=pg_temp.owner_id(1025) THEN clock_timestamp()+interval '1 day'
         ELSE clock_timestamp()-interval '1 day' END
FROM public.photo_assets
WHERE id BETWEEN pg_temp.owner_id(1001) AND pg_temp.owner_id(1033)
  AND id<>pg_temp.owner_id(1024);
INSERT INTO storage.objects(bucket_id,name)
SELECT 'analysis-inputs',original_key FROM public.photo_assets
WHERE id BETWEEN pg_temp.owner_id(1001) AND pg_temp.owner_id(1033)
  AND id<>pg_temp.owner_id(1029);
-- The same canonical name in a catalogue bucket is never private input evidence.
INSERT INTO storage.buckets(id,name,public) VALUES('t083-catalogue','t083-catalogue',true);
INSERT INTO storage.objects(bucket_id,name)
SELECT 't083-catalogue',original_key FROM public.photo_assets WHERE id=pg_temp.owner_id(1029);
UPDATE public.photo_assets SET state='deleted',deleted_at=clock_timestamp()
WHERE id=pg_temp.owner_id(1021);
INSERT INTO public.plants(id,owner_id,personal_name,creation_source,main_photo_id)
VALUES(pg_temp.owner_id(950),pg_temp.owner_id(901),'External hold','analysis',pg_temp.owner_id(1027));
INSERT INTO public.analysis_jobs(id,owner_id,flow_id,intent,add_method,mode,prompt_version,
    operation_id,payload_hash,locale,quota_kind,quota_state,photo_ids,state,lease_token,
    provider_started_at,deadline_at)
VALUES(pg_temp.owner_id(951),pg_temp.owner_id(900),pg_temp.owner_id(952),'care','scan',
    'identification','fixture',pg_temp.owner_id(953),'inventory','en','none','not_applicable',
    ARRAY[pg_temp.owner_id(1026)],'running',pg_temp.owner_id(954),
    clock_timestamp()-interval '2 hours',clock_timestamp()-interval '1 hour');
INSERT INTO public.guest_drafts(id,guest_owner_id,flow_id,intent,add_method,photo_id,source_storage_key)
SELECT pg_temp.owner_id(955),pg_temp.owner_id(900),pg_temp.owner_id(956),'care','scan',id,original_key
FROM public.photo_assets WHERE id=pg_temp.owner_id(1032);
INSERT INTO public.draft_claims(id,draft_id,proof_hash,target_owner_id,operation_id,state,expires_at)
VALUES(pg_temp.owner_id(957),pg_temp.owner_id(955),'fixture',pg_temp.owner_id(901),
    pg_temp.owner_id(958),'copying',clock_timestamp()-interval '1 hour');
SELECT public.request_account_deletion_internal(pg_temp.owner_id(900),pg_temp.owner_id(959));
UPDATE public.profiles SET account_state='active' WHERE id=pg_temp.owner_id(900);
SELECT is(public.read_account_deletion_media_inventory(pg_temp.owner_id(900)),NULL::jsonb,
    'queued request without deleting state has no inventory');
UPDATE public.profiles SET account_state='deleting'
WHERE id IN (pg_temp.owner_id(900),pg_temp.owner_id(902));
INSERT INTO public.account_deletion_requests(owner_id,operation_id,requested_at)
VALUES(pg_temp.owner_id(902),pg_temp.owner_id(960),clock_timestamp());
INSERT INTO public.operation_receipts(
    owner_id,operation_id,command_name,payload_hash,response_payload,committed_at)
SELECT owner_id,operation_id,'account.delete',encode(sha256(convert_to(
    jsonb_build_array('account.delete','{}'::jsonb)::text,'UTF8')),'hex'),
    jsonb_build_object('owner_id',owner_id,'operation_id',operation_id,
        'state','deleting','watermark',requested_at),requested_at
FROM public.account_deletion_requests WHERE owner_id=pg_temp.owner_id(902);
SELECT is(public.read_account_deletion_media_inventory(pg_temp.owner_id(902)),NULL::jsonb,
    'queued anonymous owner has no inventory');
UPDATE public.operation_receipts SET payload_hash='forged'
WHERE owner_id=pg_temp.owner_id(900) AND operation_id=pg_temp.owner_id(959);
SELECT is(public.read_account_deletion_media_inventory(pg_temp.owner_id(900)),NULL::jsonb,
    'noncanonical request receipt has no inventory');
UPDATE public.operation_receipts SET payload_hash=encode(sha256(convert_to(
    jsonb_build_array('account.delete','{}'::jsonb)::text,'UTF8')),'hex')
WHERE owner_id=pg_temp.owner_id(900) AND operation_id=pg_temp.owner_id(959);

CREATE FUNCTION pg_temp.media_inventory_snapshot() RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    relation_name text;
    rows jsonb;
    result jsonb := pg_temp.deletion_history();
BEGIN
    FOREACH relation_name IN ARRAY ARRAY[
        'public.profiles','public.operation_receipts','public.account_deletion_requests',
        'public.diagnosis_upload_tickets','public.first_aid_photo_upload_tickets',
        'public.draft_claims','public.guest_drafts','public.guest_identification_sources',
        'public.diagnosis_job_runtime','storage.objects','storage.buckets']
    LOOP
        EXECUTE format('SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY to_jsonb(r)::text),
            ''[]''::jsonb) FROM %s r',relation_name) INTO rows;
        result := result || jsonb_build_object(relation_name,rows);
    END LOOP;
    RETURN result;
END;
$$;
CREATE TEMP TABLE t083_media_before AS SELECT pg_temp.media_inventory_snapshot() body;
CREATE TEMP TABLE t083_media_page AS
SELECT public.read_account_deletion_media_inventory(pg_temp.owner_id(900)) body;
SELECT is((SELECT body->'photo_ids' FROM t083_media_page),
    (SELECT jsonb_agg(pg_temp.owner_id(n) ORDER BY n) FROM generate_series(1001,1020) n),
    'first page contains exactly twenty ordered canonical private original photo IDs');
SELECT is((SELECT body->>'next_cursor' FROM t083_media_page),pg_temp.owner_id(1020)::text,
    'cursor is the last emitted UUID');
SELECT is(public.read_account_deletion_media_inventory(pg_temp.owner_id(900),
    pg_temp.owner_id(1020))->'photo_ids',jsonb_build_array(pg_temp.owner_id(1021)),
    'exclusive second page includes a tombstoned photo whose object still exists');
SELECT is(public.read_account_deletion_media_inventory(pg_temp.owner_id(900),
    pg_temp.owner_id(1033))->'photo_ids','[]'::jsonb,'cursor beyond inventory yields an empty page');
SELECT is(public.read_account_deletion_media_inventory(pg_temp.owner_id(900),
    pg_temp.owner_id(1033))->>'blocked','6','blocked count remains global beyond the cursor');
SELECT is((SELECT body->>'waiting' FROM t083_media_page),'3',
    'live upload, unsettled provider lease and expired copying claim remain waiting');
SELECT is((SELECT body->>'blocked' FROM t083_media_page),'6',
    'legacy, thumbnail, missing ticket, foreign plant, shared key and draft holds block');
SELECT ok((SELECT body::text NOT LIKE '%unsafe%' AND body::text NOT LIKE '%legacy/%'
    AND NOT (body->'photo_ids' @> jsonb_build_array(pg_temp.owner_id(1028)))
    AND NOT (body->'photo_ids' @> jsonb_build_array(pg_temp.owner_id(1029)))
    FROM t083_media_page),'unsafe keys, foreign photos and catalogue-only objects never escape');
SELECT is(public.read_account_deletion_media_inventory(NULL),NULL::jsonb,'null owner has no inventory');
SELECT is(public.read_account_deletion_media_inventory(pg_temp.owner_id(901)),NULL::jsonb,
    'foreign active owner has no projection');
SELECT ok(NOT has_function_privilege(role_name,
    'public.read_account_deletion_media_inventory(uuid,uuid)','EXECUTE'),
    'internal inventory grants no execution to '||role_name)
FROM (VALUES ('anon'),('authenticated'),('service_role')) roles(role_name);
SELECT ok(NOT EXISTS (SELECT 1 FROM pg_proc p,
    LATERAL aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) a
    WHERE p.oid='public.read_account_deletion_media_inventory(uuid,uuid)'::regprocedure
      AND a.grantee=0 AND a.privilege_type='EXECUTE'),
    'PUBLIC cannot execute inventory');
SELECT is(pg_temp.media_inventory_snapshot(),(SELECT body FROM t083_media_before),
    'projection leaves source rows, leases, objects, quota, receipts and watermarks unchanged');

-- Keep the fixture usable when the migration selector stops at 061.
CREATE FUNCTION pg_temp.namespace_hold_tests() RETURNS SETOF text LANGUAGE plpgsql AS $$
DECLARE
    v_owner uuid := 'a0620000-0000-4000-8000-000000000001';
    v_neighbor uuid := 'a0620000-0000-4000-8000-000000000002';
    v_guest uuid := 'a0620000-0000-4000-8000-000000000003';
    v_receipt public.operation_receipts%ROWTYPE;
    v_body jsonb;
    v_before jsonb;
    v_variant integer;
    v_role text;
BEGIN
    IF to_regprocedure('public.read_account_deletion_namespace_holds(uuid)') IS NULL THEN
        RETURN QUERY SELECT skip('062 namespace projection is outside selected migration version',1);
        RETURN;
    END IF;

    INSERT INTO auth.users(id,is_anonymous,created_at) VALUES
        (v_owner,false,clock_timestamp()),(v_neighbor,false,clock_timestamp()),
        (v_guest,true,clock_timestamp());
    RETURN NEXT is(public.read_account_deletion_namespace_holds(NULL),NULL::jsonb,
        'namespace projection rejects a null owner');
    RETURN NEXT is(public.read_account_deletion_namespace_holds(pg_temp.owner_id(1299)),NULL::jsonb,
        'namespace projection rejects an unavailable owner');
    RETURN NEXT is(public.read_account_deletion_namespace_holds(v_owner),NULL::jsonb,
        'active owner has no namespace projection');
    UPDATE public.profiles SET account_state='deleting' WHERE id=v_owner;
    RETURN NEXT is(public.read_account_deletion_namespace_holds(v_owner),NULL::jsonb,
        'deleting owner without a persisted request has no namespace projection');
    UPDATE public.profiles SET account_state='active' WHERE id=v_owner;
    PERFORM public.request_account_deletion_internal(v_owner,pg_temp.owner_id(1199));
    SELECT * INTO STRICT v_receipt FROM public.operation_receipts
    WHERE owner_id=v_owner AND operation_id=pg_temp.owner_id(1199);
    RETURN NEXT is(public.read_account_deletion_namespace_holds(v_owner),
        jsonb_build_object('orphan_objects',0,'guest_draft_sources',0,
            'guest_identification_sources',0,'incoming_claims',0),
        'empty queued owner exposes aggregate zero counts only');

    FOR v_variant IN 1..4 LOOP
        UPDATE public.operation_receipts SET
            command_name=CASE WHEN v_variant=1 THEN 'forged' ELSE v_receipt.command_name END,
            payload_hash=CASE WHEN v_variant=2 THEN 'forged' ELSE v_receipt.payload_hash END,
            committed_at=CASE WHEN v_variant=3 THEN v_receipt.committed_at+interval '1 second'
                ELSE v_receipt.committed_at END,
            response_payload=CASE WHEN v_variant=4 THEN v_receipt.response_payload || '{"extra":true}'::jsonb
                ELSE v_receipt.response_payload END
        WHERE owner_id=v_owner AND operation_id=v_receipt.operation_id;
        RETURN NEXT is(public.read_account_deletion_namespace_holds(v_owner),NULL::jsonb,
            'namespace projection rejects forged receipt component '||v_variant);
    END LOOP;
    UPDATE public.operation_receipts SET command_name=v_receipt.command_name,
        payload_hash=v_receipt.payload_hash,committed_at=v_receipt.committed_at,
        response_payload=v_receipt.response_payload
    WHERE owner_id=v_owner AND operation_id=v_receipt.operation_id;
    UPDATE public.account_deletion_requests SET operation_id=pg_temp.owner_id(1198)
    WHERE owner_id=v_owner;
    RETURN NEXT is(public.read_account_deletion_namespace_holds(v_owner),NULL::jsonb,
        'request with no matching receipt is unavailable');
    UPDATE public.account_deletion_requests SET operation_id=v_receipt.operation_id WHERE owner_id=v_owner;
    RETURN NEXT is(public.read_account_deletion_namespace_holds(pg_temp.owner_id(902)),NULL::jsonb,
        'anonymous owner cannot acquire a namespace projection from a queued receipt');
    UPDATE public.profiles SET account_state='active' WHERE id=v_owner;
    RETURN NEXT is(public.read_account_deletion_namespace_holds(v_owner),NULL::jsonb,
        'queued receipt requires a deleting owner');
    UPDATE public.profiles SET account_state='deleting' WHERE id=v_owner;

    INSERT INTO public.photo_assets(id,owner_id,purpose,original_key,content_hash)
    VALUES
        (pg_temp.owner_id(1200),v_owner,'initial',v_owner::text||'/'||pg_temp.owner_id(1200),repeat('a',64)),
        (pg_temp.owner_id(1201),v_owner,'initial',v_owner::text||'/legacy/unsafe.jpg',repeat('a',64)),
        (pg_temp.owner_id(1202),v_neighbor,'initial',v_owner::text||'/'||pg_temp.owner_id(1202),repeat('a',64)),
        (pg_temp.owner_id(1203),v_guest,'initial',v_guest::text||'/'||pg_temp.owner_id(1203),repeat('a',64)),
        (pg_temp.owner_id(1204),v_owner,'initial','legacy/outside-owner.jpg',repeat('a',64));
    INSERT INTO storage.objects(bucket_id,name) VALUES
        ('analysis-inputs',v_owner::text||'/'||pg_temp.owner_id(1200)),
        ('analysis-inputs',v_owner::text||'/unknown'),
        ('analysis-inputs',v_owner::text||'/legacy/unsafe.jpg'),
        ('analysis-inputs',v_owner::text||'/'||pg_temp.owner_id(1202)),
        ('analysis-inputs',v_owner::text||'-neighbor/unknown'),
        ('analysis-inputs',v_neighbor::text||'/unknown'),
        ('analysis-inputs',upper(v_owner::text)||'/unknown'),
        ('analysis-inputs','legacy/outside-owner.jpg'),
        ('t083-catalogue',v_owner::text||'/catalogue-only');
    -- Canonical tombstones still track their original keys.
    UPDATE public.photo_assets SET state='deleted',deleted_at=clock_timestamp()
    WHERE id=pg_temp.owner_id(1200);
    INSERT INTO public.installation_access(id,credential_hash,linked_owner_ids)
    VALUES(pg_temp.owner_id(1250),'namespace-hold-fixture',ARRAY[v_owner,v_neighbor,v_guest]);
    INSERT INTO public.guest_drafts(id,guest_owner_id,flow_id,intent,add_method,
        photo_id,source_storage_key,installation_id,expires_at,deleted_at,claimed_at,storage_cleaned_at)
    SELECT pg_temp.owner_id(n),CASE WHEN n=1213 THEN v_neighbor ELSE v_owner END,
        pg_temp.owner_id(n+100),'care','scan',
        CASE WHEN n=1211 THEN pg_temp.owner_id(1202) ELSE pg_temp.owner_id(1200) END,
        'legacy/guest-source-'||n,pg_temp.owner_id(1250),clock_timestamp()-interval '1 day',
        CASE WHEN n=1210 THEN clock_timestamp() END,
        CASE WHEN n=1211 THEN clock_timestamp() END,
        CASE WHEN n=1212 THEN clock_timestamp() END
    FROM generate_series(1210,1213) n;
    INSERT INTO public.guest_identification_sources(photo_id,succeeded_at,expires_at,storage_cleaned_at)
    SELECT pg_temp.owner_id(n),clock_timestamp()-interval '2 days',clock_timestamp()-interval '1 day',
        CASE WHEN n=1201 THEN clock_timestamp() END
    FROM generate_series(1200,1202) n;
    -- Shared installation binding establishes no additional source ownership.
    -- These guest targets have no destination object yet.
    INSERT INTO public.guest_drafts(id,guest_owner_id,flow_id,intent,add_method,
        photo_id,source_storage_key,installation_id,storage_cleaned_at)
    SELECT pg_temp.owner_id(n),v_guest,pg_temp.owner_id(n+100),'care','scan',
        pg_temp.owner_id(1203),v_guest::text||'/'||pg_temp.owner_id(1203),pg_temp.owner_id(1250),
        CASE WHEN n=1225 THEN clock_timestamp() END
    FROM generate_series(1220,1226) n;
    INSERT INTO public.draft_claims(draft_id,proof_hash,target_owner_id,operation_id,state,expires_at)
    SELECT pg_temp.owner_id(n),'namespace-fixture',
        CASE WHEN n=1226 THEN v_neighbor ELSE v_owner END,pg_temp.owner_id(n+200),
        CASE WHEN n IN (1221,1225) THEN 'copying' WHEN n=1223 THEN 'published'
            WHEN n=1224 THEN 'cleanup_done' ELSE 'prepared' END,
        CASE WHEN n IN (1221,1222) THEN clock_timestamp()-interval '1 day'
            ELSE clock_timestamp()+interval '1 day' END
    FROM generate_series(1220,1226) n;

    v_before := pg_temp.media_inventory_snapshot();
    v_body := public.read_account_deletion_namespace_holds(v_owner);
    RETURN NEXT is(v_body,jsonb_build_object('orphan_objects',3,'guest_draft_sources',2,
        'guest_identification_sources',1,'incoming_claims',2),
        'only owner namespace orphans, unresolved direct sources and live/copying targets count');
    RETURN NEXT ok(NOT EXISTS (SELECT 1 FROM jsonb_each(v_body) e
        WHERE jsonb_typeof(e.value)<>'number'),
        'namespace projection emits counts only without IDs or storage paths');
    RETURN NEXT is(public.read_account_deletion_namespace_holds(v_neighbor),NULL::jsonb,
        'neighbor sharing installation binding has no queued projection');
    RETURN NEXT is(public.read_account_deletion_namespace_holds(v_owner),v_body,
        'repeated namespace reads retain every unresolved hold');
    RETURN NEXT is(pg_temp.media_inventory_snapshot(),v_before,
        'namespace reads leave rows, objects, jobs, receipts, quotas and watermarks unchanged');

    UPDATE public.guest_drafts SET storage_cleaned_at=clock_timestamp()
    WHERE id IN (pg_temp.owner_id(1210),pg_temp.owner_id(1211),pg_temp.owner_id(1221));
    UPDATE public.guest_identification_sources SET storage_cleaned_at=clock_timestamp()
    WHERE photo_id=pg_temp.owner_id(1200);
    UPDATE public.draft_claims SET state='published' WHERE draft_id=pg_temp.owner_id(1220);
    v_before := pg_temp.media_inventory_snapshot();
    RETURN NEXT is(public.read_account_deletion_namespace_holds(v_owner),
        jsonb_build_object('orphan_objects',3,'guest_draft_sources',0,
            'guest_identification_sources',0,'incoming_claims',0),
        'settled targets and confirmed cleaned sources release holds without hiding orphans');
    RETURN NEXT is(pg_temp.media_inventory_snapshot(),v_before,
        'settled projection also preserves all source data');
    FOREACH v_role IN ARRAY ARRAY['anon','authenticated','service_role'] LOOP
        RETURN NEXT ok(NOT has_function_privilege(v_role,
            'public.read_account_deletion_namespace_holds(uuid)','EXECUTE'),
            'namespace projection denies execution to '||v_role);
    END LOOP;
    RETURN NEXT ok(NOT EXISTS (SELECT 1 FROM pg_proc p,
        LATERAL aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) a
        WHERE p.oid='public.read_account_deletion_namespace_holds(uuid)'::regprocedure
          AND a.grantee=0 AND a.privilege_type='EXECUTE'),
        'PUBLIC cannot execute namespace projection');
END;
$$;
SELECT * FROM pg_temp.namespace_hold_tests();

-- Resolve 063 calls only after the version gate (061/062 selectors still work).
CREATE FUNCTION pg_temp.storage_work_plan_tests() RETURNS SETOF text LANGUAGE plpgsql AS $$
DECLARE
    v_owner uuid := 'a0630000-0000-4000-8000-000000000001';
    v_neighbor uuid := 'a0630000-0000-4000-8000-000000000002';
    v_body jsonb;
    v_before jsonb;
    v_receipt public.operation_receipts%ROWTYPE;
    v_field text;
    v_case integer;
    v_service_enabled boolean;
    v_role text;
    v_denied boolean;
BEGIN
    IF to_regprocedure('public.read_account_deletion_storage_work_plan(uuid)') IS NULL THEN
        RETURN QUERY SELECT skip('063 work plan is outside selected migration version',1);
        RETURN;
    END IF;
    INSERT INTO auth.users(id,is_anonymous,created_at) VALUES
        (v_owner,false,clock_timestamp()),(v_neighbor,false,clock_timestamp());
    RETURN NEXT is(public.read_account_deletion_storage_work_plan(NULL),NULL::jsonb,
        'work plan rejects null owner');
    UPDATE public.profiles SET account_state='deleting' WHERE id=v_owner;
    RETURN NEXT is(public.read_account_deletion_storage_work_plan(v_owner),NULL::jsonb,
        'deleting flag alone supplies no work plan');
    UPDATE public.profiles SET account_state='active' WHERE id=v_owner;
    PERFORM public.request_account_deletion_internal(v_owner,pg_temp.owner_id(1399));
    SELECT * INTO STRICT v_receipt FROM public.operation_receipts
    WHERE owner_id=v_owner AND operation_id=pg_temp.owner_id(1399);
    FOR v_case IN 1..4 LOOP
        UPDATE public.operation_receipts SET
            command_name=CASE WHEN v_case=1 THEN 'forged' ELSE v_receipt.command_name END,
            payload_hash=CASE WHEN v_case=2 THEN 'forged' ELSE v_receipt.payload_hash END,
            committed_at=CASE WHEN v_case=3 THEN v_receipt.committed_at+interval '1 second'
                ELSE v_receipt.committed_at END,
            response_payload=CASE WHEN v_case=4 THEN v_receipt.response_payload||'{"extra":true}'::jsonb
                ELSE v_receipt.response_payload END
        WHERE owner_id=v_owner AND operation_id=v_receipt.operation_id;
        RETURN NEXT is(public.read_account_deletion_storage_work_plan(v_owner),NULL::jsonb,
            'work plan rejects forged receipt component '||v_case);
    END LOOP;
    UPDATE public.operation_receipts SET command_name=v_receipt.command_name,
        payload_hash=v_receipt.payload_hash,committed_at=v_receipt.committed_at,
        response_payload=v_receipt.response_payload
    WHERE owner_id=v_owner AND operation_id=v_receipt.operation_id;
    UPDATE public.account_deletion_requests SET operation_id=pg_temp.owner_id(1398)
    WHERE owner_id=v_owner;
    RETURN NEXT is(public.read_account_deletion_storage_work_plan(v_owner),NULL::jsonb,
        'work plan requires the exact queued receipt');
    UPDATE public.account_deletion_requests SET operation_id=v_receipt.operation_id WHERE owner_id=v_owner;

    INSERT INTO public.photo_assets(id,owner_id,purpose,original_key,content_hash)
    SELECT pg_temp.owner_id(n),v_owner,'initial',v_owner::text||'/'||pg_temp.owner_id(n),repeat('a',64)
    FROM generate_series(1300,1320) n;
    INSERT INTO public.diagnosis_upload_tickets(photo_asset_id,mime_type,byte_size,expires_at)
    SELECT pg_temp.owner_id(n),'image/jpeg',4,clock_timestamp()-interval '1 day'
    FROM generate_series(1300,1320) n;
    INSERT INTO storage.objects(bucket_id,name)
    SELECT 'analysis-inputs',original_key FROM public.photo_assets WHERE owner_id=v_owner;
    UPDATE public.photo_assets SET state='deleted',deleted_at=clock_timestamp()
    WHERE id=pg_temp.owner_id(1320);
    v_before := pg_temp.media_inventory_snapshot();
    v_body := public.read_account_deletion_storage_work_plan(v_owner);
    RETURN NEXT is(v_body->'photo_ids',
        (SELECT jsonb_agg(pg_temp.owner_id(n) ORDER BY n) FROM generate_series(1300,1319) n),
        'work plan emits at most twenty validated first-page IDs');
    RETURN NEXT is(v_body->>'storage_ready','false','full work page prevents readiness');
    RETURN NEXT is(public.read_account_deletion_storage_work_plan(v_owner),v_body,
        'retry retains all still-owned objects');
    RETURN NEXT is(pg_temp.media_inventory_snapshot(),v_before,'work plan reads preserve source rows');
    DELETE FROM storage.objects WHERE bucket_id='analysis-inputs'
        AND name IN (SELECT original_key FROM public.photo_assets
            WHERE owner_id=v_owner AND id<>pg_temp.owner_id(1320));
    v_body := public.read_account_deletion_storage_work_plan(v_owner);
    RETURN NEXT is(v_body->'photo_ids',jsonb_build_array(pg_temp.owner_id(1320)),
        'partial first page retains tombstoned surviving object');
    RETURN NEXT is(v_body->>'storage_ready','false','partial page cannot signal readiness');
    RETURN NEXT is(public.read_account_deletion_storage_work_plan(v_owner),v_body,
        'retry cannot skip the surviving object with a cursor');
    DELETE FROM storage.objects WHERE bucket_id='analysis-inputs'
        AND name=v_owner::text||'/'||pg_temp.owner_id(1320);
    v_body := public.read_account_deletion_storage_work_plan(v_owner);
    RETURN NEXT is(v_body,jsonb_build_object('owner_id',v_owner,'photo_ids','[]'::jsonb,
        'blocked',0,'waiting',0,'orphan_objects',0,'guest_draft_sources',0,
        'guest_identification_sources',0,'incoming_claims',0,'storage_ready',true),
        'actual canonical object removal supplies clean evidence despite retained photo rows');

    -- Each independent hold is introduced against the otherwise clean owner.
    FOR v_case IN 1..6 LOOP
        IF v_case=1 THEN
            UPDATE public.photo_assets SET analysis_key='unsafe/thumbnail'
            WHERE id=pg_temp.owner_id(1300);
            v_field := 'blocked';
        ELSIF v_case=2 THEN
            UPDATE public.diagnosis_upload_tickets SET expires_at=clock_timestamp()+interval '1 day'
            WHERE photo_asset_id=pg_temp.owner_id(1300);
            v_field := 'waiting';
        ELSIF v_case=3 THEN
            INSERT INTO storage.objects(bucket_id,name) VALUES('analysis-inputs',v_owner::text||'/orphan');
            v_field := 'orphan_objects';
        ELSIF v_case=4 THEN
            INSERT INTO public.guest_drafts(id,guest_owner_id,flow_id,intent,add_method,source_storage_key)
            VALUES(pg_temp.owner_id(1340),v_owner,pg_temp.owner_id(1341),'care','scan','legacy/source');
            v_field := 'guest_draft_sources';
        ELSIF v_case=5 THEN
            INSERT INTO public.guest_identification_sources(photo_id,succeeded_at,expires_at)
            VALUES(pg_temp.owner_id(1300),clock_timestamp()-interval '2 days',clock_timestamp()-interval '1 day');
            v_field := 'guest_identification_sources';
        ELSE
            INSERT INTO public.guest_drafts(id,guest_owner_id,flow_id,intent,add_method,source_storage_key)
            VALUES(pg_temp.owner_id(1350),v_neighbor,pg_temp.owner_id(1351),'care','scan','legacy/incoming');
            INSERT INTO public.draft_claims(draft_id,proof_hash,target_owner_id,operation_id,state,expires_at)
            VALUES(pg_temp.owner_id(1350),'work-plan',v_owner,pg_temp.owner_id(1352),
                'copying',clock_timestamp()-interval '1 day');
            v_field := 'incoming_claims';
        END IF;
        v_before := pg_temp.media_inventory_snapshot();
        v_body := public.read_account_deletion_storage_work_plan(v_owner);
        RETURN NEXT is(v_body->>v_field,'1','work plan exposes hold '||v_field);
        RETURN NEXT is(v_body->>'storage_ready','false','hold prevents readiness: '||v_field);
        RETURN NEXT is(pg_temp.media_inventory_snapshot(),v_before,'hold read preserves sources: '||v_field);
        IF v_case=1 THEN
            UPDATE public.photo_assets SET analysis_key=NULL WHERE id=pg_temp.owner_id(1300);
        ELSIF v_case=2 THEN
            UPDATE public.diagnosis_upload_tickets SET expires_at=clock_timestamp()-interval '1 day'
            WHERE photo_asset_id=pg_temp.owner_id(1300);
        ELSIF v_case=3 THEN
            DELETE FROM storage.objects WHERE bucket_id='analysis-inputs' AND name=v_owner::text||'/orphan';
        ELSIF v_case=4 THEN
            UPDATE public.guest_drafts SET storage_cleaned_at=clock_timestamp() WHERE id=pg_temp.owner_id(1340);
        ELSIF v_case=5 THEN
            UPDATE public.guest_identification_sources SET storage_cleaned_at=clock_timestamp()
            WHERE photo_id=pg_temp.owner_id(1300);
        ELSE
            UPDATE public.guest_drafts SET storage_cleaned_at=clock_timestamp() WHERE id=pg_temp.owner_id(1350);
        END IF;
        RETURN NEXT is(public.read_account_deletion_storage_work_plan(v_owner)->>'storage_ready','true',
            'confirmed removal of hold restores clean readiness: '||v_field);
    END LOOP;
    UPDATE storage.buckets SET public=true WHERE id='analysis-inputs';
    RETURN NEXT is(public.read_account_deletion_storage_work_plan(v_owner)->>'storage_ready','false',
        'public canonical bucket prevents readiness');
    UPDATE storage.buckets SET public=false WHERE id='analysis-inputs';
    -- Roll back only this fixture perturbation, including other owners objects.
    BEGIN
        DELETE FROM storage.objects WHERE bucket_id='analysis-inputs';
        DELETE FROM storage.buckets WHERE id='analysis-inputs';
        RETURN NEXT is(public.read_account_deletion_storage_work_plan(v_owner)->>'storage_ready','false',
            'absent canonical bucket prevents readiness');
        RAISE SQLSTATE 'Z0063';
    EXCEPTION WHEN SQLSTATE 'Z0063' THEN NULL;
    END;
    RETURN NEXT is(public.read_account_deletion_storage_work_plan(v_neighbor),NULL::jsonb,
        'neighbor cannot acquire a plan from another owners receipt');
    RETURN NEXT is(public.read_account_deletion_storage_work_plan(pg_temp.owner_id(902)),NULL::jsonb,
        'anonymous forged queue remains unavailable');
    RETURN NEXT ok(NOT EXISTS (SELECT 1 FROM jsonb_each(v_body) e
        WHERE e.key NOT IN ('owner_id','photo_ids','blocked','waiting','orphan_objects',
            'guest_draft_sources','guest_identification_sources','incoming_claims','storage_ready')),
        'work plan exposes no raw names or cursor');
    -- Explicit marker preserves historical 063-only permission assertions.
    v_service_enabled := coalesce(obj_description(
        'public.read_account_deletion_storage_work_plan(uuid)'::regprocedure,'pg_proc')
        = '064: account storage work plan service-only execution',false);
    RETURN NEXT ok(NOT EXISTS (SELECT 1 FROM pg_proc p,
        LATERAL aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) a
        WHERE p.oid='public.read_account_deletion_storage_work_plan(uuid)'::regprocedure
          AND a.grantee<>p.proowner AND a.privilege_type='EXECUTE'
          AND NOT (v_service_enabled AND a.grantee='service_role'::regrole)),
        'work plan execution is limited to owner and explicitly enabled service role');
    RETURN NEXT is(has_function_privilege('service_role',
        'public.read_account_deletion_storage_work_plan(uuid)','EXECUTE'),v_service_enabled,
        'service execution requires the 064 migration marker');
    FOREACH v_role IN ARRAY ARRAY['anon','authenticated','service_role'] LOOP
        v_denied := false;
        BEGIN
            EXECUTE format('SET LOCAL ROLE %I',v_role);
            PERFORM public.read_account_deletion_storage_work_plan(v_owner);
        EXCEPTION WHEN insufficient_privilege THEN
            v_denied := true;
        END;
        RESET ROLE;
        RETURN NEXT is(v_denied,NOT (v_service_enabled AND v_role='service_role'),
            'actual work plan execution enforces migration scope for '||v_role);
    END LOOP;
END;
$$;
SELECT * FROM pg_temp.storage_work_plan_tests();

-- Resolve 065 references only after the gate for earlier migration selectors.
CREATE FUNCTION pg_temp.storage_verification_tests() RETURNS SETOF text LANGUAGE plpgsql AS $$
DECLARE
    v_owner uuid := 'a0650000-0000-4000-8000-000000000001';
    v_neighbor uuid := 'a0650000-0000-4000-8000-000000000002';
    v_operation uuid := pg_temp.owner_id(1599);
    v_photo uuid := pg_temp.owner_id(1500);
    v_receipt public.operation_receipts%ROWTYPE;
    v_stamp timestamptz;
    v_neighbor_stamp timestamptz;
    v_tid tid;
    v_before jsonb;
    v_case integer;
    v_role text;
    v_denied boolean;
BEGIN
    IF to_regprocedure('public.verify_account_deletion_storage_internal(uuid,uuid)') IS NULL THEN
        RETURN QUERY SELECT skip('065 verification is outside selected migration version',1);
        RETURN;
    END IF;
    RETURN NEXT ok(EXISTS (SELECT 1 FROM pg_attribute
        WHERE attrelid='public.account_deletion_requests'::regclass
          AND attname='storage_verified_at' AND atttypid='timestamptz'::regtype
          AND NOT attnotnull AND NOT attisdropped),
        'verification column is a nullable timestamp on the private request table');
    RETURN NEXT ok(NOT EXISTS (SELECT 1 FROM public.account_deletion_requests
        WHERE storage_verified_at IS NOT NULL),'preexisting requests start unverified');
    INSERT INTO auth.users(id,is_anonymous,created_at) VALUES
        (v_owner,false,clock_timestamp()),(v_neighbor,false,clock_timestamp());
    RETURN NEXT is(public.verify_account_deletion_storage_internal(v_owner,v_operation),
        NULL::timestamptz,'active owner without request cannot verify');
    UPDATE public.profiles SET account_state='deleting' WHERE id=v_owner;
    RETURN NEXT is(public.verify_account_deletion_storage_internal(v_owner,v_operation),
        NULL::timestamptz,'deleting flag without request cannot verify');
    UPDATE public.profiles SET account_state='active' WHERE id=v_owner;
    PERFORM public.request_account_deletion_internal(v_owner,v_operation);
    PERFORM public.request_account_deletion_internal(v_neighbor,pg_temp.owner_id(1598));
    v_neighbor_stamp := public.verify_account_deletion_storage_internal(v_neighbor,pg_temp.owner_id(1598));
    RETURN NEXT ok(v_neighbor_stamp IS NOT NULL,'authentic clean neighbor verifies independently');
    SELECT * INTO STRICT v_receipt FROM public.operation_receipts
    WHERE owner_id=v_owner AND operation_id=v_operation;

    INSERT INTO public.photo_assets(id,owner_id,purpose,original_key,content_hash)
    VALUES(v_photo,v_owner,'initial',v_owner::text||'/'||v_photo,repeat('a',64));
    INSERT INTO public.diagnosis_upload_tickets(photo_asset_id,mime_type,byte_size,expires_at)
    VALUES(v_photo,'image/jpeg',4,clock_timestamp()-interval '1 day');
    INSERT INTO storage.objects(bucket_id,name)
    VALUES('analysis-inputs',v_owner::text||'/'||v_photo);
    RETURN NEXT is(public.verify_account_deletion_storage_internal(v_owner,v_operation),
        NULL::timestamptz,'surviving canonical object leaves request pending');
    RETURN NEXT is(public.verify_account_deletion_storage_internal(v_owner,v_operation),
        NULL::timestamptz,'pending retry sees the same surviving object');
    DELETE FROM storage.objects WHERE bucket_id='analysis-inputs'
        AND name=v_owner::text||'/'||v_photo;
    v_stamp := public.verify_account_deletion_storage_internal(v_owner,v_operation);
    RETURN NEXT ok(v_stamp IS NOT NULL,'fresh clean plan persists verification');
    RETURN NEXT is((SELECT storage_verified_at FROM public.account_deletion_requests WHERE owner_id=v_owner),
        v_stamp,'returned timestamp is stored on the exact request');
    SELECT ctid INTO v_tid FROM public.account_deletion_requests WHERE owner_id=v_owner;
    RETURN NEXT is(public.verify_account_deletion_storage_internal(v_owner,v_operation),
        v_stamp,'clean exact retry returns the original timestamp');
    RETURN NEXT is((SELECT ctid FROM public.account_deletion_requests WHERE owner_id=v_owner),
        v_tid,'clean retry performs no request update');

    SELECT jsonb_agg(to_jsonb(q) ORDER BY owner_id) INTO v_before FROM public.account_deletion_requests q;
    RETURN NEXT is(public.verify_account_deletion_storage_internal(v_owner,pg_temp.owner_id(1597)),
        NULL::timestamptz,'wrong operation cannot verify or invalidate');
    RETURN NEXT is(public.verify_account_deletion_storage_internal(v_owner,NULL),
        NULL::timestamptz,'null operation cannot verify or invalidate');
    RETURN NEXT is(public.verify_account_deletion_storage_internal(NULL,v_operation),
        NULL::timestamptz,'null owner cannot verify');
    RETURN NEXT is(public.verify_account_deletion_storage_internal(pg_temp.owner_id(1596),v_operation),
        NULL::timestamptz,'absent owner cannot verify');
    RETURN NEXT is(public.verify_account_deletion_storage_internal(
        pg_temp.owner_id(902),pg_temp.owner_id(960)),NULL::timestamptz,
        'anonymous owner with a matching forged request and receipt cannot verify');
    RETURN NEXT is((SELECT jsonb_agg(to_jsonb(q) ORDER BY owner_id) FROM public.account_deletion_requests q),
        v_before,'invalid input preserves every request');

    FOR v_case IN 1..6 LOOP
        BEGIN
            IF v_case=1 THEN
                UPDATE public.profiles SET account_state='active' WHERE id=v_owner;
            ELSIF v_case=2 THEN
                DELETE FROM public.operation_receipts WHERE owner_id=v_owner AND operation_id=v_operation;
            ELSE
                UPDATE public.operation_receipts SET
                    command_name=CASE WHEN v_case=3 THEN 'forged' ELSE v_receipt.command_name END,
                    payload_hash=CASE WHEN v_case=4 THEN 'forged' ELSE v_receipt.payload_hash END,
                    committed_at=CASE WHEN v_case=5 THEN v_receipt.committed_at+interval '1 second'
                        ELSE v_receipt.committed_at END,
                    response_payload=CASE WHEN v_case=6 THEN v_receipt.response_payload||'{"extra":true}'::jsonb
                        ELSE v_receipt.response_payload END
                WHERE owner_id=v_owner AND operation_id=v_operation;
            END IF;
            RETURN NEXT is(public.verify_account_deletion_storage_internal(v_owner,v_operation),
                NULL::timestamptz,'invalid owner or receipt is rejected, case '||v_case);
            RETURN NEXT is((SELECT jsonb_agg(to_jsonb(q) ORDER BY owner_id)
                FROM public.account_deletion_requests q),v_before,
                'invalid owner or receipt preserves requests, case '||v_case);
            RAISE SQLSTATE 'Z0065';
        EXCEPTION WHEN SQLSTATE 'Z0065' THEN NULL;
        END;
    END LOOP;

    -- Every hold is introduced against the same authentic, verified request.
    FOR v_case IN 1..9 LOOP
        BEGIN
            IF v_case=1 THEN
                INSERT INTO storage.objects(bucket_id,name)
                VALUES('analysis-inputs',v_owner::text||'/'||v_photo);
            ELSIF v_case=2 THEN
                INSERT INTO storage.objects(bucket_id,name)
                VALUES('analysis-inputs',v_owner::text||'/orphan');
            ELSIF v_case=3 THEN
                UPDATE public.diagnosis_upload_tickets SET expires_at=clock_timestamp()+interval '1 day'
                WHERE photo_asset_id=v_photo;
            ELSIF v_case=4 THEN
                UPDATE public.photo_assets SET analysis_key='unsafe/thumbnail' WHERE id=v_photo;
            ELSIF v_case=5 THEN
                INSERT INTO public.guest_drafts(id,guest_owner_id,flow_id,intent,add_method,source_storage_key)
                VALUES(pg_temp.owner_id(1540),v_owner,pg_temp.owner_id(1541),'care','scan','legacy/source');
            ELSIF v_case=6 THEN
                INSERT INTO public.guest_identification_sources(photo_id,succeeded_at,expires_at)
                VALUES(v_photo,clock_timestamp()-interval '2 days',clock_timestamp()-interval '1 day');
            ELSIF v_case=7 THEN
                INSERT INTO public.guest_drafts(id,guest_owner_id,flow_id,intent,add_method,source_storage_key)
                VALUES(pg_temp.owner_id(1550),v_neighbor,pg_temp.owner_id(1551),'care','scan','legacy/incoming');
                INSERT INTO public.draft_claims(draft_id,proof_hash,target_owner_id,operation_id,state,expires_at)
                VALUES(pg_temp.owner_id(1550),'verification',v_owner,pg_temp.owner_id(1552),
                    'copying',clock_timestamp()-interval '1 day');
            ELSIF v_case=8 THEN
                UPDATE storage.buckets SET public=true WHERE id='analysis-inputs';
            ELSE
                DELETE FROM storage.objects WHERE bucket_id='analysis-inputs';
                DELETE FROM storage.buckets WHERE id='analysis-inputs';
            END IF;
            RETURN NEXT is(public.verify_account_deletion_storage_internal(v_owner,v_operation),
                NULL::timestamptz,'fresh failure invalidates verification, case '||v_case);
            RETURN NEXT is((SELECT storage_verified_at FROM public.account_deletion_requests WHERE owner_id=v_owner),
                NULL::timestamptz,'stale timestamp is cleared, case '||v_case);
            SELECT ctid INTO v_tid FROM public.account_deletion_requests WHERE owner_id=v_owner;
            RETURN NEXT is(public.verify_account_deletion_storage_internal(v_owner,v_operation),
                NULL::timestamptz,'repeated failure stays unverified, case '||v_case);
            RETURN NEXT is((SELECT ctid FROM public.account_deletion_requests WHERE owner_id=v_owner),
                v_tid,'repeated failure avoids redundant update, case '||v_case);
            RETURN NEXT is((SELECT storage_verified_at FROM public.account_deletion_requests WHERE owner_id=v_neighbor),
                v_neighbor_stamp,'invalidation preserves neighbor, case '||v_case);
            -- Restore fixture mutations, including other owners objects in the missing-bucket case.
            RAISE SQLSTATE 'Z0065';
        EXCEPTION WHEN SQLSTATE 'Z0065' THEN NULL;
        END;
        RETURN NEXT is(public.verify_account_deletion_storage_internal(v_owner,v_operation),
            v_stamp,'clean exact retry rechecks readiness after fixture rollback, case '||v_case);
    END LOOP;

    -- A real invalidation followed by cleanup must create fresh evidence.
    UPDATE public.account_deletion_requests SET storage_verified_at='2000-01-01 UTC' WHERE owner_id=v_owner;
    INSERT INTO storage.objects(bucket_id,name) VALUES('analysis-inputs',v_owner::text||'/'||v_photo);
    RETURN NEXT is(public.verify_account_deletion_storage_internal(v_owner,v_operation),
        NULL::timestamptz,'reappearing object clears previously stored evidence');
    DELETE FROM storage.objects WHERE bucket_id='analysis-inputs' AND name=v_owner::text||'/'||v_photo;
    v_stamp := public.verify_account_deletion_storage_internal(v_owner,v_operation);
    RETURN NEXT ok(v_stamp>'2000-01-01 UTC'::timestamptz,'cleanup produces a fresh verification timestamp');
    RETURN NEXT is(public.verify_account_deletion_storage_internal(v_owner,v_operation),
        v_stamp,'fresh verification is stable on exact retry');
    RETURN NEXT is((SELECT account_state FROM public.profiles WHERE id=v_owner),'deleting',
        'verification leaves DB and Auth finalization pending');
    RETURN NEXT ok(EXISTS (SELECT 1 FROM auth.users WHERE id=v_owner)
        AND EXISTS (SELECT 1 FROM public.photo_assets WHERE id=v_photo),
        'verification preserves Auth and application data');
    RETURN NEXT ok(EXISTS (SELECT 1 FROM pg_proc
        WHERE oid='public.verify_account_deletion_storage_internal(uuid,uuid)'::regprocedure
          AND prosecdef AND provolatile='v' AND proconfig @> ARRAY['search_path=""']),
        'internal verifier is definer with fresh snapshots and empty search path');
    RETURN NEXT ok(NOT EXISTS (SELECT 1 FROM pg_proc p,
        LATERAL aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) a
        WHERE p.oid='public.verify_account_deletion_storage_internal(uuid,uuid)'::regprocedure
          AND a.grantee<>p.proowner),'verifier strips PUBLIC and all nonowner default grants');
    FOREACH v_role IN ARRAY ARRAY['anon','authenticated','service_role'] LOOP
        v_denied := false;
        BEGIN
            EXECUTE format('SET LOCAL ROLE %I',v_role);
            PERFORM public.verify_account_deletion_storage_internal(v_owner,v_operation);
        EXCEPTION WHEN insufficient_privilege THEN
            v_denied := true;
        END;
        RESET ROLE;
        RETURN NEXT ok(v_denied,'actual verifier execution denied for '||v_role);
        RETURN NEXT ok(NOT has_table_privilege(v_role,'public.account_deletion_requests',
            'SELECT,INSERT,UPDATE,DELETE'),'request table remains private for '||v_role);
    END LOOP;
END;
$$;
SELECT * FROM pg_temp.storage_verification_tests();

-- Resolve 066 only after the gate so earlier migration fixtures still run.
CREATE FUNCTION pg_temp.care_leaf_snapshot(p_owner uuid DEFAULT NULL) RETURNS jsonb LANGUAGE sql AS $$
    SELECT jsonb_build_object(
        'recovery_transitions',(SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY id),'[]'::jsonb)
            FROM public.recovery_transitions r WHERE p_owner IS NULL OR owner_id=p_owner),
        'care_reversals',(SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY id),'[]'::jsonb)
            FROM public.care_reversals r WHERE p_owner IS NULL OR owner_id=p_owner),
        'schedule_changes',(SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY id),'[]'::jsonb)
            FROM public.schedule_changes r WHERE p_owner IS NULL OR owner_id=p_owner),
        'notification_claims',(SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY id),'[]'::jsonb)
            FROM public.notification_claims r WHERE p_owner IS NULL OR owner_id=p_owner))
$$;

CREATE FUNCTION pg_temp.care_leaf_retained_snapshot() RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_table text;
    v_rows jsonb;
    v_result jsonb := pg_temp.deletion_history();
BEGIN
    FOREACH v_table IN ARRAY ARRAY['profiles','condition_snapshots','care_observations',
        'task_rules','first_aid_followups','basic_care_memberships','operation_receipts',
        'account_deletion_requests'] LOOP
        EXECUTE format('SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY to_jsonb(r)::text),
            ''[]''::jsonb) FROM public.%I r',v_table) INTO v_rows;
        v_result := v_result || jsonb_build_object(v_table,v_rows);
    END LOOP;
    RETURN v_result || jsonb_build_object('auth_users',
        (SELECT jsonb_agg(to_jsonb(u) ORDER BY id) FROM auth.users u));
END;
$$;

CREATE FUNCTION pg_temp.reject_care_leaf_purge() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'FIXTURE_LEAF_PURGE_FAILURE' USING ERRCODE='Z0066';
END;
$$;

CREATE FUNCTION pg_temp.care_leaf_purge_tests() RETURNS SETOF text LANGUAGE plpgsql AS $$
DECLARE
    v_owner uuid := 'a0660000-0000-4000-8000-000000000001';
    v_neighbor uuid := 'a0660000-0000-4000-8000-000000000002';
    v_guest uuid := 'a0660000-0000-4000-8000-000000000003';
    v_operation uuid := pg_temp.owner_id(1699);
    v_subject uuid;
    v_plant uuid;
    v_snapshot uuid;
    v_plan uuid;
    v_observation uuid;
    v_entry uuid;
    v_release uuid;
    v_installation uuid;
    v_deleted timestamptz;
    v_leaves jsonb;
    v_neighbor_leaves jsonb;
    v_guest_leaves jsonb;
    v_retained jsonb;
    v_n integer;
    v_role text;
    v_denied boolean;
BEGIN
    IF to_regprocedure('public.purge_account_deletion_care_leaves_internal(uuid,uuid)') IS NULL THEN
        RETURN QUERY SELECT skip('066 leaf purge is outside selected migration version',1);
        RETURN;
    END IF;
    INSERT INTO auth.users(id,is_anonymous,created_at) VALUES
        (v_owner,false,clock_timestamp()),(v_neighbor,false,clock_timestamp()),
        (v_guest,true,clock_timestamp());
    INSERT INTO public.kb_releases(version,state) VALUES('t083-leaf-purge-066','draft')
        RETURNING id INTO v_release;
    FOREACH v_subject IN ARRAY ARRAY[v_owner,v_neighbor,v_guest] LOOP
        INSERT INTO public.installation_access(credential_hash,linked_owner_ids)
        VALUES(encode(sha256(convert_to(v_subject::text,'UTF8')),'hex'),ARRAY[v_subject])
            RETURNING id INTO v_installation;
        INSERT INTO public.plants(owner_id,personal_name,creation_source)
        VALUES(v_subject,'Leaf purge fixture','identification') RETURNING id INTO v_plant;
        INSERT INTO public.condition_snapshots(owner_id,plant_id)
        VALUES(v_subject,v_plant) RETURNING id INTO v_snapshot;
        INSERT INTO public.care_plans(owner_id,plant_id,operation_id,locale,plan_kind,
            access_tier,source_kind,snapshot_id,kb_release_id,context_revision,full_body)
        VALUES(v_subject,v_plant,gen_random_uuid(),'en','recovery','full','analysis',
            v_snapshot,v_release,1,'{}') RETURNING id INTO v_plan;
        FOR v_n IN 1..2 LOOP
            v_deleted := CASE WHEN v_n=2 THEN clock_timestamp() ELSE NULL END;
            INSERT INTO public.care_observations(owner_id,plant_id,status_code,operation_id)
            VALUES(v_subject,v_plant,'improved',gen_random_uuid()) RETURNING id INTO v_observation;
            INSERT INTO public.care_entries(owner_id,plant_id,action_code,occurred_at,
                occurred_local_date,timezone,operation_id)
            VALUES(v_subject,v_plant,'water',clock_timestamp(),current_date,'UTC',gen_random_uuid())
                RETURNING id INTO v_entry;
            INSERT INTO public.recovery_transitions(owner_id,plant_id,recovery_plan_id,
                observation_id,expected_care_revision,operation_id,state,deleted_at)
            VALUES(v_subject,v_plant,v_plan,v_observation,1,gen_random_uuid(),'confirmed',v_deleted);
            INSERT INTO public.care_reversals(owner_id,entry_id,operation_id,deleted_at)
            VALUES(v_subject,v_entry,gen_random_uuid(),v_deleted);
            INSERT INTO public.schedule_changes(owner_id,plant_id,to_date,cause_code,explanation_code,deleted_at)
            VALUES(v_subject,v_plant,current_date,'fixture','fixture',v_deleted);
            INSERT INTO public.notification_claims(owner_id,kind,period_key,installation_id,scheduled_at,deleted_at)
            VALUES(v_subject,'trial_end','leaf-'||v_n,v_installation,clock_timestamp(),v_deleted);
        END LOOP;
    END LOOP;
    v_leaves := pg_temp.care_leaf_snapshot();
    RETURN NEXT is(public.purge_account_deletion_care_leaves_internal(v_owner,v_operation),false,
        'active permanent owner cannot purge');
    RETURN NEXT is(public.purge_account_deletion_care_leaves_internal(v_guest,v_operation),false,
        'distinct anonymous owner cannot purge');
    PERFORM public.request_account_deletion_internal(v_owner,v_operation);
    -- A forged matching request/receipt cannot authorize the anonymous fixture.
    UPDATE public.profiles SET account_state='deleting' WHERE id=v_guest;
    INSERT INTO public.account_deletion_requests(owner_id,operation_id,requested_at)
        SELECT v_guest,operation_id,requested_at FROM public.account_deletion_requests WHERE owner_id=v_owner;
    INSERT INTO public.operation_receipts(owner_id,operation_id,command_name,payload_hash,response_payload,committed_at)
        SELECT v_guest,operation_id,command_name,payload_hash,
            response_payload||jsonb_build_object('owner_id',v_guest),committed_at
        FROM public.operation_receipts WHERE owner_id=v_owner AND operation_id=v_operation;
    RETURN NEXT is(public.purge_account_deletion_care_leaves_internal(v_guest,v_operation),false,
        'anonymous owner with matching forged receipt remains ineligible');
    RETURN NEXT is(public.purge_account_deletion_care_leaves_internal(v_owner,pg_temp.owner_id(1698)),false,
        'wrong operation cannot purge');
    RETURN NEXT is(public.purge_account_deletion_care_leaves_internal(NULL,v_operation),false,
        'null owner cannot purge');
    RETURN NEXT is(public.purge_account_deletion_care_leaves_internal(v_owner,NULL),false,
        'null operation cannot purge');
    RETURN NEXT is(pg_temp.care_leaf_snapshot(),v_leaves,'invalid callers preserve all leaf rows');

    INSERT INTO storage.objects(bucket_id,name) VALUES('analysis-inputs',v_owner::text||'/orphan');
    RETURN NEXT is(public.purge_account_deletion_care_leaves_internal(v_owner,v_operation),false,
        'fresh Storage hold blocks purge');
    RETURN NEXT is(pg_temp.care_leaf_snapshot(),v_leaves,'failed verification deletes no rows');
    DELETE FROM storage.objects WHERE bucket_id='analysis-inputs' AND name=v_owner::text||'/orphan';
    RETURN NEXT ok(public.verify_account_deletion_storage_internal(v_owner,v_operation) IS NOT NULL,
        'clean owner has saved verification');
    INSERT INTO storage.objects(bucket_id,name) VALUES('analysis-inputs',v_owner::text||'/orphan');
    RETURN NEXT is(public.purge_account_deletion_care_leaves_internal(v_owner,v_operation),false,
        'reappearing object blocks purge despite saved verification');
    RETURN NEXT is((SELECT storage_verified_at FROM public.account_deletion_requests WHERE owner_id=v_owner),
        NULL::timestamptz,'fresh failure invalidates saved verification');
    RETURN NEXT is(pg_temp.care_leaf_snapshot(),v_leaves,'reappearing object preserves all leaves');
    DELETE FROM storage.objects WHERE bucket_id='analysis-inputs' AND name=v_owner::text||'/orphan';

    -- Failure on the last table must undo earlier deletes and the new verification.
    v_retained := pg_temp.care_leaf_retained_snapshot();
    CREATE TRIGGER t066_reject_leaf BEFORE DELETE ON public.notification_claims
        FOR EACH ROW EXECUTE FUNCTION pg_temp.reject_care_leaf_purge();
    RETURN NEXT throws_ok(format('SELECT public.purge_account_deletion_care_leaves_internal(%L::uuid,%L::uuid)',
        v_owner,v_operation),'Z0066','FIXTURE_LEAF_PURGE_FAILURE','last-table failure propagates');
    DROP TRIGGER t066_reject_leaf ON public.notification_claims;
    RETURN NEXT is(pg_temp.care_leaf_snapshot(),v_leaves,'failure rolls back every earlier leaf deletion');
    RETURN NEXT is(pg_temp.care_leaf_retained_snapshot(),v_retained,'failure rolls back verification too');

    PERFORM public.verify_account_deletion_storage_internal(v_owner,v_operation);
    v_retained := pg_temp.care_leaf_retained_snapshot();
    v_neighbor_leaves := pg_temp.care_leaf_snapshot(v_neighbor);
    v_guest_leaves := pg_temp.care_leaf_snapshot(v_guest);
    RETURN NEXT is(public.purge_account_deletion_care_leaves_internal(v_owner,v_operation),true,
        'verified owner purges successfully');
    RETURN NEXT is(pg_temp.care_leaf_snapshot(v_owner),
        '{"recovery_transitions":[],"care_reversals":[],"schedule_changes":[],"notification_claims":[]}'::jsonb,
        'all four owner leaf sets are empty including live and tombstoned rows');
    RETURN NEXT is(pg_temp.care_leaf_snapshot(v_neighbor),v_neighbor_leaves,'neighbor leaves are unchanged');
    RETURN NEXT is(pg_temp.care_leaf_snapshot(v_guest),v_guest_leaves,'guest leaves are unchanged');
    RETURN NEXT is(pg_temp.care_leaf_retained_snapshot(),v_retained,
        'parents, observations, profiles, Auth, requests, receipts, quotas and payments are unchanged');
    RETURN NEXT is(public.purge_account_deletion_care_leaves_internal(v_owner,v_operation),true,
        'exact successful replay is harmless');
    RETURN NEXT is(pg_temp.care_leaf_retained_snapshot(),v_retained,'replay preserves retained rows');
    RETURN NEXT ok(EXISTS (SELECT 1 FROM pg_proc
        WHERE oid='public.purge_account_deletion_care_leaves_internal(uuid,uuid)'::regprocedure
          AND prosecdef AND provolatile='v' AND proconfig @> ARRAY['search_path=""']),
        'purge is volatile SECURITY DEFINER with empty search path');
    RETURN NEXT ok(NOT EXISTS (SELECT 1 FROM pg_proc p,
        LATERAL aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) a
        WHERE p.oid='public.purge_account_deletion_care_leaves_internal(uuid,uuid)'::regprocedure
          AND a.grantee<>p.proowner),'all nonowner default ACL grants are stripped');
    FOREACH v_role IN ARRAY ARRAY['anon','authenticated','service_role'] LOOP
        v_denied := false;
        BEGIN
            EXECUTE format('SET LOCAL ROLE %I',v_role);
            PERFORM public.purge_account_deletion_care_leaves_internal(v_owner,v_operation);
        EXCEPTION WHEN insufficient_privilege THEN
            v_denied := true;
        END;
        RESET ROLE;
        RETURN NEXT ok(v_denied,'actual purge execution denied for '||v_role);
    END LOOP;
    SELECT pg_get_userbyid(proowner) INTO v_role FROM pg_proc
        WHERE oid='public.purge_account_deletion_care_leaves_internal(uuid,uuid)'::regprocedure;
    EXECUTE format('SET LOCAL ROLE %I',v_role);
    RETURN NEXT is(public.purge_account_deletion_care_leaves_internal(v_owner,v_operation),true,
        'actual SQL owner can execute exact replay');
    RESET ROLE;
END;
$$;
SELECT * FROM pg_temp.care_leaf_purge_tests();

-- Keep function resolution behind the version gate for clean/upgrade selectors.
CREATE FUNCTION pg_temp.care_journal_snapshot() RETURNS jsonb LANGUAGE sql AS $$
    SELECT pg_temp.care_leaf_retained_snapshot() || pg_temp.care_leaf_snapshot()
$$;

CREATE FUNCTION pg_temp.care_journal_purge_tests() RETURNS SETOF text LANGUAGE plpgsql AS $$
DECLARE
    v_owner uuid := 'a0670000-0000-4000-8000-000000000001';
    v_neighbor uuid := 'a0670000-0000-4000-8000-000000000002';
    v_operation uuid := pg_temp.owner_id(1799);
    v_subject uuid;
    v_release uuid;
    v_plant uuid;
    v_snapshot uuid;
    v_plan uuid;
    v_task uuid;
    v_entry uuid;
    v_extra_entry uuid;
    v_observation uuid;
    v_before jsonb;
    v_retained jsonb;
    v_followups jsonb;
    v_edge record;
    v_target uuid;
    v_role text;
    v_denied boolean;
BEGIN
    IF to_regprocedure('public.purge_account_deletion_care_journal_internal(uuid,uuid)') IS NULL THEN
        RETURN QUERY SELECT skip('067 journal purge is outside selected migration version',1);
        RETURN;
    END IF;
    INSERT INTO auth.users(id,is_anonymous,created_at) VALUES
        (v_owner,false,clock_timestamp()),(v_neighbor,false,clock_timestamp());
    INSERT INTO public.kb_releases(version,state) VALUES('t083-journal-067','draft')
        RETURNING id INTO v_release;
    FOREACH v_subject IN ARRAY ARRAY[v_owner,v_neighbor] LOOP
        INSERT INTO public.plants(owner_id,personal_name,creation_source)
        VALUES(v_subject,'Journal fixture','identification') RETURNING id INTO v_plant;
        INSERT INTO public.condition_snapshots(owner_id,plant_id)
        VALUES(v_subject,v_plant) RETURNING id INTO v_snapshot;
        INSERT INTO public.care_plans(owner_id,plant_id,operation_id,locale,plan_kind,
            access_tier,source_kind,snapshot_id,kb_release_id,context_revision,full_body)
        VALUES(v_subject,v_plant,gen_random_uuid(),'en','recovery','full','analysis',
            v_snapshot,v_release,1,'{}') RETURNING id INTO v_plan;
        INSERT INTO public.care_tasks(owner_id,plant_id,occurrence_key,action_code,due_local_date)
        VALUES(v_subject,v_plant,'journal','water',current_date) RETURNING id INTO v_task;
        INSERT INTO public.care_entries(owner_id,plant_id,task_id,action_code,occurred_at,
            occurred_local_date,timezone,operation_id)
        VALUES(v_subject,v_plant,v_task,'water',clock_timestamp(),current_date,'UTC',gen_random_uuid())
            RETURNING id INTO v_entry;
        UPDATE public.care_tasks SET completed_entry_id=v_entry WHERE id=v_task;
        INSERT INTO public.care_entries(owner_id,plant_id,action_code,occurred_at,
            occurred_local_date,timezone,operation_id,deleted_at)
        VALUES(v_subject,v_plant,'water',clock_timestamp(),current_date,'UTC',gen_random_uuid(),
            clock_timestamp()) RETURNING id INTO v_extra_entry;
        INSERT INTO public.care_reversals(owner_id,entry_id,operation_id)
        VALUES(v_subject,v_extra_entry,gen_random_uuid());
        INSERT INTO public.first_aid_followups(owner_id,plant_id,origin_analysis_id,
            kb_release_id,action_code,first_action_snapshot,action_entry_id,control_task_id)
        VALUES(v_subject,v_plant,gen_random_uuid(),v_release,'water','{}',v_entry,v_task);
        INSERT INTO public.care_observations(owner_id,plant_id,task_id,status_code,operation_id)
        VALUES(v_subject,v_plant,v_task,'improved',gen_random_uuid()) RETURNING id INTO v_observation;
        INSERT INTO public.recovery_transitions(owner_id,plant_id,recovery_plan_id,
            observation_id,expected_care_revision,operation_id,state)
        VALUES(v_subject,v_plant,v_plan,v_observation,1,gen_random_uuid(),'confirmed');
        INSERT INTO public.schedule_changes(owner_id,plant_id,to_date,cause_code,explanation_code)
        VALUES(v_subject,v_plant,current_date,'fixture','fixture');
    END LOOP;

    v_before := pg_temp.care_journal_snapshot();
    RETURN NEXT is(public.purge_account_deletion_care_journal_internal(v_owner,v_operation),false,
        'journal requires deleting permanent owner');
    RETURN NEXT is(pg_temp.care_journal_snapshot(),v_before,'active graph retained exactly');
    PERFORM public.request_account_deletion_internal(v_owner,v_operation);
    v_before := pg_temp.care_journal_snapshot();
    RETURN NEXT is(public.purge_account_deletion_care_journal_internal(v_owner,gen_random_uuid()),false,
        'journal requires exact request operation');
    RETURN NEXT is(public.purge_account_deletion_care_journal_internal(NULL,v_operation),false,
        'null owner is rejected');
    RETURN NEXT is(public.purge_account_deletion_care_journal_internal(v_owner,NULL),false,
        'null operation is rejected');
    RETURN NEXT is(pg_temp.care_journal_snapshot(),v_before,'invalid identity retains exact graph');
    BEGIN
        UPDATE public.operation_receipts SET payload_hash='forged'
        WHERE owner_id=v_owner AND operation_id=v_operation;
        v_before := pg_temp.care_journal_snapshot();
        RETURN NEXT is(public.purge_account_deletion_care_journal_internal(v_owner,v_operation),false,
            'journal revalidates exact account.delete receipt');
        RETURN NEXT is(pg_temp.care_journal_snapshot(),v_before,'bad receipt retains exact graph');
        RAISE SQLSTATE 'Z0067';
    EXCEPTION WHEN SQLSTATE 'Z0067' THEN NULL;
    END;

    -- Each current incoming FK is exercised independently, including tombstones.
    -- Subtransactions restore the canonical graph after each malformed case.
    FOR v_edge IN SELECT * FROM (VALUES
        ('care_tasks','completed_entry_id','care_entries'),
        ('care_entries','task_id','care_tasks'),
        ('care_observations','task_id','care_tasks'),
        ('first_aid_followups','action_entry_id','care_entries'),
        ('first_aid_followups','control_task_id','care_tasks'),
        ('care_reversals','entry_id','care_entries'),
        ('recovery_transitions','observation_id','care_observations')
    ) AS edges(child_table,child_column,parent_table) LOOP
        BEGIN
            EXECUTE format('SELECT id FROM public.%I WHERE owner_id=$1 ORDER BY id LIMIT 1',
                v_edge.parent_table) INTO v_target USING v_owner;
            -- Use the task's entry, which has no existing unique reversal.
            IF v_edge.parent_table='care_entries' THEN
                SELECT completed_entry_id INTO v_target FROM public.care_tasks WHERE owner_id=v_owner;
            END IF;
            IF v_edge.child_table='care_entries' THEN
                UPDATE public.care_entries SET state='voided' WHERE owner_id=v_neighbor;
            END IF;
            EXECUTE format('UPDATE public.%I SET %I=$1,deleted_at=clock_timestamp() WHERE owner_id=$2',
                v_edge.child_table,v_edge.child_column) USING v_target,v_neighbor;
            v_before := pg_temp.care_journal_snapshot();
            RETURN NEXT is(public.purge_account_deletion_care_journal_internal(v_owner,v_operation),false,
                'foreign historical FK holds journal '||v_edge.child_table||'.'||v_edge.child_column);
            RETURN NEXT is(pg_temp.care_journal_snapshot(),v_before,
                'hold retains every row and verification before 066 '||v_edge.child_column);
            PERFORM public.verify_account_deletion_storage_internal(v_owner,v_operation);
            v_before := pg_temp.care_journal_snapshot();
            RETURN NEXT is(public.purge_account_deletion_care_journal_internal(v_owner,v_operation),false,
                'saved verification cannot bypass foreign FK '||v_edge.child_column);
            RETURN NEXT is(pg_temp.care_journal_snapshot(),v_before,
                'foreign FK hold preserves saved evidence and graph '||v_edge.child_column);
            RAISE SQLSTATE 'Z0067';
        EXCEPTION WHEN SQLSTATE 'Z0067' THEN NULL;
        END;
    END LOOP;

    -- A late journal failure must roll back 066 and newly recorded verification.
    v_before := pg_temp.care_journal_snapshot();
    CREATE TRIGGER t067_reject_journal BEFORE DELETE ON public.care_tasks
        FOR EACH ROW EXECUTE FUNCTION pg_temp.reject_care_leaf_purge();
    RETURN NEXT throws_ok(format('SELECT public.purge_account_deletion_care_journal_internal(%L::uuid,%L::uuid)',
        v_owner,v_operation),'Z0066','FIXTURE_LEAF_PURGE_FAILURE','journal failure propagates');
    DROP TRIGGER t067_reject_journal ON public.care_tasks;
    RETURN NEXT is(pg_temp.care_journal_snapshot(),v_before,
        'late error atomically restores leaves, journal, FK nulls and verification');

    PERFORM public.verify_account_deletion_storage_internal(v_owner,v_operation);
    v_before := pg_temp.care_journal_snapshot();
    INSERT INTO storage.objects(bucket_id,name) VALUES('analysis-inputs',v_owner::text||'/journal-orphan');
    RETURN NEXT is(public.purge_account_deletion_care_journal_internal(v_owner,v_operation),false,
        'saved verification cannot bypass reappearing Storage object');
    RETURN NEXT is(pg_temp.care_journal_snapshot()-'account_deletion_requests',
        v_before-'account_deletion_requests','Storage hold retains the entire data graph');
    RETURN NEXT is((SELECT storage_verified_at FROM public.account_deletion_requests WHERE owner_id=v_owner),
        NULL::timestamptz,'stale Storage evidence is invalidated');
    DELETE FROM storage.objects WHERE bucket_id='analysis-inputs' AND name=v_owner::text||'/journal-orphan';
    PERFORM public.verify_account_deletion_storage_internal(v_owner,v_operation);
    v_before := pg_temp.care_journal_snapshot();
    v_retained := v_before - ARRAY['care_entries','care_tasks','care_observations',
        'first_aid_followups','recovery_transitions','care_reversals','schedule_changes','notification_claims'];
    SELECT jsonb_agg(CASE WHEN owner_id=v_owner THEN to_jsonb(f) ||
        jsonb_build_object('action_entry_id',NULL,'control_task_id',NULL) ELSE to_jsonb(f) END ORDER BY id)
        INTO v_followups FROM public.first_aid_followups f;
    RETURN NEXT is(public.purge_account_deletion_care_journal_internal(v_owner,v_operation),true,
        'verified canonical journal is removed');
    RETURN NEXT is((SELECT count(*) FROM (
        SELECT id FROM public.care_entries WHERE owner_id=v_owner
        UNION ALL SELECT id FROM public.care_tasks WHERE owner_id=v_owner
        UNION ALL SELECT id FROM public.care_observations WHERE owner_id=v_owner) remaining),
        0::bigint,'all owner facts, tasks and observations including tombstones are gone');
    RETURN NEXT is(pg_temp.care_journal_snapshot() - ARRAY['care_entries','care_tasks','care_observations',
        'first_aid_followups','recovery_transitions','care_reversals','schedule_changes','notification_claims'],
        v_retained,'all other parent, profile, Auth, request, receipt, photo and financial data retained');
    RETURN NEXT is((SELECT jsonb_agg(to_jsonb(f) ORDER BY id) FROM public.first_aid_followups f),
        v_followups,'only schema-defined same-owner followup fields are nulled');
    FOREACH v_role IN ARRAY ARRAY['care_entries','care_tasks','care_observations',
        'recovery_transitions','care_reversals','schedule_changes','notification_claims'] LOOP
        EXECUTE format('SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY id),''[]''::jsonb)
            FROM public.%I r WHERE owner_id<>$1',v_role) INTO v_retained USING v_owner;
        RETURN NEXT is(v_retained,(SELECT coalesce(jsonb_agg(e ORDER BY e->>'id'),'[]'::jsonb)
            FROM jsonb_array_elements(v_before->v_role) e WHERE e->>'owner_id'<>v_owner::text),
            'neighbors retained exactly in '||v_role);
    END LOOP;
    v_before := pg_temp.care_journal_snapshot();
    RETURN NEXT is(public.purge_account_deletion_care_journal_internal(v_owner,v_operation),true,
        'exact second invocation is harmless');
    RETURN NEXT is(pg_temp.care_journal_snapshot(),v_before,'exact replay changes no row');
    INSERT INTO storage.objects(bucket_id,name) VALUES('analysis-inputs',v_owner::text||'/journal-replay');
    RETURN NEXT is(public.purge_account_deletion_care_journal_internal(v_owner,v_operation),false,
        'successful replay still requires fresh Storage verification');
    DELETE FROM storage.objects WHERE bucket_id='analysis-inputs' AND name=v_owner::text||'/journal-replay';

    RETURN NEXT ok(EXISTS (SELECT 1 FROM pg_proc
        WHERE oid='public.purge_account_deletion_care_journal_internal(uuid,uuid)'::regprocedure
          AND prosecdef AND provolatile='v' AND proconfig @> ARRAY['search_path=""']),
        'journal function is volatile SECURITY DEFINER with empty search path');
    RETURN NEXT ok(NOT EXISTS (SELECT 1 FROM pg_proc p,
        LATERAL aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) a
        WHERE p.oid='public.purge_account_deletion_care_journal_internal(uuid,uuid)'::regprocedure
          AND a.grantee<>p.proowner),'journal strips every nonowner grant');
    FOREACH v_role IN ARRAY ARRAY['anon','authenticated','service_role'] LOOP
        v_denied := false;
        BEGIN
            EXECUTE format('SET LOCAL ROLE %I',v_role);
            PERFORM public.purge_account_deletion_care_journal_internal(v_owner,v_operation);
        EXCEPTION WHEN insufficient_privilege THEN v_denied := true;
        END;
        RESET ROLE;
        RETURN NEXT ok(v_denied,'actual journal execution denied for '||v_role);
    END LOOP;
    SELECT pg_get_userbyid(proowner) INTO v_role FROM pg_proc
        WHERE oid='public.purge_account_deletion_care_journal_internal(uuid,uuid)'::regprocedure;
    EXECUTE format('SET LOCAL ROLE %I',v_role);
    RETURN NEXT is(public.purge_account_deletion_care_journal_internal(v_owner,v_operation),true,
        'SQL function owner can execute journal replay');
    RESET ROLE;
END;
$$;
SELECT * FROM pg_temp.care_journal_purge_tests();

-- Plan phase is gated so the same fixture supports prior-migration upgrades.
CREATE FUNCTION pg_temp.care_plan_snapshot() RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_result jsonb := pg_temp.care_journal_snapshot();
    v_table text;
    v_rows jsonb;
BEGIN
    FOREACH v_table IN ARRAY ARRAY['diagnostic_decisions','diagnostic_answers','diagnosis_upload_tickets'] LOOP
        EXECUTE format('SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY to_jsonb(r)::text),
            ''[]''::jsonb) FROM public.%I r',v_table) INTO v_rows;
        v_result := v_result || jsonb_build_object(v_table,v_rows);
    END LOOP;
    RETURN v_result || jsonb_build_object('storage_objects',
        (SELECT coalesce(jsonb_agg(to_jsonb(s) ORDER BY to_jsonb(s)::text),'[]'::jsonb)
         FROM storage.objects s));
END;
$$;

-- Reuse the canonical two-owner plan graphs; every diagnostic test rolls back
-- before the existing 004 acceptance continues, on clean and upgraded schemas.
CREATE FUNCTION pg_temp.diagnostic_purge_tests(v_owner uuid,v_neighbor uuid)
RETURNS SETOF text LANGUAGE plpgsql AS $$
DECLARE
    v_operation uuid;
    v_neighbor_operation uuid;
    v_decision uuid;
    v_foreign_decision uuid;
    v_answer uuid;
    v_foreign_answer uuid;
    v_photo uuid;
    v_before jsonb;
    v_expected jsonb;
    v_rows jsonb;
    v_table text;
    v_role text;
    v_case integer;
    v_denied boolean;
BEGIN
    IF to_regprocedure('public.purge_account_deletion_diagnostic_decisions_internal(uuid,uuid)') IS NULL THEN
        RETURN QUERY SELECT skip('010 diagnostic purge is outside selected migration version',1);
        RETURN;
    END IF;
    SELECT operation_id INTO v_operation FROM public.account_deletion_requests WHERE owner_id=v_owner;
    SELECT operation_id INTO v_neighbor_operation FROM public.account_deletion_requests WHERE owner_id=v_neighbor;
    SELECT id INTO v_decision FROM public.diagnostic_decisions WHERE owner_id=v_owner LIMIT 1;
    SELECT id INTO v_foreign_decision FROM public.diagnostic_decisions WHERE owner_id=v_neighbor LIMIT 1;
    SELECT id INTO v_answer FROM public.diagnostic_answers WHERE owner_id=v_owner LIMIT 1;
    SELECT id INTO v_foreign_answer FROM public.diagnostic_answers WHERE owner_id=v_neighbor LIMIT 1;
    SELECT id INTO v_photo FROM public.photo_assets WHERE owner_id=v_owner LIMIT 1;

    RETURN NEXT is((SELECT array_agg(c.relname||'.'||a.attname ORDER BY c.relname,k.ord)
        FROM pg_constraint f JOIN pg_class c ON c.oid=f.conrelid
        CROSS JOIN LATERAL unnest(f.conkey) WITH ORDINALITY k(attnum,ord)
        JOIN pg_attribute a ON a.attrelid=c.oid AND a.attnum=k.attnum
        WHERE f.contype='f' AND f.confrelid IN
            ('public.diagnostic_decisions'::regclass,'public.diagnostic_answers'::regclass)),
        ARRAY['care_plans.diagnostic_decision_id','care_plans.diagnostic_decision_revision']::text[],
        'actual diagnostic incoming FK inventory covers the composite plan key');

    v_before := pg_temp.care_plan_snapshot();
    RETURN NEXT is(public.purge_account_deletion_diagnostic_decisions_internal(v_owner,v_neighbor_operation),false,
        'another deleting owner operation is rejected');
    RETURN NEXT is(public.purge_account_deletion_diagnostic_decisions_internal(v_neighbor,v_operation),false,
        'operation cannot be applied to another owner');
    RETURN NEXT is(public.purge_account_deletion_diagnostic_decisions_internal(NULL,v_operation),false,
        'null diagnostic owner rejected');
    RETURN NEXT is(public.purge_account_deletion_diagnostic_decisions_internal(v_owner,NULL),false,
        'null diagnostic operation rejected');
    RETURN NEXT is(pg_temp.care_plan_snapshot(),v_before,'invalid diagnostic requests are atomic');
    BEGIN
        UPDATE public.profiles SET account_state='active' WHERE id=v_owner;
        v_before := pg_temp.care_plan_snapshot();
        RETURN NEXT is(public.purge_account_deletion_diagnostic_decisions_internal(v_owner,v_operation),false,
            'old deletion receipt cannot purge an active owner');
        RETURN NEXT is(pg_temp.care_plan_snapshot(),v_before,'old receipt preserves the graph');
        RAISE SQLSTATE 'Z1610';
    EXCEPTION WHEN SQLSTATE 'Z1610' THEN NULL;
    END;
    BEGIN
        UPDATE public.operation_receipts SET payload_hash='forged'
            WHERE owner_id=v_owner AND operation_id=v_operation;
        v_before := pg_temp.care_plan_snapshot();
        RETURN NEXT is(public.purge_account_deletion_diagnostic_decisions_internal(v_owner,v_operation),false,
            'forged diagnostic deletion receipt rejected');
        RETURN NEXT is(pg_temp.care_plan_snapshot(),v_before,'forged receipt hold is atomic');
        RAISE SQLSTATE 'Z1610';
    EXCEPTION WHEN SQLSTATE 'Z1610' THEN NULL;
    END;

    FOR v_case IN 1..12 LOOP
        BEGIN
            CASE v_case
            WHEN 1 THEN
                UPDATE public.care_plans SET diagnostic_decision_id=v_decision,
                    diagnostic_decision_revision=1,deleted_at=clock_timestamp()
                    WHERE owner_id=v_neighbor AND plan_kind='recovery';
            WHEN 2 THEN
                UPDATE public.diagnostic_answers SET decision_id=v_decision,
                    question_id='cross-owner-fixture',deleted_at=clock_timestamp()
                    WHERE id=v_foreign_answer;
            WHEN 3 THEN
                UPDATE public.diagnostic_decisions SET origin_decision_id=v_decision
                    WHERE id=v_foreign_decision;
            WHEN 4 THEN
                UPDATE public.diagnostic_decisions SET answer_snapshot_ids=ARRAY[v_answer]
                    WHERE id=v_foreign_decision;
            WHEN 5 THEN
                INSERT INTO public.diagnostic_decisions(id,revision,analysis_result_id,owner_id,
                    kb_release_id,policy_version,original_candidates,decision_scores,state,decision_receipt)
                SELECT v_decision,2,analysis_result_id,v_neighbor,kb_release_id,policy_version,
                    original_candidates,decision_scores,state,decision_receipt
                    FROM public.diagnostic_decisions WHERE id=v_foreign_decision;
            WHEN 6 THEN
                UPDATE public.diagnostic_decisions SET answer_snapshot_ids=ARRAY[v_foreign_answer]
                    WHERE id=v_decision;
            WHEN 7 THEN
                UPDATE public.diagnostic_answers SET decision_id=v_foreign_decision,
                    question_id='cross-owner-fixture' WHERE id=v_answer;
            WHEN 8 THEN
                UPDATE public.diagnostic_decisions SET origin_decision_id=v_foreign_decision WHERE id=v_decision;
            WHEN 9 THEN
                UPDATE public.care_plans SET diagnostic_decision_id=v_decision,
                    diagnostic_decision_revision=NULL WHERE owner_id=v_neighbor AND plan_kind='routine';
            WHEN 10 THEN
                UPDATE public.diagnostic_decisions SET analysis_result_id=(
                    SELECT analysis_result_id FROM public.diagnostic_decisions WHERE id=v_foreign_decision)
                    WHERE id=v_decision;
            WHEN 11 THEN
                -- Hold a dependency owned by the caller as well: no cascade or
                -- restrictive reference outside this phase may be silently removed.
                CREATE TABLE public.t010_restrictive_reference(
                    decision_id uuid,revision integer,
                    CONSTRAINT t010_exact_dependency FOREIGN KEY(decision_id,revision)
                        REFERENCES public.diagnostic_decisions(id,revision));
                INSERT INTO public.t010_restrictive_reference VALUES(v_decision,1);
            WHEN 12 THEN
                CREATE TABLE public.t010_answer_reference(
                    answer_id uuid CONSTRAINT t010_answer_dependency
                        REFERENCES public.diagnostic_answers(id) ON DELETE CASCADE);
                INSERT INTO public.t010_answer_reference VALUES(v_answer);
            END CASE;
            v_before := pg_temp.care_plan_snapshot();
            RETURN NEXT is(public.purge_account_deletion_diagnostic_decisions_internal(v_owner,v_operation),false,
                'diagnostic association holds before predecessor mutation, case '||v_case);
            RETURN NEXT is(pg_temp.care_plan_snapshot(),v_before,'diagnostic hold is atomic, case '||v_case);
            PERFORM public.verify_account_deletion_storage_internal(v_owner,v_operation);
            v_before := pg_temp.care_plan_snapshot();
            RETURN NEXT is(public.purge_account_deletion_diagnostic_decisions_internal(v_owner,v_operation),false,
                'saved proof cannot bypass diagnostic dependency, case '||v_case);
            RETURN NEXT is(pg_temp.care_plan_snapshot(),v_before,'saved proof hold is atomic, case '||v_case);
            IF v_case=11 THEN
                RETURN NEXT is((SELECT count(*) FROM public.t010_restrictive_reference),1::bigint,
                    'restrictive dependency is retained');
            END IF;
            IF v_case=12 THEN
                RETURN NEXT is((SELECT count(*) FROM public.t010_answer_reference),1::bigint,
                    'unowned cascading answer dependency is retained');
            END IF;
            RAISE SQLSTATE 'Z1610';
        EXCEPTION WHEN SQLSTATE 'Z1610' THEN NULL;
        END;
    END LOOP;
    BEGIN
        UPDATE public.care_entries SET task_id=(SELECT id FROM public.care_tasks WHERE owner_id=v_owner),
            state='voided' WHERE owner_id=v_neighbor;
        v_before := pg_temp.care_plan_snapshot();
        RETURN NEXT is(public.purge_account_deletion_diagnostic_decisions_internal(v_owner,v_operation),false,
            '004 predecessor hold blocks diagnostic deletion');
        RETURN NEXT is(pg_temp.care_plan_snapshot(),v_before,'nested hold rolls back the entire diagnostic phase');
        RAISE SQLSTATE 'Z1610';
    EXCEPTION WHEN SQLSTATE 'Z1610' THEN NULL;
    END;

    FOR v_case IN 1..3 LOOP
        BEGIN
            IF v_case>1 THEN
                UPDATE public.account_deletion_requests SET storage_verified_at='2000-01-01 UTC'
                    WHERE owner_id=v_owner;
            END IF;
            IF v_case=3 THEN
                UPDATE public.diagnosis_upload_tickets SET expires_at=clock_timestamp()+interval '1 hour'
                    WHERE photo_asset_id=v_photo;
            ELSE
                INSERT INTO storage.objects(bucket_id,name)
                    VALUES('analysis-inputs',v_owner::text||'/diagnostic-hold');
            END IF;
            v_before := pg_temp.care_plan_snapshot();
            RETURN NEXT is(public.purge_account_deletion_diagnostic_decisions_internal(v_owner,v_operation),false,
                'fresh Storage check holds absent/old proof or unexpired upload, case '||v_case);
            RETURN NEXT is(pg_temp.care_plan_snapshot(),v_before,'Storage hold preserves all rows and evidence');
            RAISE SQLSTATE 'Z1610';
        EXCEPTION WHEN SQLSTATE 'Z1610' THEN NULL;
        END;
    END LOOP;

    -- Canonical versioned decisions with both stored associations.
    INSERT INTO public.diagnostic_decisions(id,revision,origin_decision_id,analysis_result_id,owner_id,
        kb_release_id,policy_version,original_candidates,answer_snapshot_ids,decision_scores,state,decision_receipt)
    SELECT id,2,id,analysis_result_id,owner_id,kb_release_id,policy_version,original_candidates,
        ARRAY[v_answer],decision_scores,state,decision_receipt
        FROM public.diagnostic_decisions WHERE id=v_decision AND revision=1;
    PERFORM public.verify_account_deletion_storage_internal(v_owner,v_operation);
    v_before := pg_temp.care_plan_snapshot();
    CREATE TRIGGER t010_reject_decision BEFORE DELETE ON public.diagnostic_decisions
        FOR EACH ROW EXECUTE FUNCTION pg_temp.reject_care_leaf_purge();
    RETURN NEXT throws_ok(format(
        'SELECT public.purge_account_deletion_diagnostic_decisions_internal(%L::uuid,%L::uuid)',
        v_owner,v_operation),'Z0066','FIXTURE_LEAF_PURGE_FAILURE','late diagnostic failure propagates');
    DROP TRIGGER t010_reject_decision ON public.diagnostic_decisions;
    RETURN NEXT is(pg_temp.care_plan_snapshot(),v_before,'late failure restores answers and all predecessors');

    v_expected := v_before;
    FOREACH v_table IN ARRAY ARRAY['care_plans','task_rules','care_tasks','care_entries',
        'care_observations','recovery_transitions','care_reversals','schedule_changes','notification_claims',
        'diagnostic_answers','diagnostic_decisions'] LOOP
        SELECT coalesce(jsonb_agg(e.value ORDER BY e.ordinality),'[]'::jsonb) INTO v_rows
            FROM jsonb_array_elements(v_before->v_table) WITH ORDINALITY e(value,ordinality)
            WHERE e.value->>'owner_id'<>v_owner::text;
        v_expected := jsonb_set(v_expected,ARRAY[v_table],v_rows);
    END LOOP;
    RETURN NEXT is(public.purge_account_deletion_diagnostic_decisions_internal(v_owner,v_operation),true,
        'expired uploads and clean Storage permit canonical owner diagnostic cleanup after 004');
    RETURN NEXT is(pg_temp.care_plan_snapshot(),v_expected,
        'only owner diagnostics and eligible predecessors removed; foreign graph, analysis, quota, receipts and Auth retained');
    RETURN NEXT is((SELECT account_state FROM public.profiles WHERE id=v_owner),'deleting',
        'diagnostic cleanup does not finalize Auth');
    v_before := pg_temp.care_plan_snapshot();
    RETURN NEXT is(public.purge_account_deletion_diagnostic_decisions_internal(v_owner,v_operation),true,
        'exact diagnostic replay succeeds');
    RETURN NEXT is(pg_temp.care_plan_snapshot(),v_before,'exact diagnostic replay changes no row');
    INSERT INTO storage.objects(bucket_id,name) VALUES('analysis-inputs',v_owner::text||'/diagnostic-replay');
    v_before := pg_temp.care_plan_snapshot();
    RETURN NEXT is(public.purge_account_deletion_diagnostic_decisions_internal(v_owner,v_operation),false,
        'successful diagnostic replay still requires fresh Storage readiness');
    RETURN NEXT is(pg_temp.care_plan_snapshot(),v_before,'replay hold is atomic');

    RETURN NEXT ok((SELECT prosecdef AND proconfig=ARRAY['search_path=""']
        FROM pg_proc WHERE oid=
            'public.purge_account_deletion_diagnostic_decisions_internal(uuid,uuid)'::regprocedure),
        'diagnostic phase is SECURITY DEFINER with an empty search path');
    RETURN NEXT ok(NOT EXISTS (
        SELECT 1 FROM pg_proc p CROSS JOIN LATERAL
            aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) a
        WHERE p.oid='public.purge_account_deletion_diagnostic_decisions_internal(uuid,uuid)'::regprocedure
            AND a.grantee<>p.proowner),'diagnostic function has no nonowner grants');
    FOREACH v_role IN ARRAY ARRAY['anon','authenticated','service_role'] LOOP
        v_denied := false;
        BEGIN
            EXECUTE format('SET LOCAL ROLE %I',v_role);
            PERFORM public.purge_account_deletion_diagnostic_decisions_internal(v_owner,v_operation);
        EXCEPTION WHEN insufficient_privilege THEN v_denied := true;
        END;
        RESET ROLE;
        RETURN NEXT ok(v_denied,'actual diagnostic execution denied for '||v_role);
    END LOOP;
    DELETE FROM storage.objects WHERE bucket_id='analysis-inputs' AND name=v_owner::text||'/diagnostic-replay';
    SELECT pg_get_userbyid(proowner) INTO v_role FROM pg_proc
        WHERE oid='public.purge_account_deletion_diagnostic_decisions_internal(uuid,uuid)'::regprocedure;
    EXECUTE format('SET LOCAL ROLE %I',v_role);
    RETURN NEXT is(public.purge_account_deletion_diagnostic_decisions_internal(v_owner,v_operation),true,
        'SQL function owner can execute diagnostic replay');
    RESET ROLE;
    RAISE SQLSTATE 'Z1610';
EXCEPTION WHEN SQLSTATE 'Z1610' THEN
    RETURN;
END;
$$;

-- 011 reuses the canonical owner graphs and rolls back before 010/004 tests.
CREATE FUNCTION pg_temp.analysis_purge_snapshot() RETURNS jsonb LANGUAGE sql AS $$
    SELECT pg_temp.care_plan_snapshot() || pg_temp.media_inventory_snapshot()
$$;

CREATE FUNCTION pg_temp.analysis_purge_tests(v_owner uuid,v_neighbor uuid)
RETURNS SETOF text LANGUAGE plpgsql AS $$
DECLARE
    v_operation uuid;
    v_result uuid;
    v_foreign_result uuid;
    v_photo uuid;
    v_draft uuid;
    v_before jsonb;
    v_expected jsonb;
    v_rows jsonb;
    v_table text;
    v_role text;
    v_case integer;
    v_denied boolean;
BEGIN
    IF to_regprocedure('public.purge_account_deletion_analysis_results_internal(uuid,uuid)') IS NULL THEN
        RETURN QUERY SELECT skip('011 result purge is outside selected migration version',1);
        RETURN;
    END IF;
    SELECT operation_id INTO v_operation FROM public.account_deletion_requests WHERE owner_id=v_owner;
    SELECT id INTO v_result FROM public.analysis_results WHERE owner_id=v_owner LIMIT 1;
    SELECT id INTO v_foreign_result FROM public.analysis_results WHERE owner_id=v_neighbor LIMIT 1;
    SELECT source_photo_id INTO v_photo FROM public.analysis_results WHERE id=v_result;
    RETURN NEXT ok(v_result IS NOT NULL AND v_foreign_result IS NOT NULL,
        '011 tests have both canonical owner results');
    RETURN NEXT is((SELECT array_agg(c.relname||'.'||a.attname ORDER BY c.relname,k.ord)
        FROM pg_constraint f JOIN pg_class c ON c.oid=f.conrelid
        CROSS JOIN LATERAL unnest(f.conkey) WITH ORDINALITY k(attnum,ord)
        JOIN pg_attribute a ON a.attrelid=c.oid AND a.attnum=k.attnum
        WHERE f.contype='f' AND f.confrelid='public.analysis_results'::regclass),
        ARRAY['care_plans.source_analysis_id','diagnostic_decisions.analysis_result_id']::text[],
        '011 actual incoming inventory includes nulling plans and cascading decisions');

    v_before := pg_temp.analysis_purge_snapshot();
    RETURN NEXT is(public.purge_account_deletion_analysis_results_internal(v_owner,gen_random_uuid()),false,
        '011 wrong operation rejected');
    RETURN NEXT is(public.purge_account_deletion_analysis_results_internal(v_neighbor,v_operation),false,
        '011 other deleting owner rejected');
    RETURN NEXT is(public.purge_account_deletion_analysis_results_internal(NULL,v_operation),false,
        '011 null owner rejected');
    RETURN NEXT is(public.purge_account_deletion_analysis_results_internal(v_owner,NULL),false,
        '011 null operation rejected');
    RETURN NEXT is(pg_temp.analysis_purge_snapshot(),v_before,'011 invalid identity preserves full graph');

    FOR v_case IN 1..18 LOOP
        BEGIN
            CASE v_case
            WHEN 1 THEN
                UPDATE public.analysis_results SET job_id=(
                    SELECT job_id FROM public.analysis_results WHERE id=v_foreign_result) WHERE id=v_result;
            WHEN 2 THEN
                UPDATE public.analysis_results SET origin_job_id=(
                    SELECT job_id FROM public.analysis_results WHERE id=v_foreign_result) WHERE id=v_result;
            WHEN 3 THEN
                UPDATE public.analysis_results SET plant_id=(
                    SELECT plant_id FROM public.analysis_results WHERE id=v_foreign_result) WHERE id=v_result;
            WHEN 4 THEN
                UPDATE public.analysis_results SET source_photo_id=(
                    SELECT source_photo_id FROM public.analysis_results WHERE id=v_foreign_result) WHERE id=v_result;
            WHEN 5 THEN
                UPDATE public.analysis_results SET source_snapshot_id=(
                    SELECT source_snapshot_id FROM public.analysis_results WHERE id=v_foreign_result) WHERE id=v_result;
            WHEN 6 THEN
                INSERT INTO public.guest_drafts(guest_owner_id,flow_id,intent,add_method)
                    VALUES(v_neighbor,gen_random_uuid(),'care','catalogue') RETURNING id INTO v_draft;
                UPDATE public.analysis_results SET draft_id=v_draft WHERE id=v_result;
            WHEN 7 THEN
                UPDATE public.diagnostic_decisions SET analysis_result_id=v_foreign_result WHERE owner_id=v_owner;
            WHEN 8 THEN
                UPDATE public.diagnostic_decisions SET analysis_result_id=v_result WHERE owner_id=v_neighbor;
            WHEN 9 THEN
                UPDATE public.care_plans SET source_analysis_id=v_foreign_result
                    WHERE owner_id=v_owner AND plan_kind='recovery';
            WHEN 10 THEN
                UPDATE public.care_plans SET source_analysis_id=v_result
                    WHERE owner_id=v_neighbor AND plan_kind='recovery';
            WHEN 11 THEN
                ALTER TABLE public.analysis_results ADD CONSTRAINT t011_composite UNIQUE(id,owner_id);
                CREATE TABLE public.t011_reference(
                    result_id uuid,owner_id uuid,
                    FOREIGN KEY(result_id,owner_id) REFERENCES public.analysis_results(id,owner_id));
                INSERT INTO public.t011_reference VALUES(v_result,v_owner);
            WHEN 12 THEN
                CREATE TABLE public.t011_reference(
                    result_id uuid REFERENCES public.analysis_results(id) ON DELETE CASCADE);
                INSERT INTO public.t011_reference VALUES(v_result);
            WHEN 13 THEN
                CREATE TABLE public.t011_reference(
                    result_id uuid REFERENCES public.analysis_results(id) ON DELETE SET NULL);
                INSERT INTO public.t011_reference VALUES(v_result);
            WHEN 14 THEN
                UPDATE public.diagnostic_decisions SET origin_decision_id=(
                    SELECT id FROM public.diagnostic_decisions WHERE owner_id=v_neighbor LIMIT 1)
                    WHERE owner_id=v_owner;
            WHEN 15 THEN
                UPDATE public.account_deletion_requests SET storage_verified_at='2000-01-01 UTC'
                    WHERE owner_id=v_owner;
                INSERT INTO storage.objects(bucket_id,name) VALUES('analysis-inputs',v_owner::text||'/011-hold');
            WHEN 16 THEN
                UPDATE public.account_deletion_requests SET storage_verified_at='2000-01-01 UTC'
                    WHERE owner_id=v_owner;
                UPDATE public.diagnosis_upload_tickets SET expires_at=clock_timestamp()+interval '1 hour'
                    WHERE photo_asset_id=v_photo;
            WHEN 17 THEN
                UPDATE public.profiles SET account_state='active' WHERE id=v_owner;
            WHEN 18 THEN
                UPDATE public.operation_receipts SET payload_hash='forged'
                    WHERE owner_id=v_owner AND operation_id=v_operation;
            END CASE;
            v_before := pg_temp.analysis_purge_snapshot();
            CREATE TRIGGER t011_predecessor_guard BEFORE DELETE ON public.care_tasks
                FOR EACH ROW EXECUTE FUNCTION pg_temp.reject_care_leaf_purge();
            RETURN NEXT is(public.purge_account_deletion_analysis_results_internal(v_owner,v_operation),false,
                '011 malformed graph or fresh proof hold, case '||v_case);
            RETURN NEXT is(pg_temp.analysis_purge_snapshot(),v_before,
                '011 hold preserves predecessors, results and evidence, case '||v_case);
            IF v_case BETWEEN 11 AND 13 THEN
                RETURN NEXT is((SELECT count(*) FROM public.t011_reference),1::bigint,
                    '011 unknown reference remains intact');
            END IF;
            RAISE SQLSTATE 'Z1611';
        EXCEPTION WHEN SQLSTATE 'Z1611' THEN NULL;
        END;
    END LOOP;

    PERFORM public.verify_account_deletion_storage_internal(v_owner,v_operation);
    v_before := pg_temp.analysis_purge_snapshot();
    CREATE TRIGGER t011_reject_result BEFORE DELETE ON public.analysis_results
        FOR EACH ROW EXECUTE FUNCTION pg_temp.reject_care_leaf_purge();
    RETURN NEXT throws_ok(format(
        'SELECT public.purge_account_deletion_analysis_results_internal(%L::uuid,%L::uuid)',v_owner,v_operation),
        'Z0066','FIXTURE_LEAF_PURGE_FAILURE','011 late result failure propagates');
    DROP TRIGGER t011_reject_result ON public.analysis_results;
    RETURN NEXT is(pg_temp.analysis_purge_snapshot(),v_before,'011 late failure restores all predecessor deletions');

    v_expected := v_before;
    FOREACH v_table IN ARRAY ARRAY['care_plans','task_rules','care_tasks','care_entries',
        'care_observations','recovery_transitions','care_reversals','schedule_changes','notification_claims',
        'diagnostic_answers','diagnostic_decisions','analysis_results'] LOOP
        SELECT coalesce(jsonb_agg(e.value ORDER BY e.ordinality),'[]'::jsonb) INTO v_rows
            FROM jsonb_array_elements(v_before->v_table) WITH ORDINALITY e(value,ordinality)
            WHERE e.value->>'owner_id'<>v_owner::text;
        v_expected := jsonb_set(v_expected,ARRAY[v_table],v_rows);
    END LOOP;
    RETURN NEXT is(public.purge_account_deletion_analysis_results_internal(v_owner,v_operation),true,
        '011 canonical cleanup follows validated 010 under fresh proof');
    RETURN NEXT is(pg_temp.analysis_purge_snapshot(),v_expected,
        '011 removes only owner results and allowed children; neighbors, jobs, runtime, quotas, profiles and Auth retained');
    v_before := pg_temp.analysis_purge_snapshot();
    RETURN NEXT is(public.purge_account_deletion_analysis_results_internal(v_owner,v_operation),true,
        '011 exact operation replay succeeds');
    RETURN NEXT is(pg_temp.analysis_purge_snapshot(),v_before,'011 replay changes no rows');
    BEGIN
        INSERT INTO storage.objects(bucket_id,name) VALUES('analysis-inputs',v_owner::text||'/011-replay');
        v_before := pg_temp.analysis_purge_snapshot();
        RETURN NEXT is(public.purge_account_deletion_analysis_results_internal(v_owner,v_operation),false,
            '011 replay still requires fresh Storage readiness');
        RETURN NEXT is(pg_temp.analysis_purge_snapshot(),v_before,'011 replay hold is atomic');
        RAISE SQLSTATE 'Z1611';
    EXCEPTION WHEN SQLSTATE 'Z1611' THEN NULL;
    END;

    RETURN NEXT ok((SELECT prosecdef AND provolatile='v' AND proconfig=ARRAY['search_path=""']
        FROM pg_proc WHERE oid='public.purge_account_deletion_analysis_results_internal(uuid,uuid)'::regprocedure),
        '011 is volatile SECURITY DEFINER with empty search path');
    RETURN NEXT ok(NOT EXISTS (
        SELECT 1 FROM pg_proc p CROSS JOIN LATERAL
            aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) a
        WHERE p.oid='public.purge_account_deletion_analysis_results_internal(uuid,uuid)'::regprocedure
            AND a.grantee<>p.proowner),'011 has no nonowner grants');
    FOREACH v_role IN ARRAY ARRAY['anon','authenticated','service_role'] LOOP
        v_denied := false;
        BEGIN
            EXECUTE format('SET LOCAL ROLE %I',v_role);
            PERFORM public.purge_account_deletion_analysis_results_internal(v_owner,v_operation);
        EXCEPTION WHEN insufficient_privilege THEN v_denied := true;
        END;
        RESET ROLE;
        RETURN NEXT ok(v_denied,'011 execution denied for '||v_role);
    END LOOP;
    SELECT pg_get_userbyid(proowner) INTO v_role FROM pg_proc
        WHERE oid='public.purge_account_deletion_analysis_results_internal(uuid,uuid)'::regprocedure;
    EXECUTE format('SET LOCAL ROLE %I',v_role);
    RETURN NEXT is(public.purge_account_deletion_analysis_results_internal(v_owner,v_operation),true,
        '011 SQL owner can replay');
    RESET ROLE;
    RAISE SQLSTATE 'Z1611';
EXCEPTION WHEN SQLSTATE 'Z1611' THEN
    RETURN;
END;
$$;

-- 012 runs against the same canonical predecessor graph and rolls back all cases.
CREATE FUNCTION pg_temp.snapshot_purge_tests(v_owner uuid,v_neighbor uuid)
RETURNS SETOF text LANGUAGE plpgsql AS $$
DECLARE
    v_operation uuid;
    v_snapshot uuid;
    v_foreign_snapshot uuid;
    v_plant uuid;
    v_foreign_plant uuid;
    v_draft uuid;
    v_draft_snapshot uuid;
    v_before jsonb;
    v_expected jsonb;
    v_rows jsonb;
    v_table text;
    v_role text;
    v_case integer;
    v_denied boolean;
BEGIN
    IF to_regprocedure('public.purge_account_deletion_condition_snapshots_internal(uuid,uuid)') IS NULL THEN
        RETURN QUERY SELECT skip('012 snapshot purge is outside selected migration version',1);
        RETURN;
    END IF;
    SELECT operation_id INTO v_operation FROM public.account_deletion_requests WHERE owner_id=v_owner;
    SELECT source_snapshot_id,plant_id INTO v_snapshot,v_plant
        FROM public.analysis_results WHERE owner_id=v_owner LIMIT 1;
    SELECT source_snapshot_id,plant_id INTO v_foreign_snapshot,v_foreign_plant
        FROM public.analysis_results WHERE owner_id=v_neighbor LIMIT 1;
    RETURN NEXT ok(v_snapshot IS NOT NULL AND v_foreign_snapshot IS NOT NULL,
        '012 has canonical results, diagnostics, plans and journal predecessors');
    RETURN NEXT is((SELECT array_agg(c.relname||'.'||a.attname ORDER BY c.relname,a.attname)
        FROM pg_constraint f JOIN pg_class c ON c.oid=f.conrelid
        JOIN pg_attribute a ON a.attrelid=c.oid AND a.attnum=f.conkey[1]
        WHERE f.contype='f' AND f.confrelid='public.condition_snapshots'::regclass),
        ARRAY['analysis_jobs.snapshot_id','analysis_results.source_snapshot_id','care_plans.snapshot_id',
            'guest_drafts.condition_snapshot_id','plants.current_condition_snapshot_id']::text[],
        '012 inventories all five real incoming FKs; legacy alias has no FK');

    v_before := pg_temp.analysis_purge_snapshot();
    CREATE TRIGGER t012_predecessor_guard BEFORE DELETE ON public.care_tasks
        FOR EACH ROW EXECUTE FUNCTION pg_temp.reject_care_leaf_purge();
    RETURN NEXT is(public.purge_account_deletion_condition_snapshots_internal(v_owner,v_operation),false,
        '012 same-owner retained job input blocks before predecessor execution');
    DROP TRIGGER t012_predecessor_guard ON public.care_tasks;
    RETURN NEXT is(pg_temp.analysis_purge_snapshot(),v_before,'012 job hold changes no rows or evidence');

    -- Only fixture preparation unlinks retained job inputs, never the finalizer.
    UPDATE public.analysis_jobs SET snapshot_id=NULL WHERE owner_id=v_owner;
    INSERT INTO public.guest_drafts(guest_owner_id,flow_id,intent,add_method)
        VALUES(v_owner,gen_random_uuid(),'care','catalogue') RETURNING id INTO v_draft;
    INSERT INTO public.condition_snapshots(owner_id,draft_id,deleted_at)
        VALUES(v_owner,v_draft,clock_timestamp()) RETURNING id INTO v_draft_snapshot;
    UPDATE public.guest_drafts SET condition_snapshot_id=v_draft_snapshot WHERE id=v_draft;
    UPDATE public.plants SET current_snapshot_id=v_snapshot,
        current_condition_snapshot_id=v_snapshot WHERE id=v_plant;

    v_before := pg_temp.analysis_purge_snapshot();
    RETURN NEXT is(public.purge_account_deletion_condition_snapshots_internal(v_owner,gen_random_uuid()),false,
        '012 wrong operation rejected');
    RETURN NEXT is(public.purge_account_deletion_condition_snapshots_internal(v_neighbor,v_operation),false,
        '012 other deleting owner rejected');
    RETURN NEXT is(public.purge_account_deletion_condition_snapshots_internal(NULL,v_operation),false,
        '012 null owner rejected');
    RETURN NEXT is(public.purge_account_deletion_condition_snapshots_internal(v_owner,NULL),false,
        '012 null operation rejected');
    RETURN NEXT is(pg_temp.analysis_purge_snapshot(),v_before,'012 invalid calls preserve full graph');

    FOR v_case IN 1..18 LOOP
        BEGIN
            CASE v_case
            WHEN 1 THEN
                UPDATE public.plants SET current_snapshot_id=v_snapshot,
                    current_condition_snapshot_id=v_snapshot WHERE id=v_foreign_plant;
            WHEN 2 THEN
                ALTER TABLE public.plants DISABLE TRIGGER trg_plants_sync_columns;
                UPDATE public.plants SET current_snapshot_id=v_snapshot,
                    current_condition_snapshot_id=NULL WHERE id=v_foreign_plant;
                ALTER TABLE public.plants ENABLE TRIGGER trg_plants_sync_columns;
            WHEN 3 THEN
                UPDATE public.plants SET current_snapshot_id=v_foreign_snapshot,
                    current_condition_snapshot_id=v_foreign_snapshot WHERE id=v_plant;
            WHEN 4 THEN
                UPDATE public.condition_snapshots
                    SET plant_id=v_foreign_plant,
                        version=(SELECT coalesce(max(s.version),0)+1
                            FROM public.condition_snapshots s WHERE s.plant_id=v_foreign_plant)
                    WHERE id=v_snapshot;
            WHEN 5 THEN
                UPDATE public.condition_snapshots SET owner_id=v_neighbor WHERE id=v_snapshot;
            WHEN 6 THEN
                UPDATE public.guest_drafts SET guest_owner_id=v_neighbor WHERE id=v_draft;
            WHEN 7 THEN
                UPDATE public.care_plans SET snapshot_id=v_snapshot WHERE owner_id=v_neighbor;
            WHEN 8 THEN
                UPDATE public.analysis_results SET source_snapshot_id=v_snapshot WHERE owner_id=v_neighbor;
            WHEN 9 THEN
                UPDATE public.analysis_jobs SET snapshot_id=v_snapshot WHERE owner_id=v_neighbor;
            WHEN 10 THEN
                CREATE TABLE public.t012_reference(
                    snapshot_id uuid REFERENCES public.condition_snapshots(id));
                INSERT INTO public.t012_reference VALUES(v_snapshot);
            WHEN 11 THEN
                CREATE TABLE public.t012_reference(
                    snapshot_id uuid REFERENCES public.condition_snapshots(id) ON DELETE CASCADE);
                INSERT INTO public.t012_reference VALUES(v_snapshot);
            WHEN 12 THEN
                CREATE TABLE public.t012_reference(
                    snapshot_id uuid REFERENCES public.condition_snapshots(id) ON DELETE SET NULL);
                INSERT INTO public.t012_reference VALUES(v_snapshot);
            WHEN 13 THEN
                UPDATE public.account_deletion_requests SET storage_verified_at='2000-01-01 UTC'
                    WHERE owner_id=v_owner;
                INSERT INTO storage.objects(bucket_id,name) VALUES('analysis-inputs',v_owner::text||'/012-hold');
            WHEN 14 THEN
                UPDATE public.operation_receipts SET payload_hash='forged'
                    WHERE owner_id=v_owner AND operation_id=v_operation;
            WHEN 15 THEN
                UPDATE public.profiles SET account_state='active' WHERE id=v_owner;
            WHEN 16 THEN
                -- Same owner, wrong parent is not authorized for alias cleanup.
                UPDATE public.plants SET current_snapshot_id=v_draft_snapshot,
                    current_condition_snapshot_id=v_draft_snapshot WHERE id=v_plant;
            WHEN 17 THEN
                ALTER TABLE public.plants DISABLE TRIGGER trg_plants_sync_columns;
                UPDATE public.plants SET current_snapshot_id=gen_random_uuid() WHERE id=v_plant;
                ALTER TABLE public.plants ENABLE TRIGGER trg_plants_sync_columns;
            WHEN 18 THEN
                ALTER TABLE public.condition_snapshots ADD CONSTRAINT t012_parent_key UNIQUE(id,owner_id);
                CREATE TABLE public.t012_reference(
                    snapshot_id uuid,owner_id uuid,
                    FOREIGN KEY(snapshot_id,owner_id) REFERENCES public.condition_snapshots(id,owner_id));
                INSERT INTO public.t012_reference VALUES(v_snapshot,v_owner);
            END CASE;
            v_before := pg_temp.analysis_purge_snapshot();
            CREATE TRIGGER t012_predecessor_guard BEFORE DELETE ON public.care_tasks
                FOR EACH ROW EXECUTE FUNCTION pg_temp.reject_care_leaf_purge();
            RETURN NEXT is(public.purge_account_deletion_condition_snapshots_internal(v_owner,v_operation),false,
                '012 preflight fails closed before predecessor, case '||v_case);
            RETURN NEXT is(pg_temp.analysis_purge_snapshot(),v_before,
                '012 hold preserves graph and fresh/stale evidence, case '||v_case);
            IF v_case BETWEEN 10 AND 12 OR v_case=18 THEN
                RETURN NEXT is((SELECT count(*) FROM public.t012_reference),1::bigint,
                    '012 unknown ordinary child retained');
            END IF;
            RAISE SQLSTATE 'Z1612';
        EXCEPTION WHEN SQLSTATE 'Z1612' THEN NULL;
        END;
    END LOOP;

    BEGIN
        CREATE TABLE public.t012_result_reference(
            result_id uuid REFERENCES public.analysis_results(id));
        INSERT INTO public.t012_result_reference
            SELECT id FROM public.analysis_results WHERE owner_id=v_owner;
        v_before := pg_temp.analysis_purge_snapshot();
        RETURN NEXT is(public.purge_account_deletion_condition_snapshots_internal(v_owner,v_operation),false,
            '012 nested 011 restrictive dependency holds the whole phase');
        RETURN NEXT is(pg_temp.analysis_purge_snapshot(),v_before,
            '012 predecessor hold restores verification and keeps every reference');
        RAISE SQLSTATE 'Z1612';
    EXCEPTION WHEN SQLSTATE 'Z1612' THEN NULL;
    END;

    -- Late errors must roll back successful predecessor work and alias clearing.
    PERFORM public.verify_account_deletion_storage_internal(v_owner,v_operation);
    v_before := pg_temp.analysis_purge_snapshot();
    CREATE TRIGGER t012_reject_snapshot BEFORE DELETE ON public.condition_snapshots
        FOR EACH ROW EXECUTE FUNCTION pg_temp.reject_care_leaf_purge();
    RETURN NEXT throws_ok(format(
        'SELECT public.purge_account_deletion_condition_snapshots_internal(%L::uuid,%L::uuid)',v_owner,v_operation),
        'Z0066','FIXTURE_LEAF_PURGE_FAILURE','012 late failure propagates');
    DROP TRIGGER t012_reject_snapshot ON public.condition_snapshots;
    RETURN NEXT is(pg_temp.analysis_purge_snapshot(),v_before,'012 late failure restores entire graph');

    -- Exercise canonical-only, legacy-only and synchronized aliases.
    FOR v_case IN 1..3 LOOP
        BEGIN
            ALTER TABLE public.plants DISABLE TRIGGER trg_plants_sync_columns;
            UPDATE public.plants
                SET current_condition_snapshot_id=CASE WHEN v_case=2 THEN NULL ELSE v_snapshot END,
                    current_snapshot_id=CASE WHEN v_case=1 THEN NULL ELSE v_snapshot END
                WHERE id=v_plant;
            ALTER TABLE public.plants ENABLE TRIGGER trg_plants_sync_columns;
            v_before := pg_temp.analysis_purge_snapshot();
            v_expected := v_before;
            FOREACH v_table IN ARRAY ARRAY['care_plans','task_rules','care_tasks','care_entries',
                'care_observations','recovery_transitions','care_reversals','schedule_changes','notification_claims',
                'diagnostic_answers','diagnostic_decisions','analysis_results','condition_snapshots'] LOOP
                SELECT coalesce(jsonb_agg(e.value ORDER BY e.ordinality),'[]'::jsonb) INTO v_rows
                    FROM jsonb_array_elements(v_before->v_table) WITH ORDINALITY e(value,ordinality)
                    WHERE e.value->>'owner_id'<>v_owner::text;
                v_expected := jsonb_set(v_expected,ARRAY[v_table],v_rows);
            END LOOP;
            SELECT jsonb_agg(x.row_value ORDER BY x.row_value::text) INTO v_rows FROM (
                SELECT CASE WHEN e->>'id'=v_plant::text
                    THEN e || '{"current_condition_snapshot_id":null,"current_snapshot_id":null}'::jsonb
                    ELSE e END AS row_value FROM jsonb_array_elements(v_before->'plants') e) x;
            v_expected := jsonb_set(v_expected,ARRAY['plants'],v_rows);
            SELECT jsonb_agg(x.row_value ORDER BY x.row_value::text) INTO v_rows FROM (
                SELECT CASE WHEN e->>'id'=v_draft::text
                    THEN e || '{"condition_snapshot_id":null}'::jsonb ELSE e END AS row_value
                FROM jsonb_array_elements(v_before->'public.guest_drafts') e) x;
            v_expected := jsonb_set(v_expected,ARRAY['public.guest_drafts'],v_rows);
            RETURN NEXT is(public.purge_account_deletion_condition_snapshots_internal(v_owner,v_operation),true,
                '012 safe canonical predecessor cleanup and alias variant '||v_case);
            RETURN NEXT is(pg_temp.analysis_purge_snapshot(),v_expected,
                '012 exact allowed changes only; jobs, Auth, receipts, foreign graph retained, variant '||v_case);
            v_before := pg_temp.analysis_purge_snapshot();
            RETURN NEXT is(public.purge_account_deletion_condition_snapshots_internal(v_owner,v_operation),true,
                '012 exact operation replay succeeds');
            RETURN NEXT is(pg_temp.analysis_purge_snapshot(),v_before,'012 replay changes no rows');
            INSERT INTO storage.objects(bucket_id,name) VALUES('analysis-inputs',v_owner::text||'/012-replay');
            v_before := pg_temp.analysis_purge_snapshot();
            RETURN NEXT is(public.purge_account_deletion_condition_snapshots_internal(v_owner,v_operation),false,
                '012 replay requires fresh Storage readiness');
            RETURN NEXT is(pg_temp.analysis_purge_snapshot(),v_before,'012 stale proof replay hold is atomic');
            RAISE SQLSTATE 'Z1612';
        EXCEPTION WHEN SQLSTATE 'Z1612' THEN NULL;
        END;
    END LOOP;

    RETURN NEXT ok((SELECT prosecdef AND provolatile='v' AND proconfig=ARRAY['search_path=""']
        FROM pg_proc WHERE oid='public.purge_account_deletion_condition_snapshots_internal(uuid,uuid)'::regprocedure),
        '012 volatile SECURITY DEFINER uses empty search path');
    RETURN NEXT ok(NOT EXISTS (
        SELECT 1 FROM pg_proc p CROSS JOIN LATERAL
            aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) a
        WHERE p.oid='public.purge_account_deletion_condition_snapshots_internal(uuid,uuid)'::regprocedure
            AND a.grantee<>p.proowner),'012 has no nonowner grants');
    FOREACH v_role IN ARRAY ARRAY['anon','authenticated','service_role'] LOOP
        v_denied := false;
        BEGIN
            EXECUTE format('SET LOCAL ROLE %I',v_role);
            PERFORM public.purge_account_deletion_condition_snapshots_internal(v_owner,v_operation);
        EXCEPTION WHEN insufficient_privilege THEN v_denied := true;
        END;
        RESET ROLE;
        RETURN NEXT ok(v_denied,'012 execution denied for '||v_role);
    END LOOP;
    SELECT pg_get_userbyid(proowner) INTO v_role FROM pg_proc
        WHERE oid='public.purge_account_deletion_condition_snapshots_internal(uuid,uuid)'::regprocedure;
    -- The function owner can execute a real purge as well as exact replay.
    EXECUTE format('SET LOCAL ROLE %I',v_role);
    RETURN NEXT is(public.purge_account_deletion_condition_snapshots_internal(v_owner,v_operation),true,
        '012 SQL owner can execute');
    RESET ROLE;
    RAISE SQLSTATE 'Z1612';
EXCEPTION WHEN SQLSTATE 'Z1612' THEN
    RETURN;
END;
$$;

-- 013 shares the canonical owner graphs and rolls every scenario back.
CREATE FUNCTION pg_temp.photo_row_purge_tests(v_owner uuid,v_neighbor uuid)
RETURNS SETOF text LANGUAGE plpgsql AS $$
DECLARE
    v_operation uuid;
    v_photo uuid;
    v_foreign_photo uuid;
    v_plant uuid;
    v_foreign_plant uuid;
    v_draft uuid;
    v_before jsonb;
    v_expected jsonb;
    v_rows jsonb;
    v_table text;
    v_case integer;
    v_role text;
    v_denied boolean;
BEGIN
    IF to_regprocedure('public.purge_account_deletion_photo_rows_internal(uuid,uuid)') IS NULL THEN
        RETURN QUERY SELECT skip('013 photo purge is outside selected migration version',1);
        RETURN;
    END IF;
    SELECT operation_id INTO v_operation FROM public.account_deletion_requests WHERE owner_id=v_owner;
    SELECT id,plant_id INTO v_photo,v_plant FROM public.photo_assets WHERE owner_id=v_owner LIMIT 1;
    SELECT id,plant_id INTO v_foreign_photo,v_foreign_plant
        FROM public.photo_assets WHERE owner_id=v_neighbor LIMIT 1;
    -- Only fixture preparation unlinks snapshots. Preserve the job's photo audit.
    UPDATE public.analysis_jobs SET snapshot_id=NULL,photo_ids=ARRAY[v_photo] WHERE owner_id=v_owner;
    UPDATE public.plants SET main_photo_id=v_photo WHERE id=v_plant;
    UPDATE public.care_observations SET photo_id=v_photo WHERE owner_id=v_owner;
    UPDATE public.photo_assets SET state='deleted',deleted_at=clock_timestamp() WHERE id=v_photo;
    INSERT INTO public.guest_identification_sources(photo_id,succeeded_at,expires_at,storage_cleaned_at)
        VALUES(v_photo,clock_timestamp()-interval '2 days',clock_timestamp()-interval '1 day',clock_timestamp());
    INSERT INTO public.guest_drafts(guest_owner_id,flow_id,intent,add_method,photo_id,deleted_at,storage_cleaned_at)
        VALUES(v_owner,gen_random_uuid(),'care','catalogue',v_photo,clock_timestamp(),clock_timestamp()) RETURNING id INTO v_draft;

    v_before := pg_temp.analysis_purge_snapshot();
    RETURN NEXT is(public.purge_account_deletion_photo_rows_internal(v_owner,gen_random_uuid()),false,
        '013 rejects wrong operation');
    RETURN NEXT is(public.purge_account_deletion_photo_rows_internal(v_neighbor,v_operation),false,
        '013 rejects another owner operation');
    RETURN NEXT is(public.purge_account_deletion_photo_rows_internal(NULL,v_operation),false,
        '013 rejects null owner');
    RETURN NEXT is(public.purge_account_deletion_photo_rows_internal(v_owner,NULL),false,
        '013 rejects null operation');
    RETURN NEXT is(pg_temp.analysis_purge_snapshot(),v_before,'013 invalid callers preserve full graph');

    FOR v_case IN 1..19 LOOP
        BEGIN
            CASE v_case
            WHEN 1 THEN UPDATE public.plants SET main_photo_id=v_photo WHERE id=v_foreign_plant;
            WHEN 2 THEN UPDATE public.plants SET main_photo_id=v_foreign_photo WHERE id=v_plant;
            WHEN 3 THEN UPDATE public.photo_assets SET plant_id=v_foreign_plant WHERE id=v_photo;
            WHEN 4 THEN UPDATE public.photo_assets SET plant_id=v_plant WHERE id=v_foreign_photo;
            WHEN 5 THEN UPDATE public.guest_drafts SET guest_owner_id=v_neighbor WHERE id=v_draft;
            WHEN 6 THEN UPDATE public.guest_drafts SET photo_id=v_foreign_photo WHERE id=v_draft;
            WHEN 7 THEN UPDATE public.care_observations SET photo_id=v_photo WHERE owner_id=v_neighbor;
            WHEN 8 THEN UPDATE public.care_observations SET photo_id=v_foreign_photo WHERE owner_id=v_owner;
            WHEN 9 THEN UPDATE public.analysis_results SET source_photo_id=v_photo WHERE owner_id=v_neighbor;
            WHEN 10 THEN UPDATE public.care_plans SET source_photo_id=v_photo WHERE owner_id=v_neighbor;
            WHEN 11 THEN UPDATE public.analysis_jobs SET photo_ids=ARRAY[v_photo] WHERE owner_id=v_neighbor;
            WHEN 12 THEN UPDATE public.analysis_jobs SET photo_ids=ARRAY[v_foreign_photo] WHERE owner_id=v_owner;
            WHEN 13 THEN
                CREATE TABLE public.t013_reference(photo_id uuid REFERENCES public.photo_assets(id));
                INSERT INTO public.t013_reference VALUES(v_photo);
            WHEN 14 THEN
                CREATE TABLE public.t013_reference(photo_id uuid REFERENCES public.photo_assets(id) ON DELETE CASCADE);
                INSERT INTO public.t013_reference VALUES(v_photo);
            WHEN 15 THEN
                CREATE TABLE public.t013_reference(photo_id uuid REFERENCES public.photo_assets(id) ON DELETE SET NULL);
                INSERT INTO public.t013_reference VALUES(v_photo);
            WHEN 16 THEN
                CREATE TABLE public.t013_reference(photo_id uuid REFERENCES public.diagnosis_upload_tickets(photo_asset_id) ON DELETE CASCADE);
                INSERT INTO public.t013_reference VALUES(v_photo);
            WHEN 17 THEN
                INSERT INTO storage.objects(bucket_id,name) VALUES('analysis-inputs',v_owner::text||'/'||v_photo::text);
            WHEN 18 THEN
                ALTER TABLE public.photo_assets ADD COLUMN t013_parent uuid REFERENCES public.plants(id);
                UPDATE public.photo_assets SET t013_parent=v_plant WHERE id=v_photo;
            WHEN 19 THEN
                ALTER TABLE public.photo_assets ADD UNIQUE(id,owner_id);
                CREATE TABLE public.t013_reference(photo_id uuid,owner_id uuid,
                    FOREIGN KEY(photo_id,owner_id) REFERENCES public.photo_assets(id,owner_id) ON DELETE CASCADE);
                INSERT INTO public.t013_reference VALUES(v_photo,v_owner);
            END CASE;
            UPDATE public.account_deletion_requests SET storage_verified_at='2000-01-01 UTC'
                WHERE owner_id=v_owner;
            v_before := pg_temp.analysis_purge_snapshot();
            CREATE TRIGGER t013_predecessor_guard BEFORE DELETE ON public.care_tasks
                FOR EACH ROW EXECUTE FUNCTION pg_temp.reject_care_leaf_purge();
            RETURN NEXT is(public.purge_account_deletion_photo_rows_internal(v_owner,v_operation),false,
                '013 fails before predecessor for malformed graph/proof '||v_case);
            DROP TRIGGER t013_predecessor_guard ON public.care_tasks;
            RETURN NEXT is(pg_temp.analysis_purge_snapshot(),v_before,'013 hold is atomic '||v_case);
            IF v_case BETWEEN 13 AND 16 OR v_case=19 THEN
                RETURN NEXT is((SELECT count(*) FROM public.t013_reference),1::bigint,
                    '013 retains ordinary restrictive/cascade/nulling child');
            END IF;
            RAISE SQLSTATE 'Z1613';
        EXCEPTION WHEN SQLSTATE 'Z1613' THEN NULL;
        END;
    END LOOP;

    -- A nested 012 hold and a late unexpected failure both restore earlier work.
    BEGIN
        UPDATE public.analysis_jobs SET snapshot_id=(
            SELECT id FROM public.condition_snapshots WHERE owner_id=v_owner LIMIT 1)
            WHERE owner_id=v_owner;
        v_before := pg_temp.analysis_purge_snapshot();
        RETURN NEXT is(public.purge_account_deletion_photo_rows_internal(v_owner,v_operation),false,
            '013 respects retained real snapshot input in 012');
        RETURN NEXT is(pg_temp.analysis_purge_snapshot(),v_before,'013 nested hold restores proof and graph');
        RAISE SQLSTATE 'Z1613';
    EXCEPTION WHEN SQLSTATE 'Z1613' THEN NULL;
    END;
    PERFORM public.verify_account_deletion_storage_internal(v_owner,v_operation);
    v_before := pg_temp.analysis_purge_snapshot();
    CREATE TRIGGER t013_reject_photo BEFORE DELETE ON public.photo_assets
        FOR EACH ROW EXECUTE FUNCTION pg_temp.reject_care_leaf_purge();
    RETURN NEXT throws_ok(format(
        'SELECT public.purge_account_deletion_photo_rows_internal(%L::uuid,%L::uuid)',v_owner,v_operation),
        'Z0066','FIXTURE_LEAF_PURGE_FAILURE','013 late error propagates');
    DROP TRIGGER t013_reject_photo ON public.photo_assets;
    RETURN NEXT is(pg_temp.analysis_purge_snapshot(),v_before,'013 late error restores all predecessors');

    -- Compute the complete allowed delta, including duplicate snapshot keys.
    v_expected := v_before;
    FOREACH v_table IN ARRAY ARRAY['care_plans','task_rules','care_tasks','care_entries',
        'care_observations','recovery_transitions','care_reversals','schedule_changes','notification_claims',
        'diagnostic_answers','diagnostic_decisions','analysis_results','condition_snapshots','photo_assets'] LOOP
        SELECT coalesce(jsonb_agg(e.value ORDER BY e.ordinality),'[]'::jsonb) INTO v_rows
            FROM jsonb_array_elements(v_before->v_table) WITH ORDINALITY e(value,ordinality)
            WHERE e.value->>'owner_id'<>v_owner::text;
        v_expected := jsonb_set(v_expected,ARRAY[v_table],v_rows);
    END LOOP;
    FOREACH v_table IN ARRAY ARRAY['diagnosis_upload_tickets','public.diagnosis_upload_tickets',
        'public.first_aid_photo_upload_tickets','public.guest_identification_sources'] LOOP
        SELECT coalesce(jsonb_agg(e.value ORDER BY e.ordinality),'[]'::jsonb) INTO v_rows
            FROM jsonb_array_elements(v_before->v_table) WITH ORDINALITY e(value,ordinality)
            WHERE coalesce(e.value->>'photo_asset_id',e.value->>'photo_id')<>v_photo::text;
        v_expected := jsonb_set(v_expected,ARRAY[v_table],v_rows);
    END LOOP;
    SELECT jsonb_agg(x.value ORDER BY x.value::text) INTO v_rows FROM (
        SELECT CASE WHEN e->>'id'=v_plant::text THEN
            e || '{"main_photo_id":null,"current_condition_snapshot_id":null,"current_snapshot_id":null}'::jsonb
            ELSE e END AS value FROM jsonb_array_elements(v_before->'plants') e) x;
    v_expected := jsonb_set(v_expected,ARRAY['plants'],v_rows);
    SELECT jsonb_agg(x.value ORDER BY x.value::text) INTO v_rows FROM (
        SELECT CASE WHEN e->>'id'=v_draft::text THEN e || '{"photo_id":null}'::jsonb ELSE e END AS value
            FROM jsonb_array_elements(v_before->'public.guest_drafts') e) x;
    v_expected := jsonb_set(v_expected,ARRAY['public.guest_drafts'],v_rows);

    RETURN NEXT is(public.purge_account_deletion_photo_rows_internal(v_owner,v_operation),true,
        '013 purges verified tombstone and supported ownerless leaves after 012');
    RETURN NEXT is(pg_temp.analysis_purge_snapshot(),v_expected,
        '013 exact delta retains jobs, Auth, keys, receipts, ledger and unrelated rows');
    v_before := pg_temp.analysis_purge_snapshot();
    RETURN NEXT is(public.purge_account_deletion_photo_rows_internal(v_owner,v_operation),true,'013 exact replay');
    RETURN NEXT is(pg_temp.analysis_purge_snapshot(),v_before,'013 replay changes nothing');
    BEGIN
        INSERT INTO storage.objects(bucket_id,name) VALUES('analysis-inputs',v_owner::text||'/013-replay');
        v_before := pg_temp.analysis_purge_snapshot();
        RETURN NEXT is(public.purge_account_deletion_photo_rows_internal(v_owner,v_operation),false,
            '013 replay rechecks Storage after photos have gone');
        RETURN NEXT is(pg_temp.analysis_purge_snapshot(),v_before,'013 replay hold retains old evidence');
        RAISE SQLSTATE 'Z1613';
    EXCEPTION WHEN SQLSTATE 'Z1613' THEN NULL;
    END;

    RETURN NEXT ok((SELECT prosecdef AND provolatile='v' AND proconfig=ARRAY['search_path=""']
        FROM pg_proc WHERE oid='public.purge_account_deletion_photo_rows_internal(uuid,uuid)'::regprocedure),
        '013 private volatile definer has empty search path');
    RETURN NEXT ok(NOT EXISTS (
        SELECT 1 FROM pg_proc p CROSS JOIN LATERAL
            aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) a
        WHERE p.oid='public.purge_account_deletion_photo_rows_internal(uuid,uuid)'::regprocedure
            AND a.grantee<>p.proowner),'013 grants no nonowner execution');
    FOREACH v_role IN ARRAY ARRAY['anon','authenticated','service_role'] LOOP
        v_denied := false;
        BEGIN
            EXECUTE format('SET LOCAL ROLE %I',v_role);
            PERFORM public.purge_account_deletion_photo_rows_internal(v_owner,v_operation);
        EXCEPTION WHEN insufficient_privilege THEN v_denied := true;
        END;
        RESET ROLE;
        RETURN NEXT ok(v_denied,'013 actual execution denied for '||v_role);
    END LOOP;
    RAISE SQLSTATE 'Z1613';
EXCEPTION WHEN SQLSTATE 'Z1613' THEN RETURN;
END;
$$;

CREATE FUNCTION pg_temp.care_plan_purge_tests() RETURNS SETOF text LANGUAGE plpgsql AS $$
DECLARE
    v_a uuid := 'a0040000-0000-4000-8000-000000000001';
    v_b uuid := 'a0040000-0000-4000-8000-000000000002';
    v_owner uuid;
    v_neighbor uuid;
    v_operation uuid;
    v_release uuid;
    v_plant uuid;
    v_snapshot uuid;
    v_photo uuid;
    v_job uuid;
    v_result uuid;
    v_decision uuid;
    v_recovery uuid;
    v_routine uuid;
    v_rule uuid;
    v_task uuid;
    v_entry uuid;
    v_observation uuid;
    v_target uuid;
    v_before jsonb;
    v_expected jsonb;
    v_rows jsonb;
    v_edge record;
    v_table text;
    v_role text;
    v_denied boolean;
BEGIN
    IF to_regprocedure('public.purge_account_deletion_care_plans_internal(uuid,uuid)') IS NULL THEN
        RETURN QUERY SELECT skip('004 plan purge is outside selected migration version',1);
        RETURN;
    END IF;
    RETURN NEXT is((SELECT array_agg(c.relname||'.'||a.attname ORDER BY c.relname,a.attname)
        FROM pg_constraint f JOIN pg_class c ON c.oid=f.conrelid
        JOIN pg_attribute a ON a.attrelid=c.oid AND a.attnum=f.conkey[1]
        WHERE f.contype='f' AND f.confrelid='public.care_plans'::regclass),
        ARRAY['recovery_transitions.recovery_plan_id','recovery_transitions.routine_plan_id',
              'task_rules.plan_id']::text[],'all actual incoming plan FK edges are covered');
    INSERT INTO auth.users(id,is_anonymous,created_at) VALUES
        (v_a,false,clock_timestamp()),(v_b,false,clock_timestamp());
    INSERT INTO public.kb_releases(version,state) VALUES('t083-plans-004','draft')
        RETURNING id INTO v_release;
    FOREACH v_owner IN ARRAY ARRAY[v_a,v_b] LOOP
        INSERT INTO public.plants(owner_id,personal_name,creation_source)
        VALUES(v_owner,'Plan purge fixture','identification') RETURNING id INTO v_plant;
        INSERT INTO public.condition_snapshots(owner_id,plant_id)
        VALUES(v_owner,v_plant) RETURNING id INTO v_snapshot;
        v_photo := gen_random_uuid();
        INSERT INTO public.photo_assets(id,owner_id,plant_id,purpose,original_key,content_hash)
        VALUES(v_photo,v_owner,v_plant,'initial',v_owner::text||'/'||v_photo::text,repeat('a',64));
        INSERT INTO public.diagnosis_upload_tickets(photo_asset_id,mime_type,byte_size,expires_at)
        VALUES(v_photo,'image/jpeg',4,clock_timestamp()-interval '1 day');
        INSERT INTO public.analysis_jobs(owner_id,flow_id,intent,add_method,plant_id,mode,
            kb_release_id,prompt_version,operation_id,payload_hash,locale,snapshot_id,
            quota_kind,quota_state,state)
        VALUES(v_owner,gen_random_uuid(),'problem','scan',v_plant,'diagnosis',v_release,
            'fixture',gen_random_uuid(),'fixture','en',v_snapshot,'none','not_applicable','succeeded')
            RETURNING id INTO v_job;
        INSERT INTO public.analysis_results(origin_analysis_id,mode,job_id,origin_job_id,
            owner_id,plant_id,source_photo_id,source_snapshot_id,locale,kb_release_id,
            classification,identification,result_hash,analysis_receipt)
        VALUES(gen_random_uuid(),'diagnosis',v_job,v_job,v_owner,v_plant,v_photo,v_snapshot,
            'en',v_release,'{}','{}','fixture','fixture') RETURNING id INTO v_result;
        v_decision := gen_random_uuid();
        INSERT INTO public.diagnostic_decisions(id,revision,analysis_result_id,owner_id,
            kb_release_id,policy_version,context_revision,original_candidates,decision_scores,
            state,decision_receipt)
        VALUES(v_decision,1,v_result,v_owner,v_release,'fixture',1,'[]','{}','resolved','fixture');
        INSERT INTO public.diagnostic_answers(decision_id,question_id,answer_revision,answer,
            operation_id,owner_id)
        VALUES(v_decision,'fixture',1,'yes',gen_random_uuid(),v_owner);
        INSERT INTO public.care_plans(owner_id,plant_id,operation_id,locale,plan_kind,access_tier,
            source_kind,snapshot_id,kb_release_id,context_revision,full_body,
            diagnostic_decision_id,diagnostic_decision_revision,source_analysis_id,source_photo_id)
        VALUES(v_owner,v_plant,gen_random_uuid(),'en','recovery','full','analysis',v_snapshot,
            v_release,1,'{}',v_decision,1,v_result,v_photo) RETURNING id INTO v_recovery;
        INSERT INTO public.care_plans(owner_id,plant_id,operation_id,locale,plan_kind,access_tier,
            source_kind,snapshot_id,kb_release_id,context_revision,full_body,deleted_at)
        VALUES(v_owner,v_plant,gen_random_uuid(),'pl','routine','basic','catalogue',v_snapshot,
            v_release,1,'{}',clock_timestamp()) RETURNING id INTO v_routine;
        INSERT INTO public.task_rules(owner_id,plant_id,plan_id,access_class,action_code,
            condition_code,interval_days)
        VALUES(v_owner,v_plant,v_recovery,'premium','water','fixture',1) RETURNING id INTO v_rule;
        INSERT INTO public.care_tasks(owner_id,plant_id,rule_id,occurrence_key,action_code,due_local_date)
        VALUES(v_owner,v_plant,v_rule,'plan-fixture','water',current_date) RETURNING id INTO v_task;
        INSERT INTO public.care_entries(owner_id,plant_id,task_id,action_code,occurred_at,
            occurred_local_date,timezone,operation_id)
        VALUES(v_owner,v_plant,v_task,'water',clock_timestamp(),current_date,'UTC',gen_random_uuid())
            RETURNING id INTO v_entry;
        UPDATE public.care_tasks SET completed_entry_id=v_entry WHERE id=v_task;
        INSERT INTO public.care_observations(owner_id,plant_id,task_id,status_code,operation_id)
        VALUES(v_owner,v_plant,v_task,'improved',gen_random_uuid()) RETURNING id INTO v_observation;
        INSERT INTO public.recovery_transitions(owner_id,plant_id,recovery_plan_id,routine_plan_id,
            observation_id,expected_care_revision,operation_id,state)
        VALUES(v_owner,v_plant,v_recovery,v_routine,v_observation,1,gen_random_uuid(),'confirmed');
        INSERT INTO public.care_reversals(owner_id,entry_id,operation_id)
        VALUES(v_owner,v_entry,gen_random_uuid());
        INSERT INTO public.schedule_changes(owner_id,plant_id,to_date,cause_code,explanation_code)
        VALUES(v_owner,v_plant,current_date,'fixture','fixture');
        v_before := pg_temp.care_plan_snapshot();
        RETURN NEXT is(public.purge_account_deletion_care_plans_internal(v_owner,gen_random_uuid()),false,
            'active owner cannot purge plans');
        RETURN NEXT is(pg_temp.care_plan_snapshot(),v_before,'active owner graph unchanged');
        PERFORM public.request_account_deletion_internal(v_owner,gen_random_uuid());
    END LOOP;

    RETURN QUERY SELECT * FROM pg_temp.photo_row_purge_tests(v_a,v_b);
    RETURN QUERY SELECT * FROM pg_temp.photo_row_purge_tests(v_b,v_a);
    RETURN QUERY SELECT * FROM pg_temp.snapshot_purge_tests(v_a,v_b);
    RETURN QUERY SELECT * FROM pg_temp.snapshot_purge_tests(v_b,v_a);
    RETURN QUERY SELECT * FROM pg_temp.analysis_purge_tests(v_a,v_b);
    RETURN QUERY SELECT * FROM pg_temp.analysis_purge_tests(v_b,v_a);

    -- Both directions are tested before either canonical graph is removed.
    FOREACH v_owner IN ARRAY ARRAY[v_a,v_b] LOOP
        v_neighbor := CASE WHEN v_owner=v_a THEN v_b ELSE v_a END;
        RETURN QUERY SELECT * FROM pg_temp.diagnostic_purge_tests(v_owner,v_neighbor);
        SELECT operation_id INTO v_operation FROM public.account_deletion_requests WHERE owner_id=v_owner;
        v_before := pg_temp.care_plan_snapshot();
        RETURN NEXT is(public.purge_account_deletion_care_plans_internal(v_owner,gen_random_uuid()),false,
            'mismatched request cannot purge plans');
        RETURN NEXT is(public.purge_account_deletion_care_plans_internal(NULL,v_operation),false,
            'null owner rejected');
        RETURN NEXT is(public.purge_account_deletion_care_plans_internal(v_owner,NULL),false,
            'null operation rejected');
        RETURN NEXT is(pg_temp.care_plan_snapshot(),v_before,'invalid requests leave no evidence or changes');
        BEGIN
            UPDATE public.operation_receipts SET payload_hash='forged'
                WHERE owner_id=v_owner AND operation_id=v_operation;
            v_before := pg_temp.care_plan_snapshot();
            RETURN NEXT is(public.purge_account_deletion_care_plans_internal(v_owner,v_operation),false,
                'forged receipt holds plans');
            RETURN NEXT is(pg_temp.care_plan_snapshot(),v_before,'receipt hold is atomic');
            RAISE SQLSTATE 'Z1604';
        EXCEPTION WHEN SQLSTATE 'Z1604' THEN NULL;
        END;

        FOR v_edge IN SELECT * FROM (VALUES
            ('task_rules','plan_id','care_plans','recovery'),
            ('recovery_transitions','recovery_plan_id','care_plans','recovery'),
            ('recovery_transitions','routine_plan_id','care_plans','routine'),
            ('care_tasks','rule_id','task_rules',NULL)
        ) AS edges(child_table,child_column,parent_table,plan_kind) LOOP
            BEGIN
                IF v_edge.parent_table='care_plans' THEN
                    SELECT id INTO v_target FROM public.care_plans
                        WHERE owner_id=v_owner AND plan_kind=v_edge.plan_kind;
                ELSE
                    SELECT id INTO v_target FROM public.task_rules WHERE owner_id=v_owner;
                END IF;
                EXECUTE format('UPDATE public.%I SET %I=$1,deleted_at=clock_timestamp() WHERE owner_id=$2',
                    v_edge.child_table,v_edge.child_column) USING v_target,v_neighbor;
                v_before := pg_temp.care_plan_snapshot();
                RETURN NEXT is(public.purge_account_deletion_care_plans_internal(v_owner,v_operation),false,
                    'foreign historical FK holds plans: '||v_edge.child_table||'.'||v_edge.child_column);
                RETURN NEXT is(pg_temp.care_plan_snapshot(),v_before,
                    'FK hold rolls back verification and retains both graphs');
                PERFORM public.verify_account_deletion_storage_internal(v_owner,v_operation);
                v_before := pg_temp.care_plan_snapshot();
                RETURN NEXT is(public.purge_account_deletion_care_plans_internal(v_owner,v_operation),false,
                    'saved Storage proof cannot bypass foreign FK');
                RETURN NEXT is(pg_temp.care_plan_snapshot(),v_before,'saved evidence retained on FK hold');
                RAISE SQLSTATE 'Z1604';
            EXCEPTION WHEN SQLSTATE 'Z1604' THEN NULL;
            END;
        END LOOP;
        BEGIN
            SELECT id INTO v_target FROM public.care_tasks WHERE owner_id=v_owner;
            UPDATE public.care_entries SET state='voided',task_id=v_target WHERE owner_id=v_neighbor;
            v_before := pg_temp.care_plan_snapshot();
            RETURN NEXT is(public.purge_account_deletion_care_plans_internal(v_owner,v_operation),false,
                'nested 067 journal hold prevents plan removal');
            RETURN NEXT is(pg_temp.care_plan_snapshot(),v_before,'nested hold rolls back outer verification');
            RAISE SQLSTATE 'Z1604';
        EXCEPTION WHEN SQLSTATE 'Z1604' THEN NULL;
        END;

        v_before := pg_temp.care_plan_snapshot();
        CREATE TRIGGER t004_reject_plan BEFORE DELETE ON public.care_plans
            FOR EACH ROW EXECUTE FUNCTION pg_temp.reject_care_leaf_purge();
        RETURN NEXT throws_ok(format('SELECT public.purge_account_deletion_care_plans_internal(%L::uuid,%L::uuid)',
            v_owner,v_operation),'Z0066','FIXTURE_LEAF_PURGE_FAILURE','late plan error propagates');
        DROP TRIGGER t004_reject_plan ON public.care_plans;
        RETURN NEXT is(pg_temp.care_plan_snapshot(),v_before,
            'late plan error restores journal, leaves, cascades and verification');

        PERFORM public.verify_account_deletion_storage_internal(v_owner,v_operation);
        INSERT INTO storage.objects(bucket_id,name) VALUES('analysis-inputs',v_owner::text||'/plan-hold');
        v_before := pg_temp.care_plan_snapshot();
        RETURN NEXT is(public.purge_account_deletion_care_plans_internal(v_owner,v_operation),false,
            'stale proof cannot bypass live Storage recheck');
        RETURN NEXT is(pg_temp.care_plan_snapshot(),v_before,'Storage hold changes no data or evidence');
        DELETE FROM storage.objects WHERE bucket_id='analysis-inputs' AND name=v_owner::text||'/plan-hold';
    END LOOP;

    FOREACH v_owner IN ARRAY ARRAY[v_a,v_b] LOOP
        SELECT operation_id INTO v_operation FROM public.account_deletion_requests WHERE owner_id=v_owner;
        PERFORM public.verify_account_deletion_storage_internal(v_owner,v_operation);
        v_before := pg_temp.care_plan_snapshot();
        v_expected := v_before;
        FOREACH v_table IN ARRAY ARRAY['care_plans','task_rules','care_tasks','care_entries',
            'care_observations','recovery_transitions','care_reversals','schedule_changes','notification_claims'] LOOP
            SELECT coalesce(jsonb_agg(e.value ORDER BY e.ordinality),'[]'::jsonb) INTO v_rows
                FROM jsonb_array_elements(v_before->v_table) WITH ORDINALITY e(value,ordinality)
                WHERE e.value->>'owner_id'<>v_owner::text;
            v_expected := jsonb_set(v_expected,ARRAY[v_table],v_rows);
        END LOOP;
        RETURN NEXT is(public.purge_account_deletion_care_plans_internal(v_owner,v_operation),true,
            'verified owner journal then plans are removed');
        RETURN NEXT is(pg_temp.care_plan_snapshot(),v_expected,
            'only owner journal/plans and cascaded rules removed; decisions, receipts and neighbors retained');
        v_before := pg_temp.care_plan_snapshot();
        RETURN NEXT is(public.purge_account_deletion_care_plans_internal(v_owner,v_operation),true,
            'exact successful replay accepted');
        RETURN NEXT is(pg_temp.care_plan_snapshot(),v_before,'exact replay changes nothing');
        INSERT INTO storage.objects(bucket_id,name) VALUES('analysis-inputs',v_owner::text||'/plan-replay');
        v_before := pg_temp.care_plan_snapshot();
        RETURN NEXT is(public.purge_account_deletion_care_plans_internal(v_owner,v_operation),false,
            'reappearing object holds successful replay');
        RETURN NEXT is(pg_temp.care_plan_snapshot(),v_before,'replay Storage hold is atomic');
        DELETE FROM storage.objects WHERE bucket_id='analysis-inputs' AND name=v_owner::text||'/plan-replay';
    END LOOP;

    RETURN NEXT ok(EXISTS (SELECT 1 FROM pg_proc
        WHERE oid='public.purge_account_deletion_care_plans_internal(uuid,uuid)'::regprocedure
          AND prosecdef AND provolatile='v' AND proconfig @> ARRAY['search_path=""']),
        'plan function is volatile SECURITY DEFINER with empty search path');
    RETURN NEXT ok(NOT EXISTS (SELECT 1 FROM pg_proc p,
        LATERAL aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) a
        WHERE p.oid='public.purge_account_deletion_care_plans_internal(uuid,uuid)'::regprocedure
          AND a.grantee<>p.proowner),'plan function strips all nonowner grants');
    FOREACH v_role IN ARRAY ARRAY['anon','authenticated','service_role'] LOOP
        v_denied := false;
        BEGIN
            EXECUTE format('SET LOCAL ROLE %I',v_role);
            PERFORM public.purge_account_deletion_care_plans_internal(v_owner,v_operation);
        EXCEPTION WHEN insufficient_privilege THEN v_denied := true;
        END;
        RESET ROLE;
        RETURN NEXT ok(v_denied,'actual plan execution denied for '||v_role);
    END LOOP;
    SELECT pg_get_userbyid(proowner) INTO v_role FROM pg_proc
        WHERE oid='public.purge_account_deletion_care_plans_internal(uuid,uuid)'::regprocedure;
    EXECUTE format('SET LOCAL ROLE %I',v_role);
    RETURN NEXT is(public.purge_account_deletion_care_plans_internal(v_owner,v_operation),true,
        'SQL function owner can replay plan purge');
    RESET ROLE;
END;
$$;
SELECT * FROM pg_temp.care_plan_purge_tests();

SELECT * FROM finish();
ROLLBACK;
