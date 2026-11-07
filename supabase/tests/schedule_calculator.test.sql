-- supabase/tests/schedule_calculator.test.sql
-- T018: pgTAP tests for calculate_plant_schedule and can_owner_schedule_rule

BEGIN;
SELECT plan(12);

-- Setup test owner, KB release, taxon, and plant
INSERT INTO auth.users (id, email)
VALUES ('00000000-0000-0000-0000-0000000000a1', 'sched-owner@example.com');

INSERT INTO public.profiles (id, account_state, anonymous, preferred_locale)
VALUES ('00000000-0000-0000-0000-0000000000a1', 'active', FALSE, 'pl');

INSERT INTO public.kb_releases (
  id, version, status, manifest_sha256, schema_version, published_at
) VALUES (
  '00000000-0000-0000-0000-0000000000b1', '2026.11.01', 'published',
  repeat('a', 64), '3.0', now()
);

INSERT INTO public.catalogue_releases (
  id, kb_release_id, version, status, published_at
) VALUES (
  '00000000-0000-0000-0000-0000000000b2',
  '00000000-0000-0000-0000-0000000000b1',
  '2026.11.01', 'published', now()
);

INSERT INTO public.catalogue_taxa (
  id, release_id, plant_id, scientific_name, genus, family, status
) VALUES (
  '00000000-0000-0000-0000-0000000000b3',
  '00000000-0000-0000-0000-0000000000b2',
  'monstera_deliciosa', 'Monstera deliciosa', 'Monstera', 'Araceae', 'published'
);

INSERT INTO public.plants (
  id, owner_id, taxon_id, plant_id, display_name, creation_source, creation_intent, add_method, care_revision
) VALUES (
  '00000000-0000-0000-0000-0000000000c1',
  '00000000-0000-0000-0000-0000000000a1',
  '00000000-0000-0000-0000-0000000000b3',
  'monstera_deliciosa', 'Monstera', 'catalogue', 'care', 'catalogue', 1
);

INSERT INTO public.condition_snapshots (
  id, owner_id, plant_id, revision, light_level, light_source, light_confirmed, watering_habit, last_watered
) VALUES (
  '00000000-0000-0000-0000-0000000000c2',
  '00000000-0000-0000-0000-0000000000a1',
  '00000000-0000-0000-0000-0000000000c1',
  1, 'bright_indirect', 'manual', TRUE, 'moderate', 'unknown'
);

UPDATE public.plants
SET current_snapshot_id = '00000000-0000-0000-0000-0000000000c2'
WHERE id = '00000000-0000-0000-0000-0000000000c1';

-- 1. Create a basic care plan and basic_care_membership in Free slot 1
INSERT INTO public.care_plans (
  id, owner_id, plant_id, kb_release_id, version, access_tier, plan_kind, state,
  applicability_status, context_revision, summary_body
) VALUES (
  '00000000-0000-0000-0000-0000000000d1',
  '00000000-0000-0000-0000-0000000000a1',
  '00000000-0000-0000-0000-0000000000c1',
  '00000000-0000-0000-0000-0000000000b1',
  1, 'basic', 'routine', 'active', 'applicable', 1, '{"summary":"Basic routine"}'::jsonb
);

INSERT INTO public.basic_care_memberships (
  id, owner_id, plant_id, enabled, enabled_at, free_slot, selection_revision
) VALUES (
  '00000000-0000-0000-0000-0000000000d2',
  '00000000-0000-0000-0000-0000000000a1',
  '00000000-0000-0000-0000-0000000000c1',
  TRUE, now(), 1, 1
);

INSERT INTO public.task_rules (
  id, owner_id, plant_id, plan_id, access_class, action_type, interval_days,
  start_date, rule_state
) VALUES (
  '00000000-0000-0000-0000-0000000000d3',
  '00000000-0000-0000-0000-0000000000a1',
  '00000000-0000-0000-0000-0000000000c1',
  '00000000-0000-0000-0000-0000000000d1',
  'basic_care', 'water', 7, DATE '2026-11-01', 'active'
);

SELECT is(
  public.can_owner_schedule_rule(
    '00000000-0000-0000-0000-0000000000a1',
    '00000000-0000-0000-0000-0000000000c1',
    'basic_care',
    '00000000-0000-0000-0000-0000000000d1',
    NULL,
    now()
  ),
  TRUE,
  'basic_care rule is eligible when plant occupies Free slot 1..3'
);

-- Run calculate_plant_schedule
SELECT lives_ok(
  $$SELECT public.calculate_plant_schedule(
    '00000000-0000-0000-0000-0000000000a1',
    '00000000-0000-0000-0000-0000000000c1',
    DATE '2026-11-01'
  )$$,
  'calculate_plant_schedule executes cleanly'
);

SELECT is(
  (SELECT COUNT(*)::INT FROM public.care_tasks WHERE rule_id = '00000000-0000-0000-0000-0000000000d3' AND status = 'open'),
  1,
  'Exactly one open care_task is created for the basic_care rule'
);

SELECT is(
  (SELECT condition_code FROM public.care_tasks WHERE rule_id = '00000000-0000-0000-0000-0000000000d3' AND status = 'open'),
  'check_soil_first',
  'First watering task has check_soil_first when last_watered is unknown'
);

-- Calling calculate_plant_schedule a second time does not create a duplicate occurrence
SELECT public.calculate_plant_schedule(
  '00000000-0000-0000-0000-0000000000a1',
  '00000000-0000-0000-0000-0000000000c1',
  DATE '2026-11-01'
);

