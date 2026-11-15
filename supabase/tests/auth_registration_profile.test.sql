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

SELECT * FROM finish();
ROLLBACK;
