-- Real RPC / pgTAP fixtures only; sequential admissions do not prove concurrency.
BEGIN;
SELECT plan(50);

-- Legacy mode CHECKs remain usable for historical jobs and photo metadata.
SELECT is(
  (SELECT jsonb_agg(jsonb_build_array(mode, state, quota_kind, quota_state) ORDER BY id)
   FROM public.analysis_jobs
   WHERE id IN ('15700000-0000-4000-8000-000000000201', '15700000-0000-4000-8000-000000000202')),
  '[["follow_up","succeeded","paid_monthly","consumed"],["plan","succeeded","none","not_applicable"]]'::jsonb,
  'Historical follow_up and plan jobs remain readable without conversion'
);
SELECT is(
  public.lookup_operation_receipt(
    '15700000-0000-4000-8000-000000000002',
    '15700000-0000-4000-8000-000000000501', 'analysis.follow_up', repeat('c', 64)),
  '{"job_id":"15700000-0000-4000-8000-000000000201","mode":"follow_up","state":"succeeded","legacy":true}'::jsonb,
  'Original follow_up receipt is replayable'
);
SELECT is(
  (SELECT jsonb_build_array(purpose, original_key, analysis_key, content_hash, state, uploaded_at)
   FROM public.photo_assets WHERE id = '15700000-0000-4000-8000-000000000301'),
  jsonb_build_array('follow_up', 'fixtures/t157/legacy-original.jpg',
    'fixtures/t157/legacy-analysis.jpg', repeat('b', 64), 'ready', '2026-10-20T10:00:00+00:00'::timestamptz),
  'Legacy photo keys and immutable upload time survive'
);
SELECT is(
  (SELECT jsonb_build_array(quota_kind, consumed_count, reserved_count, limit_count, period_start, period_end)
   FROM public.monthly_quotas WHERE id = '15700000-0000-4000-8000-000000000401'),
  jsonb_build_array('paid_monthly', 7, 1, 100, '2026-10-20T10:00:00Z'::timestamptz, '2026-11-20T10:00:00Z'::timestamptz),
  'Existing consumption, reservation and period survive upgrade'
);
SELECT is(
  (SELECT jsonb_build_array(po.environment, po.original_transaction_id, po.first_verified_access_at, p.quota_anchor_at)
   FROM public.purchase_ownership po JOIN public.profiles p ON p.id = po.owner_id
   WHERE po.owner_id = '15700000-0000-4000-8000-000000000002'),
  jsonb_build_array('Xcode', 'fixture-t157-mode-guard',
    '2026-10-20T10:00:00Z'::timestamptz, '2026-10-20T10:00:00Z'::timestamptz),
  'Verified ledger and original quota anchor survive'
);

SELECT ok(has_function_privilege('service_role',
  'public.admit_analysis_quota(text,uuid,uuid,uuid,timestamptz)', 'EXECUTE'),
  'Service role retains the original RPC signature');
SELECT ok(NOT has_function_privilege('anon',
  'public.admit_analysis_quota(text,uuid,uuid,uuid,timestamptz)', 'EXECUTE'),
  'Anonymous clients cannot call the privileged RPC');
SELECT ok(NOT has_function_privilege('authenticated',
  'public.admit_analysis_quota(text,uuid,uuid,uuid,timestamptz)', 'EXECUTE'),
  'Authenticated clients cannot call the privileged RPC');
SELECT ok(NOT EXISTS (
  SELECT 1 FROM pg_proc p,
    LATERAL aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) a
  WHERE p.oid = 'public.admit_analysis_quota(text,uuid,uuid,uuid,timestamptz)'::regprocedure
    AND a.grantee = 0 AND a.privilege_type = 'EXECUTE'
), 'PUBLIC has no execute grant');
SELECT ok(
  (SELECT prosecdef AND proconfig @> ARRAY['search_path=public']
   FROM pg_proc WHERE oid = 'public.admit_analysis_quota(text,uuid,uuid,uuid,timestamptz)'::regprocedure),
  'RPC keeps SECURITY DEFINER and its fixed search_path'
);

