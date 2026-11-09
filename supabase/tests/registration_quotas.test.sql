-- Real current-schema RPCs/constraints; synthetic fixtures only.
-- The controller also compares all original public rows across forward upgrade.
BEGIN;
SELECT plan(49);

CREATE TEMP TABLE ledger_ids AS
SELECT n, ('16320000-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid AS id
FROM generate_series(1, 300) n;
GRANT SELECT ON ledger_ids TO service_role;

INSERT INTO public.profiles(id, anonymous, created_at)
SELECT id, n = 3, '2026-01-31 10:20Z'::timestamptz
FROM ledger_ids WHERE n IN (1, 2, 3, 4, 6, 7);
UPDATE public.profiles SET account_state = 'deleting' WHERE id = (SELECT id FROM ledger_ids WHERE n = 4);
-- Emulate a PRE-005 permanent profile with no verified registration evidence.
-- Restore the real trigger before any RPC assertion; all fixture DDL rolls back.
ALTER TABLE public.profiles DISABLE TRIGGER trg_profiles_registration_anchor;
INSERT INTO public.profiles(id, anonymous, created_at)
SELECT id, false, '2020-01-01 00:00Z'::timestamptz FROM ledger_ids WHERE n = 5;
ALTER TABLE public.profiles ENABLE TRIGGER trg_profiles_registration_anchor;
INSERT INTO public.account_quota_anchors(owner_id, registered_at, source)
SELECT id, NULL, 'unresolved' FROM ledger_ids WHERE n = 5;

-- Historical jobs may reference a retired release. Keep the gate's published
-- release intact and respect the single-published-release unique index.
INSERT INTO public.kb_releases(id, version, state, manifest_sha256, published_at)
SELECT id, 'ledger-fixture', 'retired', repeat('a', 64), '2026-01-01 00:00Z'::timestamptz
FROM ledger_ids WHERE n = 100;

CREATE TEMP TABLE ledger_quota_fixture(n int, owner_n int, kind text, start_at timestamptz,
                                       consumed int, reserved int);
INSERT INTO ledger_quota_fixture VALUES
(101,1,'paid_monthly','2026-03-01 00:00Z',7,2),
(102,1,'free_monthly','2026-03-01 00:00Z',1,0),
(103,1,'paid_monthly','2026-02-01 00:00Z',1,0),
(104,2,'paid_monthly','2026-03-01 00:00Z',1,0),
(105,5,'paid_monthly','2026-03-01 00:00Z',3,1),
(106,6,'paid_monthly','2026-03-01 00:00Z',0,0),
(107,6,'paid_monthly','2026-04-01 00:00Z',2,1),
(108,7,'paid_monthly','2026-03-01 00:00Z',1,0);
INSERT INTO public.monthly_quotas(id, owner_id, quota_kind, period_start, period_end,
                                  limit_count, consumed_count, reserved_count)
SELECT qi.id, oi.id, f.kind, f.start_at,
       ((f.start_at AT TIME ZONE 'UTC') + interval '1 month') AT TIME ZONE 'UTC',
       CASE WHEN f.kind = 'free_monthly' THEN 1 ELSE 100 END, f.consumed, f.reserved
FROM ledger_quota_fixture f JOIN ledger_ids qi ON qi.n = f.n
JOIN ledger_ids oi ON oi.n = f.owner_n;

CREATE TEMP TABLE ledger_job_fixture(n int, owner_n int, mode text, kind text, quota_state text,
                                     quota_n int, reserve_at timestamptz, quota_owner_n int);
INSERT INTO ledger_job_fixture VALUES
(201,1,'diagnosis','paid_monthly','consumed',101,'2026-03-15 00:00Z',1),
(202,1,'identification','paid_monthly','reserved',101,'2026-03-15 00:00Z',1),
(203,1,'diagnosis','free_monthly','consumed',102,'2026-03-15 00:00Z',1),
(204,1,'follow_up','paid_monthly','consumed',103,'2026-02-10 00:00Z',1),
(205,1,'identification','starter_identification','consumed',NULL,'2026-03-15 00:00Z',1),
(206,1,'plan','none','not_applicable',NULL,'2026-03-15 00:00Z',NULL),
(207,1,'diagnosis','paid_monthly','released',101,'2026-03-15 00:00Z',1),
(208,1,'diagnosis','paid_monthly','consumed',NULL,'2026-03-15 00:00Z',NULL),
(209,1,'diagnosis','paid_monthly','reserved',101,'2026-03-15 00:00Z',1),
(211,2,'diagnosis','paid_monthly','consumed',104,'2026-03-15 00:00Z',2),
(215,5,'diagnosis','paid_monthly','consumed',105,'2026-03-15 00:00Z',5),
(216,6,'diagnosis','paid_monthly','consumed',106,'2026-03-15 00:00Z',6),
(217,6,'diagnosis','paid_monthly','consumed',107,'-infinity',6),
(218,6,'diagnosis','paid_monthly','reserved',107,'2026-03-15 00:00Z',2),
(219,6,'diagnosis','paid_monthly','consumed',107,'2026-01-01 00:00Z',6),
(220,2,'diagnosis','paid_monthly','consumed',107,'2026-03-15 00:00Z',2),
(221,7,'diagnosis','paid_monthly','consumed',108,'2026-03-15 00:00Z',7);
INSERT INTO public.analysis_jobs(
    id, owner_id, flow_id, intent, add_method, mode, kb_release_id, prompt_version,
    operation_id, payload_hash, locale, quota_kind, quota_state, quota_owner_id,
    monthly_quota_id, state, lease_token, provider_started_at, created_at, deadline_at, updated_at
)
SELECT ji.id, oi.id, ji.id, 'problem', 'scan', f.mode, ki.id, 'fixture', ji.id,
       repeat('b',64), 'en', f.kind, f.quota_state, qoi.id, qi.id,
       CASE f.quota_state WHEN 'reserved' THEN 'running' WHEN 'released' THEN 'failed' ELSE 'succeeded' END,
       CASE WHEN f.quota_state = 'reserved' THEN ji.id END,
       CASE WHEN f.mode <> 'plan' THEN '2026-03-15 00:00Z'::timestamptz END,
       f.reserve_at, '2026-03-15 00:00:55Z'::timestamptz, '2026-03-15 00:00Z'::timestamptz
FROM ledger_job_fixture f JOIN ledger_ids ji ON ji.n = f.n
JOIN ledger_ids oi ON oi.n = f.owner_n JOIN ledger_ids ki ON ki.n = 100
LEFT JOIN ledger_ids qi ON qi.n = f.quota_n LEFT JOIN ledger_ids qoi ON qoi.n = f.quota_owner_n;
UPDATE public.profiles SET starter_identification_consumed = true,
    starter_identification_job_id = (SELECT id FROM ledger_ids WHERE n = 205)
WHERE id = (SELECT id FROM ledger_ids WHERE n = 1);
INSERT INTO public.operation_receipts(owner_id, operation_id, command_name, payload_hash, response_payload)
SELECT oi.id, ji.id, 'analysis.start', repeat('b',64), jsonb_build_object('job_id',ji.id,'receipt','fixture-signed')
FROM ledger_ids oi CROSS JOIN ledger_ids ji WHERE oi.n = 1 AND ji.n = 201;

-- Snapshot every pre-005 public table, including history/receipts/budget/cap state.
DO $snapshot$
DECLARE v_query text;
BEGIN
    SELECT string_agg(format(
        'SELECT %L AS name, COALESCE(jsonb_agg(to_jsonb(t) ORDER BY to_jsonb(t)::text), ''[]''::jsonb) AS table_rows FROM public.%I t',
        tablename, tablename), ' UNION ALL ' ORDER BY tablename)
    INTO v_query FROM pg_tables WHERE schemaname = 'public'
      AND tablename NOT IN ('account_quota_usage','quota_legacy_reconciliation','account_quota_anchors');
    EXECUTE 'CREATE TEMP VIEW ledger_original_state AS SELECT jsonb_object_agg(name,table_rows) AS data FROM ('
        || v_query || ') s';
END;
$snapshot$;
CREATE TEMP TABLE ledger_original_before AS SELECT data FROM ledger_original_state;

SELECT ok((SELECT bool_and(relrowsecurity) FROM pg_class WHERE oid IN (
    'public.account_quota_usage'::regclass, 'public.quota_legacy_reconciliation'::regclass)),
    'Both private tables enable RLS');
SELECT ok(NOT EXISTS (
    SELECT 1 FROM (VALUES ('anon'),('authenticated')) roles(name)
    CROSS JOIN (VALUES ('public.account_quota_usage'),('public.quota_legacy_reconciliation')) tables(name)
    WHERE has_table_privilege(roles.name,tables.name,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')
), 'Clients have no grants on either table');
SELECT ok((SELECT prosecdef AND proconfig @> ARRAY['search_path=""'] FROM pg_proc
    WHERE oid = 'public.reconcile_registration_quota(uuid)'::regprocedure),
    'Reconciliation is a definer with pinned empty search_path');
SELECT ok(NOT EXISTS (
    SELECT 1 FROM pg_proc p,
    LATERAL aclexplode(COALESCE(p.proacl,acldefault('f',p.proowner))) a
    WHERE p.oid = 'public.reconcile_registration_quota(uuid)'::regprocedure
      AND a.grantee IN (0,'anon'::regrole::oid,'authenticated'::regrole::oid)
      AND a.privilege_type = 'EXECUTE'
), 'PUBLIC and clients cannot execute reconciliation');
SELECT ok(has_function_privilege('service_role','public.reconcile_registration_quota(uuid)','EXECUTE'),
    'Service role can reconcile');
SELECT throws_ok($$SELECT public.reconcile_registration_quota('16320000-0000-4000-8000-000000000099')$$,
    'P0002','OWNER_NOT_FOUND','Missing owner rejected');
SELECT throws_ok($$SELECT public.reconcile_registration_quota('16320000-0000-4000-8000-000000000003')$$,
    '42501','ACTIVE_PERMANENT_OWNER_REQUIRED','Anonymous owner rejected');
SELECT throws_ok($$SELECT public.reconcile_registration_quota('16320000-0000-4000-8000-000000000004')$$,
    '42501','ACTIVE_PERMANENT_OWNER_REQUIRED','Inactive owner rejected');

SET LOCAL ROLE service_role;
SELECT lives_ok($$SELECT public.reconcile_registration_quota('16320000-0000-4000-8000-000000000001')$$,
    'Real service-only import succeeds');
SELECT throws_ok($$DELETE FROM public.account_quota_usage$$,
    '42501',NULL,'Service cannot delete usage directly to refill');
RESET ROLE;
SELECT is((SELECT count(*) FROM public.account_quota_usage WHERE owner_id = (SELECT id FROM ledger_ids WHERE n=1)),
    7::bigint,'Known monthly jobs are imported once');
SELECT results_eq(
    $$SELECT u.quota_state FROM public.account_quota_usage u JOIN ledger_ids i ON i.id=u.job_id WHERE i.n IN (201,202) ORDER BY i.n$$,
    $$VALUES ('consumed'::text),('reserved'::text)$$,
    'Known consumed and running reserved jobs retain their quota states');
SELECT ok((SELECT bool_and(period_start='2026-02-28 10:20Z'::timestamptz
    AND period_end='2026-03-31 10:20Z'::timestamptz) FROM public.account_quota_usage
    WHERE job_id IN (SELECT id FROM ledger_ids WHERE n IN (201,202,203))),
    'Free and paid map reserve instants into one registration window');
SELECT is((SELECT count(*) FROM public.account_quota_usage WHERE owner_id=(SELECT id FROM ledger_ids WHERE n=1)
    AND period_start='2026-02-28 10:20Z' AND quota_state='consumed'),3::bigint,
    'Free and paid consumption shares the same ledger');
SELECT ok((SELECT period_start='2026-01-31 10:20Z'::timestamptz
    AND period_end='2026-02-28 10:20Z'::timestamptz FROM public.account_quota_usage
    WHERE job_id=(SELECT id FROM ledger_ids WHERE n=204)),
    'Historical monthly follow_up retains its old window');
SELECT is((SELECT count(*) FROM public.account_quota_usage WHERE job_id IN (
    SELECT id FROM ledger_ids WHERE n IN (205,206))),0::bigint,'Starter and plan are excluded');
SELECT ok((SELECT legacy_quota_id IS NULL FROM public.account_quota_usage
    WHERE job_id=(SELECT id FROM ledger_ids WHERE n=208)),
    'A known monthly job without a legacy pointer still has one charge');
SELECT results_eq(
    $$SELECT r.unallocated_consumed,r.unallocated_reserved,r.requires_review FROM public.quota_legacy_reconciliation r JOIN ledger_ids i ON i.id=r.monthly_quota_id WHERE i.n IN (101,102,103) ORDER BY i.n$$,
    $$VALUES (6,0,true),(0,0,false),(0,0,false)$$,
    'Only leftovers remain; complete old/free aggregates do not need review');
SELECT is((SELECT count(*) FROM public.account_quota_usage WHERE legacy_quota_id=(SELECT id FROM ledger_ids WHERE n=101)
    AND quota_state='consumed') + (SELECT unallocated_consumed FROM public.quota_legacy_reconciliation
    WHERE monthly_quota_id=(SELECT id FROM ledger_ids WHERE n=101)),
    7::bigint,'Ledger plus residual equals original consumption, without double counting');
SELECT ok(NOT EXISTS (SELECT 1 FROM public.account_quota_usage WHERE owner_id=(SELECT id FROM ledger_ids WHERE n=2))
    AND NOT EXISTS (SELECT 1 FROM public.quota_legacy_reconciliation WHERE monthly_quota_id=(SELECT id FROM ledger_ids WHERE n=104)),
    'Reconciling A does not import or reconcile B');
SELECT is((SELECT data FROM ledger_original_state),(SELECT data FROM ledger_original_before),
    'Import preserves all original rows, counters, pointers, leases and receipts');

CREATE TEMP VIEW ledger_import_state AS
SELECT jsonb_build_object(
    'usage',(SELECT COALESCE(jsonb_agg(to_jsonb(u) ORDER BY job_id),'[]'::jsonb) FROM public.account_quota_usage u),
    'residual',(SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY monthly_quota_id),'[]'::jsonb) FROM public.quota_legacy_reconciliation r)
) AS data;
CREATE TEMP TABLE ledger_import_before AS SELECT data FROM ledger_import_state;
DO $$BEGIN PERFORM public.reconcile_registration_quota('16320000-0000-4000-8000-000000000001'); END$$;
SELECT is((SELECT data FROM ledger_import_state),(SELECT data FROM ledger_import_before),
    'Second import is byte-for-byte identical');

