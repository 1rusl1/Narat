-- T161: real persisted-schema fixtures, not scheduling mocks.
-- Clean/upgrade preservation and real cap races are run by the controller.
BEGIN;
SELECT no_plan();

CREATE TEMP TABLE care_fixture AS
SELECT n AS k,
  CASE WHEN n <= 3 THEN 'f1610000-0000-4000-8000-000000000001'::uuid
       ELSE 'f1610000-0000-4000-8000-000000000002'::uuid END AS owner_id,
  md5('t161-plant-' || n)::uuid AS plant_id,
  md5('t161-snapshot-' || n)::uuid AS snapshot_id,
  md5('t161-plan-' || n)::uuid AS plan_id,
  md5('t161-rule-' || n)::uuid AS rule_id,
  md5('t161-task-' || n)::uuid AS task_id
FROM generate_series(1, 7) n;

INSERT INTO public.profiles(id, anonymous, preferred_locale) VALUES
('f1610000-0000-4000-8000-000000000001', false, 'pl'),
('f1610000-0000-4000-8000-000000000002', false, 'en');
UPDATE public.profiles SET free_selection_explicit = true, free_selection_revision = 7
WHERE id = 'f1610000-0000-4000-8000-000000000001';
INSERT INTO public.entitlements(owner_id, product_id, state, offer_kind, valid_until)
VALUES ('f1610000-0000-4000-8000-000000000002',
  'app.narat.plants.pro.monthly', 'active', 'paid', clock_timestamp() + interval '1 day');
INSERT INTO public.kb_releases(id, version, state, published_at)
VALUES ('f1610000-0000-4000-8000-000000000401',
  'fixture-t161-free-care', 'published', clock_timestamp());

INSERT INTO public.plants(id, owner_id, display_name, creation_source)
SELECT plant_id, owner_id, 'Care fixture ' || k, 'identification' FROM care_fixture;
INSERT INTO public.condition_snapshots(id, owner_id, plant_id)
SELECT snapshot_id, owner_id, plant_id FROM care_fixture;
UPDATE public.plants p SET current_condition_snapshot_id = f.snapshot_id
FROM care_fixture f WHERE p.id = f.plant_id;
INSERT INTO public.care_plans(
  id, operation_id, owner_id, plant_id, locale, plan_kind, access_tier,
  source_kind, snapshot_id, kb_release_id, context_revision, full_body
)
SELECT plan_id, md5('t161-plan-operation-' || k)::uuid, owner_id, plant_id,
  'en', 'routine', 'basic', 'catalogue', snapshot_id,
  'f1610000-0000-4000-8000-000000000401', 1, '{"actions":[]}'::jsonb
FROM care_fixture;
INSERT INTO public.task_rules(
  id, owner_id, plant_id, plan_id, access_class, rule_state,
  action_code, condition_code, interval_days
)
SELECT rule_id, owner_id, plant_id, plan_id, 'basic_care', 'paused',
  'water', 'check_soil_first', 7 FROM care_fixture;
INSERT INTO public.care_tasks(
  id, owner_id, plant_id, rule_id, occurrence_key, action_code, due_local_date,
  reminder_eligible, inactive_reason
)
SELECT task_id, owner_id, plant_id, rule_id, 'fixture-' || k, 'water',
  CURRENT_DATE, false, 'plan_superseded' FROM care_fixture;

-- Retained legacy row: reconciliation must preserve every physical field.
INSERT INTO public.basic_care_memberships(owner_id, plant_id, enabled_at, free_slot)
SELECT owner_id, plant_id, '2026-10-01T09:00:00Z', 2 FROM care_fixture WHERE k = 1;
CREATE TEMP TABLE legacy_membership AS
SELECT to_jsonb(m) AS body FROM public.basic_care_memberships m
JOIN care_fixture f ON f.plant_id = m.plant_id WHERE f.k = 1;