-- All successful and competing admissions use real FK-valid job rows.
CREATE TEMP TABLE mode_guard_jobs (
  name text, id uuid, owner_id uuid, installation_id uuid,
  mode text, quota_kind text, monthly_quota_id uuid
);
INSERT INTO mode_guard_jobs VALUES
  ('id', '15700000-0000-4000-8000-000000000211', '15700000-0000-4000-8000-000000000001',
   '15700000-0000-4000-8000-000000000101', 'identification', 'starter_identification', NULL),
  ('diag', '15700000-0000-4000-8000-000000000212', '15700000-0000-4000-8000-000000000001',
   '15700000-0000-4000-8000-000000000101', 'diagnosis', 'starter_diagnosis', NULL),
  ('id_other', '15700000-0000-4000-8000-000000000213', '15700000-0000-4000-8000-000000000001',
   '15700000-0000-4000-8000-000000000101', 'identification', 'starter_identification', NULL),
  ('diag_other', '15700000-0000-4000-8000-000000000214', '15700000-0000-4000-8000-000000000001',
   '15700000-0000-4000-8000-000000000101', 'diagnosis', 'starter_diagnosis', NULL),
  ('paid_id', '15700000-0000-4000-8000-000000000215', '15700000-0000-4000-8000-000000000002',
   '15700000-0000-4000-8000-000000000102', 'identification', 'paid_monthly', '15700000-0000-4000-8000-000000000401'),
  ('paid_diag', '15700000-0000-4000-8000-000000000216', '15700000-0000-4000-8000-000000000002',
   '15700000-0000-4000-8000-000000000102', 'diagnosis', 'paid_monthly', '15700000-0000-4000-8000-000000000401');
INSERT INTO public.analysis_jobs (
  id, owner_id, flow_id, intent, add_method, mode, kb_release_id, prompt_version,
  operation_id, payload_hash, locale, quota_kind, quota_state,
  quota_installation_id, quota_owner_id, monthly_quota_id
)
SELECT id, owner_id, id, 'problem', 'scan', mode,
  '15700000-0000-4000-8000-000000000100'::uuid, '3.0', id, repeat('e', 64), 'en',
  quota_kind, 'reserved', installation_id, owner_id, monthly_quota_id
FROM mode_guard_jobs;

CREATE TEMP TABLE mode_guard_context AS
SELECT 'free'::text AS name, owner_id, installation_id, id AS job_id FROM mode_guard_jobs WHERE name = 'id'
UNION ALL
SELECT 'paid', owner_id, installation_id, id FROM mode_guard_jobs WHERE name = 'paid_id'
UNION ALL
SELECT 'missing', '15700000-0000-4000-8000-000000000999'::uuid,
  '15700000-0000-4000-8000-000000000999'::uuid, '15700000-0000-4000-8000-000000000999'::uuid
UNION ALL
SELECT 'absent', NULL::uuid, NULL::uuid, NULL::uuid;

-- Snapshot every public table, including any otherwise empty quota/budget tables.
-- This view only reads real rows; it never substitutes admission behavior.
DO $snapshot$
DECLARE
  v_query text;
BEGIN
  SELECT string_agg(format(
    'SELECT %L AS table_name, COALESCE(jsonb_agg(to_jsonb(t) ORDER BY to_jsonb(t)::text), ''[]''::jsonb) AS table_rows FROM public.%I t',
    tablename, tablename), ' UNION ALL ' ORDER BY tablename)
  INTO v_query FROM pg_tables WHERE schemaname = 'public';
  EXECUTE 'CREATE TEMP VIEW mode_guard_public_state AS SELECT jsonb_object_agg(table_name, table_rows) AS data FROM ('
    || v_query || ') AS all_tables';
END;
$snapshot$;
CREATE TEMP TABLE mode_guard_before AS SELECT data FROM mode_guard_public_state;

-- 16 actual throws_ok calls: NULL, removed, plan and unknown modes on each path.
SELECT throws_ok(
  format('SELECT public.admit_analysis_quota(%L, %L::uuid, %L::uuid, %L::uuid, %L::timestamptz)',
    m.mode, c.owner_id, c.installation_id, c.job_id, '2026-11-09T10:00:00Z'),
  'P0001', 'INVALID_ANALYSIS_MODE',
  format('Reject %s before owner/installation access (%s)', COALESCE(m.mode, 'NULL'), c.name)
)
FROM (VALUES ('follow_up'), ('plan'), ('unknown'), (NULL::text)) AS m(mode)
CROSS JOIN mode_guard_context c;
SELECT is((SELECT data FROM mode_guard_public_state), (SELECT data FROM mode_guard_before),
  'Forbidden modes leave all public rows, starter markers and spend unchanged');