SELECT is(public.reconcile_registration_quota('16320000-0000-4000-8000-000000000005'),
    '{"registration_required":true,"requires_review":true}'::jsonb,
    'Unknown legacy anchor stays explicit and fails closed');
SELECT ok((SELECT registered_at IS NULL AND source='unresolved' FROM public.account_quota_anchors
    WHERE owner_id=(SELECT id FROM ledger_ids WHERE n=5)), 'Reconcile never invents registration evidence');
SELECT is((SELECT count(*) FROM public.account_quota_usage WHERE owner_id=(SELECT id FROM ledger_ids WHERE n=5)),
    0::bigint,'Unknown anchor is never mapped into the current month');
SELECT ok((SELECT unallocated_consumed=3 AND unallocated_reserved=1 AND requires_review
    FROM public.quota_legacy_reconciliation WHERE monthly_quota_id=(SELECT id FROM ledger_ids WHERE n=105)),
    'Unknown legacy usage remains explicit in full');
CREATE TEMP TABLE ledger_unknown_before AS SELECT data FROM ledger_import_state;
DO $$BEGIN PERFORM public.reconcile_registration_quota('16320000-0000-4000-8000-000000000005'); END$$;
SELECT is((SELECT data FROM ledger_import_state),(SELECT data FROM ledger_unknown_before),
    'Retry of unknown history is identical');