DO $$
DECLARE f RECORD;
BEGIN
  FOR f IN SELECT * FROM care_fixture WHERE k > 1 ORDER BY k LOOP
    PERFORM public.execute_basic_care_command(
      f.owner_id, md5('t161-enable-' || f.k)::uuid, 'basic_care.enable',
      jsonb_build_object('plant_id', f.plant_id)
    );
  END LOOP;
END;
$$;

CREATE TEMP VIEW care_eligibility AS
SELECT f.*, public.can_owner_schedule_rule(
  owner_id, plant_id, 'basic_care', plan_id, NULL, clock_timestamp()
) AS allowed FROM care_fixture f;
CREATE TEMP VIEW care_state AS
SELECT jsonb_build_object(
  'profiles', (SELECT jsonb_agg(to_jsonb(p) ORDER BY p.id) FROM public.profiles p),
  'memberships', (SELECT jsonb_agg(to_jsonb(m) ORDER BY m.id) FROM public.basic_care_memberships m),
  'rules', (SELECT jsonb_agg(to_jsonb(r) ORDER BY r.id) FROM public.task_rules r),
  'tasks', (SELECT jsonb_agg(to_jsonb(t) ORDER BY t.id) FROM public.care_tasks t),
  'receipts', (SELECT jsonb_agg(to_jsonb(r) ORDER BY r.owner_id, r.operation_id)
               FROM public.operation_receipts r)
) AS body;

SELECT ok((SELECT bool_and(allowed) FROM care_eligibility WHERE k <= 3),
  'No-entitlement Free can schedule every enabled membership without slots');
SELECT ok((SELECT bool_and(allowed) FROM care_eligibility WHERE k >= 4),
  'Verified paid schedules all four enabled plants without slots');
SELECT is((SELECT count(*) FROM public.basic_care_memberships m
  JOIN care_fixture f ON f.plant_id = m.plant_id WHERE m.free_slot IS NOT NULL),
  1::bigint, 'Enable never assigns automatic slots');
SELECT ok((SELECT free_selection_explicit AND free_selection_revision = 7
  FROM public.profiles WHERE id = 'f1610000-0000-4000-8000-000000000001'),
  'Reconcile preserves historical profile selection flags');
SELECT is((SELECT to_jsonb(m) FROM public.basic_care_memberships m
  JOIN care_fixture f ON f.plant_id = m.plant_id WHERE f.k = 1),
  (SELECT body FROM legacy_membership), 'Reconcile preserves the exact legacy membership');
SELECT ok((SELECT bool_and(r.rule_state = 'active' AND t.reminder_eligible
  AND t.inactive_reason IS NULL) FROM care_fixture f
  JOIN public.task_rules r ON r.id = f.rule_id
  JOIN public.care_tasks t ON t.id = f.task_id),
  'Rules and open reminders follow the same predicate for Free and paid');
SELECT is(public.compute_next_available_step(
  'f1610000-0000-4000-8000-000000000001', (SELECT plant_id FROM care_fixture WHERE k = 2),
  'care', false, 'available')->>'next_available_step', 'enable_basic_care',
  'Free next step enables care without choosing plants');
SELECT is(public.compute_next_available_step(
  'f1610000-0000-4000-8000-000000000002', (SELECT plant_id FROM care_fixture WHERE k = 4),
  'care', false, 'available')->>'next_available_step', 'open_plan',
  'Paid active plan readiness is preserved');
SELECT is(public.compute_next_available_step(
  'f1610000-0000-4000-8000-000000000001', (SELECT plant_id FROM care_fixture WHERE k = 2),
  'care', false, 'care_profile_unavailable')->>'next_available_step', 'view_plant',
  'Unavailable care profile still leads to the plant');
SELECT is(public.compute_next_available_step(
  'f1610000-0000-4000-8000-000000000001', (SELECT plant_id FROM care_fixture WHERE k = 2),
  'problem', true, 'available')->>'next_available_step', 'record_first_aid',
  'Diagnosis entry point keeps the first-aid action');