SELECT is(
  (SELECT COUNT(*)::INT FROM public.care_tasks WHERE rule_id = '00000000-0000-0000-0000-0000000000d3' AND status = 'open'),
  1,
  'Idempotent schedule calculation keeps single open occurrence'
);

-- Record a care entry on 2026-11-03 and complete initial task, then recalculate -> next due_date = 2026-11-10
UPDATE public.care_tasks
SET status = 'completed'
WHERE rule_id = '00000000-0000-0000-0000-0000000000d3' AND status = 'open';

INSERT INTO public.care_entries (
  id, owner_id, plant_id, task_id, action_type, performed_date
) VALUES (
  '00000000-0000-0000-0000-0000000000e1',
  '00000000-0000-0000-0000-0000000000a1',
  '00000000-0000-0000-0000-0000000000c1',
  (SELECT id FROM public.care_tasks WHERE rule_id = '00000000-0000-0000-0000-0000000000d3' LIMIT 1),
  'water',
  DATE '2026-11-03'
);

SELECT public.calculate_plant_schedule(
  '00000000-0000-0000-0000-0000000000a1',
  '00000000-0000-0000-0000-0000000000c1',
  DATE '2026-11-03'
);

SELECT is(
  (SELECT due_date FROM public.care_tasks WHERE rule_id = '00000000-0000-0000-0000-0000000000d3' AND status = 'open'),
  DATE '2026-11-10',
  'Next occurrence due_date is calculated from actual performed_date + interval_days'
);

-- Unassign Free slot without paid subscription -> open task becomes reminder_eligible = false, care_entries preserved
UPDATE public.basic_care_memberships
SET free_slot = NULL
WHERE id = '00000000-0000-0000-0000-0000000000d2';

SELECT public.calculate_plant_schedule(
  '00000000-0000-0000-0000-0000000000a1',
  '00000000-0000-0000-0000-0000000000c1',
  DATE '2026-11-03'
);

SELECT is(
  (SELECT reminder_eligible FROM public.care_tasks WHERE rule_id = '00000000-0000-0000-0000-0000000000d3' AND status = 'open'),
  FALSE,
  'Open basic task has reminder_eligible = FALSE when Free slot is unassigned without subscription'
);

SELECT is(
  (SELECT inactive_reason FROM public.care_tasks WHERE rule_id = '00000000-0000-0000-0000-0000000000d3' AND status = 'open'),
  'free_slot_unassigned',
  'Open basic task records free_slot_unassigned reason'
);

SELECT is(
  (SELECT COUNT(*)::INT FROM public.care_entries WHERE plant_id = '00000000-0000-0000-0000-0000000000c1' AND deleted_at IS NULL),
  1,
  'Historical care_entries are preserved when Free slot is unassigned'
);

-- Premium rule requires active/grace paid entitlement
INSERT INTO public.care_plans (
  id, owner_id, plant_id, kb_release_id, version, access_tier, plan_kind, state,
  applicability_status, context_revision, summary_body, full_body
) VALUES (
  '00000000-0000-0000-0000-0000000000f1',
  '00000000-0000-0000-0000-0000000000a1',
  '00000000-0000-0000-0000-0000000000c1',
  '00000000-0000-0000-0000-0000000000b1',
  2, 'full', 'routine', 'active', 'applicable', 1,
  '{"summary":"Full routine"}'::jsonb, '{"steps":["Step 1"]}'::jsonb
);

SELECT is(
  public.can_owner_schedule_rule(
    '00000000-0000-0000-0000-0000000000a1',
    '00000000-0000-0000-0000-0000000000c1',
    'premium',
    '00000000-0000-0000-0000-0000000000f1',
    NULL,
    TIMESTAMPTZ '2026-11-03T12:00:00Z'
  ),
  FALSE,
  'Premium rule is blocked when owner has no verified active/grace subscription'
);

-- Grant verified trial entitlement -> both premium and basic_care become eligible
INSERT INTO public.entitlements (
  owner_id, product_id, state, offer_kind, trial_end_at, valid_until, auto_renew_enabled, verified_at
) VALUES (
  '00000000-0000-0000-0000-0000000000a1',
  'app.narat.plants.pro.yearly',
  'active',
  'trial',
  TIMESTAMPTZ '2026-11-10T12:00:00Z',
  TIMESTAMPTZ '2026-11-10T12:00:00Z',
  TRUE,
  TIMESTAMPTZ '2026-11-03T12:00:00Z'
);

SELECT is(
  public.can_owner_schedule_rule(
    '00000000-0000-0000-0000-0000000000a1',
    '00000000-0000-0000-0000-0000000000c1',
    'premium',
    '00000000-0000-0000-0000-0000000000f1',
    NULL,
    TIMESTAMPTZ '2026-11-03T12:00:00Z'
  ),
  TRUE,
  'Premium rule is allowed during verified active trial'
);

SELECT is(
  public.can_owner_schedule_rule(
    '00000000-0000-0000-0000-0000000000a1',
    '00000000-0000-0000-0000-0000000000c1',
    'basic_care',
    '00000000-0000-0000-0000-0000000000d1',
    NULL,
    TIMESTAMPTZ '2026-11-03T12:00:00Z'
  ),
  TRUE,
  'basic_care rule is allowed for any enabled plant while paid access is active'
);

SELECT * FROM finish();
ROLLBACK;