SELECT lives_ok($$SELECT public.set_registration_quota_anchor('16320000-0000-4000-8000-000000000005','2026-01-31 10:20Z','fixture verified registration');
    SELECT public.reconcile_registration_quota('16320000-0000-4000-8000-000000000005')$$,
    'Explicit verified anchor enables a later import');
SELECT ok((SELECT count(*)=1 FROM public.account_quota_usage WHERE owner_id=(SELECT id FROM ledger_ids WHERE n=5))
    AND (SELECT unallocated_consumed=2 AND unallocated_reserved=1 AND requires_review
         FROM public.quota_legacy_reconciliation WHERE monthly_quota_id=(SELECT id FROM ledger_ids WHERE n=105)),
    'Verified import replaces attribution, without adding full counters twice');

SELECT lives_ok($$SELECT public.reconcile_registration_quota('16320000-0000-4000-8000-000000000006')$$,
    'Contradictory history is retained for review');
SELECT is((SELECT count(*) FROM public.account_quota_usage WHERE owner_id=(SELECT id FROM ledger_ids WHERE n=6)),
    1::bigint,'Only the mappable job is imported from contradictory history');
SELECT ok((SELECT unallocated_consumed=0 AND unallocated_reserved=0 AND requires_review
    FROM public.quota_legacy_reconciliation WHERE monthly_quota_id=(SELECT id FROM ledger_ids WHERE n=106)),
    'Smaller stored counters flag contradiction without losing the known job');
