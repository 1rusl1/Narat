-- supabase/tests/guest_claim.test.sql
-- T040: pgTAP tests for guest_claim, overrides (care_revision=2, context_state='stale'),
-- room-only override keeping current, >24h TTL local fallback, claim/fallback race protection,
-- identification-only claim, and diagnostic decision/answer transfer.

BEGIN;
SELECT plan(14);

-- Setup KB release, taxon, and owner
INSERT INTO public.kb_releases (
  id, version, status, manifest_sha256, schema_version, published_at
) VALUES (
  '00000000-0000-0000-0000-000000000600', '2026.11.01', 'published',
  repeat('d', 64), '3.0', TIMESTAMPTZ '2026-11-01T00:00:00Z'
);

INSERT INTO public.catalogue_releases (
  id, kb_release_id, version, status, published_at
) VALUES (
  '00000000-0000-0000-0000-000000000601',
  '00000000-0000-0000-0000-000000000600',
  '2026.11.01', 'published', TIMESTAMPTZ '2026-11-01T00:00:00Z'
);

INSERT INTO public.catalogue_taxa (
  id, release_id, plant_id, scientific_name, genus, family, status
) VALUES (
  '00000000-0000-0000-0000-000000000602',
  '00000000-0000-0000-0000-000000000601',
  'monstera_deliciosa', 'Monstera deliciosa', 'Monstera', 'Araceae', 'published'
);

INSERT INTO auth.users (id, email)
VALUES ('00000000-0000-0000-0000-000000000603', 'claim-owner@example.com');

INSERT INTO public.profiles (id, account_state, anonymous, preferred_locale)
VALUES ('00000000-0000-0000-0000-000000000603', 'active', FALSE, 'pl');

INSERT INTO public.installation_access (
  id, credential_hash, starter_diagnosis_consumed, first_starter_success_at
) VALUES (
  '00000000-0000-0000-0000-000000000604', repeat('e', 64), TRUE, TIMESTAMPTZ '2026-11-02T09:00:00Z'
);

-- 1. Create a diagnosis guest_draft with analysis_result, diagnostic_decision, and diagnostic_answer
INSERT INTO public.guest_drafts (
  id, installation_id, flow_id, intent, add_method, state, claim_secret_hash,
  confirmed_taxon_id, confirmed_plant_id, conditions_payload, expires_at
) VALUES (
  '00000000-0000-0000-0000-000000000610',
  '00000000-0000-0000-0000-000000000604',
  '00000000-0000-0000-0000-000000000611',
  'problem', 'scan', 'ready', 'secret_hash_1',
  '00000000-0000-0000-0000-000000000602', 'monstera_deliciosa',
  '{"light_level":"medium","light_source":"manual","light_confirmed":true,"watering_habit":"moderate","last_watered":"within_7_days","pot_type":"unknown","season_override":"auto"}'::jsonb,
  TIMESTAMPTZ '2026-11-03T09:00:00Z'
);

INSERT INTO public.analysis_jobs (
  id, draft_id, installation_id, kb_release_id, mode, status, quota_kind, quota_state
) VALUES (
  '00000000-0000-0000-0000-000000000612',
  '00000000-0000-0000-0000-000000000610',
  '00000000-0000-0000-0000-000000000604',
  '00000000-0000-0000-0000-000000000600',
  'diagnosis', 'succeeded', 'starter_diagnosis', 'consumed'
);

INSERT INTO public.analysis_results (
  id, job_id, draft_id, kb_release_id, mode, schema_version,
  identification_status, plant_id, genus_id, diagnosis_status,
  provider_classification, context_state, analysis_receipt
) VALUES (
  '00000000-0000-0000-0000-000000000613',
  '00000000-0000-0000-0000-000000000612',
  '00000000-0000-0000-0000-000000000610',
  '00000000-0000-0000-0000-000000000600',
  'diagnosis', '3.0', 'resolved', 'monstera_deliciosa', 'monstera',
  'condition_detected', '{}'::jsonb, 'current', 'signed_receipt_1'
);

INSERT INTO public.diagnostic_decisions (
  id, analysis_id, revision, kb_release_id, candidate_conditions, selected_condition_id, resolution_state, decision_receipt
) VALUES (
  '00000000-0000-0000-0000-000000000614',
  '00000000-0000-0000-0000-000000000613',
  1, '00000000-0000-0000-0000-000000000600',
  '[{"condition_id":"overwatering","rank":1,"confidence":0.85}]'::jsonb,
  'overwatering', 'user_confirmed', 'decision_receipt_1'
);