-- A historical receipt is a byte-for-byte JSONB replay, not a new selection.
INSERT INTO public.operation_receipts(
  owner_id, operation_id, command_name, payload_hash, response_payload
) VALUES (
  'f1610000-0000-4000-8000-000000000001', 'f1610000-0000-4000-8000-000000000101',
  'free_care.select', encode(digest('{"selected_plant_ids":[]}'::jsonb::text, 'sha256'), 'hex'),
  '{"legacy_selection":true,"state":{"free_slot":2}}'::jsonb
);
CREATE TEMP TABLE before_rejection AS SELECT body FROM care_state;
SELECT throws_ok($q$SELECT public.execute_basic_care_command(
  'f1610000-0000-4000-8000-000000000001', 'f1610000-0000-4000-8000-000000000102',
  'free_care.select', '{"selected_plant_ids":[]}'::jsonb)$q$,
  '22023', 'FREE_SELECTION_RETIRED', 'New selection is retired');
SELECT is(public.execute_basic_care_command(
  'f1610000-0000-4000-8000-000000000001', 'f1610000-0000-4000-8000-000000000101',
  'free_care.select', '{"selected_plant_ids":[]}'::jsonb),
  '{"legacy_selection":true,"state":{"free_slot":2}}'::jsonb,
  'Historical selection response is returned verbatim, including historical keys');
SELECT throws_ok($q$SELECT public.execute_basic_care_command(
  'f1610000-0000-4000-8000-000000000001', 'f1610000-0000-4000-8000-000000000101',
  'free_care.select', '{"selected_plant_ids":["different"]}'::jsonb)$q$,
  '23505', 'operation_payload_mismatch', 'Legacy payload mismatch conflicts before parsing');
SELECT throws_ok($q$SELECT public.execute_basic_care_command(
  'f1610000-0000-4000-8000-000000000001', 'f1610000-0000-4000-8000-000000000101',
  'basic_care.enable', '{"selected_plant_ids":[]}'::jsonb)$q$,
  '23505', 'operation_payload_mismatch', 'Same operation with a different command conflicts');
SELECT throws_ok($q$SELECT public.execute_basic_care_command(
  'f1610000-0000-4000-8000-000000000001', 'f1610000-0000-4000-8000-000000000102',
  NULL, '{}'::jsonb)$q$, '22023', 'unsupported_basic_care_command', 'Null command is rejected');
SELECT throws_ok($q$SELECT public.execute_basic_care_command(
  'f1610000-0000-4000-8000-000000000001', 'f1610000-0000-4000-8000-000000000102',
  'unknown', '{}'::jsonb)$q$, '22023', 'unsupported_basic_care_command', 'Unknown command is rejected');
SELECT throws_ok($q$SELECT public.execute_basic_care_command(
  'f1610000-0000-4000-8000-000000000002', 'f1610000-0000-4000-8000-000000000102',
  'basic_care.enable', jsonb_build_object('plant_id', plant_id))
  FROM care_fixture WHERE k = 1$q$, 'P0002', 'plant_not_found', 'Other owner cannot enable care');
SELECT throws_ok($q$SELECT public.execute_basic_care_command(
  'f1610000-0000-4000-8000-000000000002', 'f1610000-0000-4000-8000-000000000102',
  'basic_care.disable', jsonb_build_object('plant_id', plant_id))
  FROM care_fixture WHERE k = 1$q$, 'P0002', 'plant_not_found', 'Other owner cannot disable care');
SELECT is((SELECT body FROM care_state), (SELECT body FROM before_rejection),
  'Rejections and historical replay mutate no watermark, receipt, membership, rule or task');

CREATE TEMP TABLE before_retry AS SELECT body FROM care_state;
SELECT is(public.execute_basic_care_command(
  owner_id, md5('t161-enable-' || k)::uuid, 'basic_care.enable',
  jsonb_build_object('plant_id', plant_id)),
  (SELECT response_payload FROM public.operation_receipts r
   WHERE r.owner_id = f.owner_id AND r.operation_id = md5('t161-enable-' || f.k)::uuid),
  'Exact enable retry returns the saved receipt')
