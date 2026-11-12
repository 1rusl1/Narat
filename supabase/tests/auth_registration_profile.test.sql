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

SELECT * FROM finish();
ROLLBACK;