INSERT INTO public.diagnostic_answers (
  id, analysis_id, decision_revision, question_code, answer_value
) VALUES (
  '00000000-0000-0000-0000-000000000615',
  '00000000-0000-0000-0000-000000000613',
  1, 'q_soil_wet', 'yes'
);

-- Prepare and commit with condition override + new room creation -> care_revision=2, context_state='stale'
SELECT lives_ok(
  $$SELECT public.prepare_guest_claim(
    '00000000-0000-0000-0000-000000000603',
    '00000000-0000-0000-0000-000000000616',
    '00000000-0000-0000-0000-000000000610',
    'secret_hash_1',
    '{"light_level":"low","new_room_name":"Salon"}'::jsonb,
    TIMESTAMPTZ '2026-11-02T10:00:00Z'
  )$$,
  'prepare_guest_claim succeeds with valid claim_secret_hash'
);

CREATE TEMP TABLE claim1_out AS
SELECT public.commit_guest_claim(
  '00000000-0000-0000-0000-000000000603',
  '00000000-0000-0000-0000-000000000617',
  '00000000-0000-0000-0000-000000000610',
  NULL,
  TIMESTAMPTZ '2026-11-02T10:01:00Z'
) AS res;

SELECT is(
  (SELECT (res->>'care_revision')::INT FROM claim1_out),
  2,
  'Overriding light_level during guest claim sets care_revision = 2'
);

SELECT is(
  (SELECT res->>'context_state' FROM claim1_out),
  'stale',
  'Overriding conditions marks original analysis context_state = stale'
);

SELECT is(
  (SELECT res->>'next_available_step' FROM claim1_out),
  'record_first_aid',
  'Problem claim returns next_available_step = record_first_aid'
);

SELECT is(
  (SELECT COUNT(*)::INT FROM public.condition_snapshots WHERE plant_id = (SELECT (res->>'plant_id')::UUID FROM claim1_out)),
  2,
  'Both initial snapshot (rev 1) and overridden snapshot (rev 2) are stored atomically'
);

SELECT is(
  (SELECT owner_id FROM public.diagnostic_decisions WHERE id = '00000000-0000-0000-0000-000000000614'),
  '00000000-0000-0000-0000-000000000603'::UUID,
  'diagnostic_decisions ownership is transferred to permanent owner'
);

SELECT is(
  (SELECT owner_id FROM public.diagnostic_answers WHERE id = '00000000-0000-0000-0000-000000000615'),
  '00000000-0000-0000-0000-000000000603'::UUID,
  'diagnostic_answers ownership is transferred to permanent owner'
);

-- 2. Race between claim and fallback: attempting local_fallback with the same origin_draft_id is rejected
SELECT throws_ok(
  $$SELECT public.execute_plant_create_command(
    '00000000-0000-0000-0000-000000000603',
    '00000000-0000-0000-0000-000000000618',
    '{"creation_source":"local_fallback","origin_draft_id":"00000000-0000-0000-0000-000000000610","analysis_receipt":"signed_receipt_1","plant_id":"monstera_deliciosa"}'::jsonb,
    TIMESTAMPTZ '2026-11-04T10:00:00Z'
  )$$,
  'DRAFT_ALREADY_SAVED',
  'Fallback save rejects an already-claimed origin_draft_id'
);

-- 3. Identification-only guest_draft with room-only override keeps care_revision=1 and context_state='current'
INSERT INTO public.guest_drafts (
  id, installation_id, flow_id, intent, add_method, state, claim_secret_hash,
  confirmed_taxon_id, confirmed_plant_id, conditions_payload, expires_at
) VALUES (
  '00000000-0000-0000-0000-000000000620',
  '00000000-0000-0000-0000-000000000604',
  '00000000-0000-0000-0000-000000000621',
  'care', 'scan', 'ready', 'secret_hash_2',
  '00000000-0000-0000-0000-000000000602', 'monstera_deliciosa',
  '{"light_level":"bright_indirect","light_source":"camera_estimate","light_confirmed":true,"watering_habit":"moderate","last_watered":"unknown","pot_type":"standard_drainage","season_override":"auto"}'::jsonb,
  TIMESTAMPTZ '2026-11-03T09:00:00Z'
);