SELECT ok((SELECT unallocated_consumed=2 AND unallocated_reserved=1 AND requires_review
    FROM public.quota_legacy_reconciliation WHERE monthly_quota_id=(SELECT id FROM ledger_ids WHERE n=107)),
    'Infinite/pre-registration timestamps and owner mismatch retain residuals and review flag');
SELECT is((SELECT count(*) FROM public.account_quota_usage WHERE job_id IN (
    SELECT id FROM ledger_ids WHERE n IN (217,218,219,220))),0::bigint,
    'Unmappable timestamps and foreign owner jobs receive no fabricated window');
SELECT is((SELECT data FROM ledger_original_state),(SELECT data FROM ledger_original_before),
    'Unknown/verified/contradictory imports leave every original public row unchanged');

-- Simulate the next slice settling ledger rows while legacy source states remain.
UPDATE public.account_quota_usage SET quota_state=CASE WHEN job_id=(SELECT id FROM ledger_ids WHERE n=202)
    THEN 'released' ELSE 'consumed' END WHERE job_id IN (SELECT id FROM ledger_ids WHERE n IN (202,209));
CREATE TEMP TABLE ledger_terminal_before AS SELECT data FROM ledger_import_state;
DO $$BEGIN PERFORM public.reconcile_registration_quota('16320000-0000-4000-8000-000000000001'); END$$;
SELECT results_eq(
    $$SELECT u.quota_state FROM public.account_quota_usage u JOIN ledger_ids i ON i.id=u.job_id WHERE i.n IN (202,209) ORDER BY i.n$$,
    $$VALUES ('released'::text),('consumed'::text)$$,
    'Reimport cannot reinstate either terminal reservation');