SELECT is(
  public.admit_analysis_quota(mode, owner_id, installation_id, id, '2026-11-09T10:00:00Z'),
  jsonb_build_object('admitted', TRUE, 'quota_kind', quota_kind,
    'installation_id', installation_id, 'remaining_after_reserve', 0),
  'Identification admits the real starter job'
) FROM mode_guard_jobs WHERE name = 'id';
SELECT ok(
  (SELECT starter_identification_job_id = '15700000-0000-4000-8000-000000000211'::uuid
    AND starter_diagnosis_job_id IS NULL AND NOT starter_identification_consumed AND NOT starter_diagnosis_consumed
   FROM public.profiles WHERE id = '15700000-0000-4000-8000-000000000001'),
  'Profile identification reservation does not consume diagnosis'
);
SELECT ok(
  (SELECT starter_identification_job_id = '15700000-0000-4000-8000-000000000211'::uuid
    AND starter_diagnosis_job_id IS NULL AND NOT starter_identification_consumed AND NOT starter_diagnosis_consumed
   FROM public.installation_access WHERE id = '15700000-0000-4000-8000-000000000101'),
  'Installation identification reservation does not consume diagnosis'
);
SELECT is(
  public.admit_analysis_quota(mode, owner_id, installation_id, id, '2026-11-09T10:00:00Z'),
  jsonb_build_object('admitted', TRUE, 'quota_kind', quota_kind,
    'installation_id', installation_id, 'remaining_after_reserve', 0),
  'Diagnosis admits independently while identification is in progress'
) FROM mode_guard_jobs WHERE name = 'diag';
SELECT ok(
  (SELECT p.starter_identification_job_id = '15700000-0000-4000-8000-000000000211'::uuid
    AND p.starter_diagnosis_job_id = '15700000-0000-4000-8000-000000000212'::uuid
    AND i.starter_identification_job_id = p.starter_identification_job_id
    AND i.starter_diagnosis_job_id = p.starter_diagnosis_job_id
    AND NOT p.starter_identification_consumed AND NOT p.starter_diagnosis_consumed
    AND NOT i.starter_identification_consumed AND NOT i.starter_diagnosis_consumed
   FROM public.profiles p JOIN public.installation_access i ON i.id = '15700000-0000-4000-8000-000000000101'
   WHERE p.id = '15700000-0000-4000-8000-000000000001'),
  'Independent reservations remain on both owner and installation'
);

CREATE TEMP TABLE mode_guard_in_progress AS SELECT data FROM mode_guard_public_state;
SELECT is(
  public.admit_analysis_quota(j.mode, j.owner_id, j.installation_id, j.id, '2026-11-09T10:00:00Z'),
  jsonb_build_object('admitted', FALSE, 'quota_kind', j.quota_kind,
    'reason', 'starter_in_progress', 'in_progress_job_id', original.id),
  j.mode || ' rejects a different job while its starter is reserved'
)
FROM mode_guard_jobs j JOIN mode_guard_jobs original ON original.mode = j.mode
WHERE j.name IN ('id_other', 'diag_other') AND original.name IN ('id', 'diag');
SELECT is((SELECT data FROM mode_guard_public_state), (SELECT data FROM mode_guard_in_progress),
  'Sequential in-progress denials leave every public row unchanged');