INSERT INTO public.analysis_jobs (
  id, draft_id, installation_id, kb_release_id, mode, status, quota_kind, quota_state
) VALUES (
  '00000000-0000-0000-0000-000000000622',
  '00000000-0000-0000-0000-000000000620',
  '00000000-0000-0000-0000-000000000604',
  '00000000-0000-0000-0000-000000000600',
  'identification', 'succeeded', 'starter_identification', 'consumed'
);

INSERT INTO public.analysis_results (
  id, job_id, draft_id, kb_release_id, mode, schema_version,
  identification_status, plant_id, genus_id, diagnosis_status,
  provider_classification, context_state, analysis_receipt
) VALUES (
  '00000000-0000-0000-0000-000000000623',
  '00000000-0000-0000-0000-000000000622',
  '00000000-0000-0000-0000-000000000620',
  '00000000-0000-0000-0000-000000000600',
  'identification', '3.0', 'resolved', 'monstera_deliciosa', 'monstera',
  NULL, '{}'::jsonb, 'current', 'signed_receipt_2'
);

CREATE TEMP TABLE claim2_out AS
SELECT public.commit_guest_claim(
  '00000000-0000-0000-0000-000000000603',
  '00000000-0000-0000-0000-000000000624',
  '00000000-0000-0000-0000-000000000620',
  '{"new_room_name":"Sypialnia"}'::jsonb,
  TIMESTAMPTZ '2026-11-02T11:00:00Z'
) AS res;

SELECT is(
  (SELECT (res->>'care_revision')::INT FROM claim2_out),
  1,
  'Changing only the room during claim keeps care_revision = 1'
);

SELECT is(
  (SELECT res->>'context_state' FROM claim2_out),
  'current',
  'Changing only the room keeps analysis context_state = current'
);

SELECT is(
  (SELECT res->>'next_available_step' FROM claim2_out),
  'enable_basic_care',
  'Identification-only care claim returns next_available_step = enable_basic_care'
);

-- 4. Local fallback save after 24h TTL expiry succeeds without AI/photo quota
CREATE TEMP TABLE fallback_out AS
SELECT public.execute_plant_create_command(
  '00000000-0000-0000-0000-000000000603',
  '00000000-0000-0000-0000-000000000630',
  '{
    "creation_source": "local_fallback",
    "creation_intent": "problem",
    "add_method": "scan",
    "origin_draft_id": "00000000-0000-0000-0000-000000000631",
    "origin_flow_id": "00000000-0000-0000-0000-000000000632",
    "plant_id": "monstera_deliciosa",
    "taxon_id": "00000000-0000-0000-0000-000000000602",
    "display_name": "Monstera Fallback",
    "analysis_receipt": "signed_receipt_fallback_1",
    "analysis_mode": "diagnosis",
    "conditions": {
      "light_level": "medium",
      "light_source": "manual",
      "light_confirmed": true,
      "watering_habit": "moderate",
      "last_watered": "unknown"
    },
    "overrides": {
      "watering_habit": "frequent"
    }
  }'::jsonb,
  TIMESTAMPTZ '2026-11-05T12:00:00Z'
) AS res;

SELECT is(
  (SELECT (res->>'care_revision')::INT FROM fallback_out),
  2,
  'Local fallback save after 24h TTL applies overrides and sets care_revision = 2'
);

SELECT is(
  (SELECT res->>'next_available_step' FROM fallback_out),
  'record_first_aid',
  'Local fallback save returns next_available_step without calling AI'
);

-- 5. Deleting a room preserves the plants in that room with room_id = NULL
SELECT public.execute_room_command(
  '00000000-0000-0000-0000-000000000603',
  '00000000-0000-0000-0000-000000000640',
  'room.delete',
  jsonb_build_object('room_id', (SELECT (res->>'room_id')::UUID FROM claim2_out))
);

SELECT is(
  (SELECT room_id IS NULL AND deleted_at IS NULL
   FROM public.plants WHERE id = (SELECT (res->>'plant_id')::UUID FROM claim2_out)),
  TRUE,
  'Deleting a room sets plants.room_id = NULL while preserving the plant'
);

SELECT * FROM finish();
ROLLBACK;