SELECT ok((SELECT unallocated_reserved=0 AND unallocated_consumed=6 FROM public.quota_legacy_reconciliation
    WHERE monthly_quota_id=(SELECT id FROM ledger_ids WHERE n=101)),
    'Terminal ledger transitions cannot refill residual reserve');
SELECT is((SELECT data FROM ledger_import_state),(SELECT data FROM ledger_terminal_before),
    'Reimport after terminal settlement changes no ledger or residual row');
SELECT is((SELECT data FROM ledger_original_state),(SELECT data FROM ledger_original_before),
    'Terminal reimport preserves original source job states and reserved counters');

SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub = '16320000-0000-4000-8000-000000000002';
SELECT throws_ok($$SELECT * FROM public.account_quota_usage$$,'42501',NULL,
    'Authenticated B cannot read private ledger, including A');
SELECT throws_ok($$SELECT * FROM public.quota_legacy_reconciliation$$,'42501',NULL,
    'Authenticated B cannot read reconciliation');
SELECT throws_ok($$SELECT public.reconcile_registration_quota('16320000-0000-4000-8000-000000000001')$$,
    '42501',NULL,'Authenticated B cannot reconcile A');
RESET ROLE;
SET LOCAL ROLE anon;
SELECT throws_ok($$SELECT * FROM public.account_quota_usage$$,'42501',NULL,'Anon cannot read ledger');
SELECT throws_ok($$SELECT public.reconcile_registration_quota('16320000-0000-4000-8000-000000000001')$$,
    '42501',NULL,'Anon cannot reconcile');
RESET ROLE;

SELECT lives_ok($$SELECT public.reconcile_registration_quota('16320000-0000-4000-8000-000000000007')$$,
    'Deletion fixture imports through the real function');
SELECT ok((SELECT count(*)=1 FROM public.account_quota_usage WHERE owner_id=(SELECT id FROM ledger_ids WHERE n=7))
    AND EXISTS (SELECT 1 FROM public.quota_legacy_reconciliation WHERE monthly_quota_id=(SELECT id FROM ledger_ids WHERE n=108)),
    'Deletion fixture has actual ledger and reconciliation rows');
SELECT lives_ok($$DELETE FROM public.profiles WHERE id='16320000-0000-4000-8000-000000000007'$$,
    'Account deletion cascades without blocking');
SELECT ok(NOT EXISTS (SELECT 1 FROM public.account_quota_usage WHERE owner_id=(SELECT id FROM ledger_ids WHERE n=7))
    AND NOT EXISTS (SELECT 1 FROM public.quota_legacy_reconciliation WHERE monthly_quota_id=(SELECT id FROM ledger_ids WHERE n=108))
    AND NOT EXISTS (SELECT 1 FROM public.analysis_jobs WHERE owner_id=(SELECT id FROM ledger_ids WHERE n=7)),
    'Account deletion removes both private history tables via their FKs');
DELETE FROM public.analysis_jobs WHERE id=(SELECT id FROM ledger_ids WHERE n=208);
SELECT is((SELECT count(*) FROM public.account_quota_usage WHERE job_id=(SELECT id FROM ledger_ids WHERE n=208)),
    0::bigint,'Job deletion cascades to its ledger row');

SELECT * FROM finish();
ROLLBACK;