FROM care_fixture f WHERE k = 2;
SELECT is((SELECT body FROM care_state), (SELECT body FROM before_retry),
  'Enable retry is side-effect free');

SELECT lives_ok($q$SELECT public.execute_basic_care_command(
  owner_id, 'f1610000-0000-4000-8000-000000000103', 'basic_care.disable',
  jsonb_build_object('plant_id', plant_id)) FROM care_fixture WHERE k = 1$q$,
  'Owner can disable a legacy membership');
SELECT ok((SELECT NOT m.enabled AND m.free_slot IS NULL
  AND m.id = (b.body->>'id')::uuid AND m.enabled_at = (b.body->>'enabled_at')::timestamptz
  FROM public.basic_care_memberships m
  JOIN care_fixture f ON f.plant_id = m.plant_id CROSS JOIN legacy_membership b WHERE f.k = 1),
  'Disable clears only the constrained legacy slot and preserves identity/enabled_at');
SELECT ok((SELECT r.rule_state = 'paused' AND NOT t.reminder_eligible
  FROM care_fixture f JOIN public.task_rules r ON r.id = f.rule_id
  JOIN public.care_tasks t ON t.id = f.task_id WHERE f.k = 1),
  'Disable pauses rule and reminder');
TRUNCATE before_retry;
INSERT INTO before_retry SELECT body FROM care_state;
SELECT lives_ok($q$SELECT public.execute_basic_care_command(
  owner_id, 'f1610000-0000-4000-8000-000000000103', 'basic_care.disable',
  jsonb_build_object('plant_id', plant_id)) FROM care_fixture WHERE k = 1$q$,
  'Disable exact retry succeeds');
SELECT is((SELECT body FROM care_state), (SELECT body FROM before_retry),
  'Disable retry changes nothing');
SELECT lives_ok($q$SELECT public.execute_basic_care_command(
  owner_id, 'f1610000-0000-4000-8000-000000000104', 'basic_care.enable',
  jsonb_build_object('plant_id', plant_id)) FROM care_fixture WHERE k = 1$q$,
  'Re-enable succeeds without a selection');
SELECT ok((SELECT m.enabled AND m.free_slot IS NULL
  AND m.enabled_at = (b.body->>'enabled_at')::timestamptz
  FROM public.basic_care_memberships m
  JOIN care_fixture f ON f.plant_id = m.plant_id CROSS JOIN legacy_membership b WHERE f.k = 1),
  'Re-enable preserves ordering history and never reassigns a slot');

-- Applicability is checked using real persisted plan/context columns.
UPDATE public.care_plans cp SET state = 'superseded'
FROM care_fixture f WHERE cp.id = f.plan_id AND f.k = 2;
SELECT public.reconcile_owner_basic_care('f1610000-0000-4000-8000-000000000001');
SELECT ok((SELECT NOT allowed FROM care_eligibility WHERE k = 2),
  'Superseded plan cannot schedule');
SELECT ok((SELECT r.rule_state = 'paused' AND NOT t.reminder_eligible
  FROM care_fixture f JOIN public.task_rules r ON r.id = f.rule_id
  JOIN public.care_tasks t ON t.id = f.task_id WHERE f.k = 2),
  'Reconcile pauses tasks for an inapplicable plan');
UPDATE public.care_plans cp SET state = 'active', context_revision = 2
FROM care_fixture f WHERE cp.id = f.plan_id AND f.k = 2;
SELECT ok((SELECT NOT allowed FROM care_eligibility WHERE k = 2),
  'Plan from a different care revision cannot schedule');
UPDATE public.care_plans cp SET context_revision = 1
FROM care_fixture f WHERE cp.id = f.plan_id AND f.k = 2;
SELECT ok((SELECT NOT public.can_owner_schedule_rule(owner_id, plant_id, 'basic_care',
  (SELECT plan_id FROM care_fixture WHERE k = 4), NULL) FROM care_fixture WHERE k = 2),
  'Foreign owner/plant plan is not applicable');