SELECT is(
  public.admit_analysis_quota(mode, owner_id, installation_id, id, '2026-11-09T10:00:00Z'),
  jsonb_build_object('admitted', TRUE, 'quota_kind', 'paid_monthly', 'monthly_quota_id', monthly_quota_id,
    'period_start', '2026-10-20T10:00:00Z'::timestamptz, 'period_end', '2026-11-20T10:00:00Z'::timestamptz,
    'remaining_after_reserve', 91),
  'Paid identification reserves against the original window'
) FROM mode_guard_jobs WHERE name = 'paid_id';
SELECT is(
  public.admit_analysis_quota(mode, owner_id, installation_id, id, '2026-11-09T10:00:00Z'),
  jsonb_build_object('admitted', TRUE, 'quota_kind', 'paid_monthly', 'monthly_quota_id', monthly_quota_id,
    'period_start', '2026-10-20T10:00:00Z'::timestamptz, 'period_end', '2026-11-20T10:00:00Z'::timestamptz,
    'remaining_after_reserve', 90),
  'Paid diagnosis shares the unchanged original window'
) FROM mode_guard_jobs WHERE name = 'paid_diag';
SELECT ok(
  (SELECT p.starter_identification_consumed AND p.starter_diagnosis_consumed
    AND i.starter_identification_consumed AND i.starter_diagnosis_consumed
    AND p.starter_identification_job_id IS NULL AND p.starter_diagnosis_job_id IS NULL
    AND i.starter_identification_job_id IS NULL AND i.starter_diagnosis_job_id IS NULL
    AND p.quota_anchor_at = '2026-10-20T10:00:00Z'::timestamptz
   FROM public.profiles p JOIN public.installation_access i ON i.id = '15700000-0000-4000-8000-000000000102'
   WHERE p.id = '15700000-0000-4000-8000-000000000002'),
  'Paid admissions retain starter markers and the original anchor'
);
SELECT is(
  (SELECT jsonb_build_array(consumed_count, reserved_count, limit_count, period_start, period_end)
   FROM public.monthly_quotas WHERE id = '15700000-0000-4000-8000-000000000401'),
  jsonb_build_array(7, 3, 100, '2026-10-20T10:00:00Z'::timestamptz, '2026-11-20T10:00:00Z'::timestamptz),
  'Only the two valid paid admissions add reservations; spend and dates stay intact'
);

UPDATE public.profiles SET account_state = 'deleting' WHERE id = '15700000-0000-4000-8000-000000000002';
CREATE TEMP TABLE mode_guard_inactive AS SELECT data FROM mode_guard_public_state;
SELECT is(
  public.admit_analysis_quota(mode, owner_id, installation_id, id, '2026-11-09T10:00:00Z'),
  '{"admitted":false,"reason":"account_inactive"}'::jsonb,
  mode || ' retains the inactive-owner guard'
) FROM mode_guard_jobs WHERE name IN ('paid_id', 'paid_diag');
SELECT throws_ok(
  format('SELECT public.admit_analysis_quota(%L, %L::uuid, %L::uuid, %L::uuid, %L::timestamptz)',
    m.mode, c.owner_id, c.installation_id, c.job_id, '2026-11-09T10:00:00Z'),
  'P0001', 'INVALID_ANALYSIS_MODE',
  format('Invalid %s takes precedence over inactive owner', COALESCE(m.mode, 'NULL'))
)
FROM (VALUES ('follow_up'), ('plan'), ('unknown'), (NULL::text)) AS m(mode)
CROSS JOIN mode_guard_context c WHERE c.name = 'paid';
SELECT is((SELECT data FROM mode_guard_public_state), (SELECT data FROM mode_guard_inactive),
  'Inactive-owner and forbidden-mode denials leave every public row unchanged');

-- Fixture transition to an anonymous owner with previously consumed starters.
-- This does not test settlement or change the RPC under test.
UPDATE public.profiles SET account_state = 'active', anonymous = TRUE, app_account_token = NULL
WHERE id = '15700000-0000-4000-8000-000000000002';
CREATE TEMP TABLE mode_guard_exhausted AS SELECT data FROM mode_guard_public_state;
SELECT is(
  public.admit_analysis_quota(mode, owner_id, installation_id, id, '2026-11-09T10:00:00Z'),
  jsonb_build_object('admitted', FALSE,
    'quota_kind', CASE mode WHEN 'identification' THEN 'starter_identification' ELSE 'starter_diagnosis' END,
    'reason', 'starter_exhausted'),
  mode || ' cannot reissue an already consumed anonymous starter'
) FROM mode_guard_jobs WHERE name IN ('paid_id', 'paid_diag');
SELECT is((SELECT data FROM mode_guard_public_state), (SELECT data FROM mode_guard_exhausted),
  'Exhausted starters leave every public row unchanged');

SELECT is(
  (SELECT jsonb_build_array(data->'analysis_jobs', data->'operation_receipts', data->'photo_assets', data->'purchase_ownership')
   FROM mode_guard_public_state),
  (SELECT jsonb_build_array(data->'analysis_jobs', data->'operation_receipts', data->'photo_assets', data->'purchase_ownership')
   FROM mode_guard_before),
  'Admissions and denials preserve full legacy job, receipt, photo and ledger rows'
);

SELECT * FROM finish();
ROLLBACK;
