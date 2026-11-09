-- Synthetic fixtures for both clean install and seeded forward upgrade.
-- No production identities, credentials, disabled constraints, or admission stubs.
BEGIN;

INSERT INTO public.profiles (
  id, anonymous, app_account_token, starter_identification_consumed,
  starter_diagnosis_consumed, first_starter_success_at
) VALUES
  ('15700000-0000-4000-8000-000000000001', FALSE, NULL, FALSE, FALSE, NULL),
  ('15700000-0000-4000-8000-000000000002', FALSE,
   '15700000-0000-4000-8000-000000000602', TRUE, TRUE, '2026-10-20T10:00:00Z');

INSERT INTO public.installation_access (
  id, credential_hash, linked_owner_ids, starter_identification_consumed,
  starter_diagnosis_consumed, first_starter_success_at
) VALUES
  ('15700000-0000-4000-8000-000000000101', 'fixture-t157-installation-one',
   ARRAY['15700000-0000-4000-8000-000000000001'::uuid], FALSE, FALSE, NULL),
  ('15700000-0000-4000-8000-000000000102', 'fixture-t157-installation-two',
   ARRAY['15700000-0000-4000-8000-000000000002'::uuid], TRUE, TRUE, '2026-10-20T10:00:00Z');

INSERT INTO public.kb_releases (
  id, version, state, manifest_sha256, published_at
) VALUES (
  '15700000-0000-4000-8000-000000000100', 'fixture-t157-mode-guard',
  'published', repeat('a', 64), '2026-10-20T00:00:00Z'
);

-- The real purchase trigger sets the existing anchor; the upgrade must preserve it.
INSERT INTO public.purchase_ownership (
  environment, original_transaction_id, owner_id,
  app_account_token, first_verified_access_at
) VALUES (
  'Xcode', 'fixture-t157-mode-guard',
  '15700000-0000-4000-8000-000000000002',
  '15700000-0000-4000-8000-000000000602', '2026-10-20T10:00:00Z'
);

INSERT INTO public.entitlements (
  owner_id, product_id, state, offer_kind, valid_until
) VALUES (
  '15700000-0000-4000-8000-000000000002',
  'app.narat.plants.pro.monthly', 'active', 'paid', '2027-10-20T10:00:00Z'
);

INSERT INTO public.monthly_quotas (
  id, owner_id, quota_kind, period_start, period_end,
  limit_count, consumed_count, reserved_count
) VALUES (
  '15700000-0000-4000-8000-000000000401',
  '15700000-0000-4000-8000-000000000002', 'paid_monthly',
  '2026-10-20T10:00:00Z', '2026-11-20T10:00:00Z', 100, 7, 1
);

INSERT INTO public.photo_assets (
  id, owner_id, purpose, original_key, analysis_key, content_hash, state, uploaded_at
) VALUES (
  '15700000-0000-4000-8000-000000000301',
  '15700000-0000-4000-8000-000000000002', 'follow_up',
  'fixtures/t157/legacy-original.jpg', 'fixtures/t157/legacy-analysis.jpg',
  repeat('b', 64), 'ready', '2026-10-20T10:00:00Z'
);

INSERT INTO public.analysis_jobs (
  id, owner_id, flow_id, intent, add_method, mode, kb_release_id,
  prompt_version, operation_id, payload_hash, locale, photo_ids,
  quota_kind, quota_state, quota_installation_id, quota_owner_id,
  monthly_quota_id, state, provider_started_at, usage
) VALUES (
  '15700000-0000-4000-8000-000000000201',
  '15700000-0000-4000-8000-000000000002',
  '15700000-0000-4000-8000-000000000701', 'problem', 'scan', 'follow_up',
  '15700000-0000-4000-8000-000000000100', '3.0',
  '15700000-0000-4000-8000-000000000501', repeat('c', 64), 'pl',
  ARRAY['15700000-0000-4000-8000-000000000301'::uuid],
  'paid_monthly', 'consumed',
  '15700000-0000-4000-8000-000000000102',
  '15700000-0000-4000-8000-000000000002',
  '15700000-0000-4000-8000-000000000401', 'succeeded',
  '2026-10-20T10:00:00Z', '{"input_tokens":120,"output_tokens":40}'::jsonb
), (
  '15700000-0000-4000-8000-000000000202',
  '15700000-0000-4000-8000-000000000002',
  '15700000-0000-4000-8000-000000000702', 'care', 'catalogue', 'plan',
  '15700000-0000-4000-8000-000000000100', '3.0',
  '15700000-0000-4000-8000-000000000502', repeat('d', 64), 'en',
  '{}'::uuid[], 'none', 'not_applicable', NULL, NULL, NULL, 'succeeded', NULL, '{}'::jsonb
);

INSERT INTO public.operation_receipts (
  owner_id, operation_id, command_name, payload_hash, response_payload, committed_at
) VALUES (
  '15700000-0000-4000-8000-000000000002',
  '15700000-0000-4000-8000-000000000501', 'analysis.follow_up', repeat('c', 64),
  '{"job_id":"15700000-0000-4000-8000-000000000201","mode":"follow_up","state":"succeeded","legacy":true}'::jsonb,
  '2026-10-20T10:01:00Z'
);

COMMIT;