UPDATE public.basic_care_memberships m SET deleted_at = clock_timestamp()
FROM care_fixture f WHERE m.plant_id = f.plant_id AND f.k = 3;
SELECT public.reconcile_owner_basic_care('f1610000-0000-4000-8000-000000000001');
SELECT ok((SELECT NOT allowed FROM care_eligibility WHERE k = 3),
  'Deleted membership cannot schedule');
SELECT ok((SELECT r.rule_state = 'paused' AND NOT t.reminder_eligible
  FROM care_fixture f JOIN public.task_rules r ON r.id = f.rule_id
  JOIN public.care_tasks t ON t.id = f.task_id WHERE f.k = 3),
  'Deleted membership also pauses existing reminders');
SELECT lives_ok($q$SELECT public.execute_basic_care_command(
  owner_id, 'f1610000-0000-4000-8000-000000000105', 'basic_care.enable',
  jsonb_build_object('plant_id', plant_id)) FROM care_fixture WHERE k = 3$q$,
  'Enable restores the same soft-deleted membership');

CREATE TEMP TABLE paid_membership_history AS
SELECT jsonb_agg(to_jsonb(m) ORDER BY m.id) AS body
FROM public.basic_care_memberships m JOIN care_fixture f ON f.plant_id = m.plant_id WHERE f.k >= 4;
-- Keep state active first: verified expiry dates, not only state, stop care.
UPDATE public.entitlements SET valid_until = clock_timestamp() - interval '1 second'
WHERE owner_id = 'f1610000-0000-4000-8000-000000000002';
SELECT public.reconcile_owner_basic_care('f1610000-0000-4000-8000-000000000002');
SELECT ok((SELECT bool_and(NOT allowed) FROM care_eligibility WHERE k >= 4),
  'Expired paid dates never fall back to an automatic Free triple');
SELECT ok((SELECT bool_and(r.rule_state = 'paused' AND NOT t.reminder_eligible)
  FROM care_fixture f JOIN public.task_rules r ON r.id = f.rule_id
  JOIN public.care_tasks t ON t.id = f.task_id WHERE f.k >= 4),
  'Expiry consistently pauses all four basic rules and reminders');
SELECT is((SELECT jsonb_agg(to_jsonb(m) ORDER BY m.id)
  FROM public.basic_care_memberships m JOIN care_fixture f ON f.plant_id = m.plant_id WHERE f.k >= 4),
  (SELECT body FROM paid_membership_history), 'Expiry reconcile preserves all memberships verbatim');
SELECT is((SELECT count(*) FROM public.plants
  WHERE owner_id = 'f1610000-0000-4000-8000-000000000002' AND deleted_at IS NULL),
  4::bigint, 'Expiry retains the over-cap collection');
SELECT is(public.compute_next_available_step(
  'f1610000-0000-4000-8000-000000000002', (SELECT plant_id FROM care_fixture WHERE k = 4),
  'care', false, 'available')->>'next_available_step', 'view_plant',
  'Expired owner is not directed to enable automatic Free care');

UPDATE public.entitlements SET state = 'revoked', valid_until = clock_timestamp() + interval '1 day'
WHERE owner_id = 'f1610000-0000-4000-8000-000000000002';
SELECT ok((SELECT bool_and(NOT allowed) FROM care_eligibility WHERE k >= 4),
  'Revoked entitlement cannot regain Free care');
UPDATE public.entitlements SET state = 'billing_retry'
WHERE owner_id = 'f1610000-0000-4000-8000-000000000002';
SELECT ok((SELECT bool_and(NOT allowed) FROM care_eligibility WHERE k >= 4),
  'Billing retry cannot regain Free care');
UPDATE public.entitlements SET state = 'expired'
WHERE owner_id = 'f1610000-0000-4000-8000-000000000002';
SELECT ok((SELECT bool_and(NOT allowed) FROM care_eligibility WHERE k >= 4),
  'Expired state cannot regain Free care even with a future date');
UPDATE public.entitlements SET state = 'grace'
WHERE owner_id = 'f1610000-0000-4000-8000-000000000002';
SELECT public.reconcile_owner_basic_care('f1610000-0000-4000-8000-000000000002');
SELECT ok((SELECT bool_and(allowed) FROM care_eligibility WHERE k >= 4),
  'Verified grace retains paid basic care for all memberships');
SELECT ok((SELECT bool_and(r.rule_state = 'active' AND t.reminder_eligible)
  FROM care_fixture f JOIN public.task_rules r ON r.id = f.rule_id
  JOIN public.care_tasks t ON t.id = f.task_id WHERE f.k >= 4),
  'Renewed rights consistently restore eligible rules and reminders');

SELECT ok(NOT (public.reconcile_owner_basic_care('f1610000-0000-4000-8000-000000000001')
  ?| ARRAY['free_selection_explicit', 'free_selection_revision'])
  AND NOT EXISTS (
    SELECT 1 FROM jsonb_array_elements(public.reconcile_owner_basic_care(
      'f1610000-0000-4000-8000-000000000001')->'memberships') m
    WHERE m ?| ARRAY['free_slot', 'selection_revision']
  ), 'New basic-care state omits retired selection keys');
SELECT ok(NOT (public.fetch_sync_delta('f1610000-0000-4000-8000-000000000001')->'profile'
  ?| ARRAY['free_selection_explicit', 'free_selection_revision']),
  'Sync profile omits retired selection keys');
SELECT ok(NOT EXISTS (
  SELECT 1 FROM public.owner_sync_entries e
  JOIN care_fixture f ON f.plant_id::text = e.data->>'plant_id'
  WHERE e.entity_type = 'basic_care_memberships'
    AND e.data ?| ARRAY['free_slot', 'selection_revision']
), 'Membership sync omits retired slot keys');
SELECT ok(NOT EXISTS (
  SELECT 1 FROM public.owner_sync_entries
  WHERE entity_type = 'rooms' OR (entity_type = 'plants' AND data ? 'room_id')
), 'Latest room retirement is preserved');
SELECT ok(has_function_privilege('service_role',
  'public.execute_basic_care_command(uuid,uuid,text,jsonb)', 'EXECUTE')
  AND NOT has_function_privilege('anon',
    'public.execute_basic_care_command(uuid,uuid,text,jsonb)', 'EXECUTE')
  AND NOT has_function_privilege('authenticated',
    'public.execute_basic_care_command(uuid,uuid,text,jsonb)', 'EXECUTE'),
  'Service-only command privileges remain in force');

-- Soft-delete preserves the membership row/history and pauses existing care.
UPDATE public.plants p SET deleted_at = clock_timestamp()
FROM care_fixture f WHERE p.id = f.plant_id AND f.k = 2;
SELECT ok((SELECT NOT m.enabled AND m.deleted_at IS NOT NULL
  FROM public.basic_care_memberships m JOIN care_fixture f ON f.plant_id = m.plant_id WHERE f.k = 2),
  'Soft-delete retains and disables the same membership');
SELECT ok((SELECT NOT allowed FROM care_eligibility WHERE k = 2),
  'Deleted plant cannot schedule');
SELECT ok((SELECT NOT t.reminder_eligible FROM public.care_tasks t
  JOIN care_fixture f ON f.task_id = t.id WHERE f.k = 2),
  'Soft-delete also pauses existing basic reminders');

UPDATE public.profiles SET account_state = 'deleting'
WHERE id = 'f1610000-0000-4000-8000-000000000002';
SELECT lives_ok($q$UPDATE public.plants SET deleted_at = clock_timestamp()
  WHERE id = (SELECT plant_id FROM care_fixture WHERE k = 4)$q$,
  'Soft-delete reconciliation does not block account teardown');
SELECT ok((SELECT bool_and(NOT t.reminder_eligible)
  FROM care_fixture f JOIN public.care_tasks t ON t.id = f.task_id WHERE f.k >= 4),
  'Inactive owner reconciliation pauses basic reminders');

SELECT * FROM finish();
ROLLBACK;
