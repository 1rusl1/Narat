-- 202610200011_schedule_calculator.sql
-- T018: SQL calculate_plant_schedule and unified SQL access predicate for basic_care, first_aid_control, and premium tasks.

CREATE OR REPLACE FUNCTION public.has_verified_paid_access(
  p_owner_id UUID,
  p_now TIMESTAMPTZ DEFAULT now()
)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.entitlements e
    JOIN public.profiles p ON p.id = e.owner_id
    WHERE e.owner_id = p_owner_id
      AND p.account_state = 'active'
      AND e.state IN ('active', 'grace')
      AND e.valid_until IS NOT NULL
      AND e.valid_until > p_now
      AND (
        e.offer_kind = 'paid'
        OR (e.offer_kind = 'trial' AND e.trial_end_at IS NOT NULL AND e.trial_end_at > p_now)
      )
  );
$$;

CREATE OR REPLACE FUNCTION public.can_owner_schedule_rule(
  p_owner_id UUID,
  p_plant_id UUID,
  p_access_class TEXT,
  p_plan_id UUID,
  p_first_aid_id UUID,
  p_now TIMESTAMPTZ DEFAULT now()
)
RETURNS BOOLEAN
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_has_paid BOOLEAN;
  v_plant_active BOOLEAN;
BEGIN
  SELECT EXISTS (
    SELECT 1
    FROM public.plants pl
    JOIN public.profiles pr ON pr.id = pl.owner_id
    WHERE pl.id = p_plant_id
      AND pl.owner_id = p_owner_id
      AND pl.deleted_at IS NULL
      AND pr.account_state = 'active'
  ) INTO v_plant_active;

  IF NOT v_plant_active THEN
    RETURN FALSE;
  END IF;

  v_has_paid := public.has_verified_paid_access(p_owner_id, p_now);

  IF p_access_class = 'basic_care' THEN
    IF p_plan_id IS NULL OR p_first_aid_id IS NOT NULL THEN
      RETURN FALSE;
    END IF;

    -- Must reference an active applicable plan
    IF NOT EXISTS (
      SELECT 1
      FROM public.care_plans cp
      WHERE cp.id = p_plan_id
        AND cp.owner_id = p_owner_id
        AND cp.plant_id = p_plant_id
        AND cp.state = 'active'
        AND cp.applicability_status = 'applicable'
        AND cp.deleted_at IS NULL
    ) THEN
      RETURN FALSE;
    END IF;

    IF v_has_paid THEN
      RETURN EXISTS (
        SELECT 1
        FROM public.basic_care_memberships m
        WHERE m.owner_id = p_owner_id
          AND m.plant_id = p_plant_id
          AND m.enabled = TRUE
          AND m.deleted_at IS NULL
      );
    END IF;

    RETURN EXISTS (
      SELECT 1
      FROM public.basic_care_memberships m
      WHERE m.owner_id = p_owner_id
        AND m.plant_id = p_plant_id
        AND m.enabled = TRUE
        AND m.free_slot BETWEEN 1 AND 3
        AND m.deleted_at IS NULL
    );

  ELSIF p_access_class = 'first_aid_control' THEN
    IF p_first_aid_id IS NULL OR p_plan_id IS NOT NULL THEN
      RETURN FALSE;
    END IF;

    RETURN EXISTS (
      SELECT 1
      FROM public.first_aid_followups f
      WHERE f.id = p_first_aid_id
        AND f.owner_id = p_owner_id
        AND f.plant_id = p_plant_id
        AND f.state = 'active'
        AND f.deleted_at IS NULL
        AND f.first_action_entry_id IS NOT NULL
        AND f.control_interval_days IS NOT NULL
    );

  ELSIF p_access_class = 'premium' THEN
    IF NOT v_has_paid OR p_plan_id IS NULL OR p_first_aid_id IS NOT NULL THEN
      RETURN FALSE;
    END IF;

    RETURN EXISTS (
      SELECT 1
      FROM public.care_plans cp
      WHERE cp.id = p_plan_id
        AND cp.owner_id = p_owner_id
        AND cp.plant_id = p_plant_id
        AND cp.access_tier = 'full'
        AND cp.state = 'active'
        AND cp.applicability_status = 'applicable'
        AND cp.deleted_at IS NULL
        AND (
          cp.chemical_Must_Revalidate_After IS NULL
          OR cp.chemical_must_revalidate_after >= (p_now AT TIME ZONE 'UTC')::DATE
        )
    );
  END IF;

  RETURN FALSE;
END;
$$;

CREATE OR REPLACE FUNCTION public.calculate_plant_schedule(
  p_owner_id UUID,
  p_plant_id UUID,
  p_reference_date DATE DEFAULT CURRENT_DATE,
  p_now TIMESTAMPTZ DEFAULT now()
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_ts TIMESTAMPTZ;
  v_rule RECORD;
  v_can_schedule BOOLEAN;
  v_last_entry RECORD;
  v_open_task RECORD;
  v_due_date DATE;
  v_condition_code TEXT;
  v_last_watered TEXT;
  v_completed_repeats INT;
  v_created_count INT := 0;
  v_updated_count INT := 0;
  v_paused_count INT := 0;
  v_new_task_id UUID;
BEGIN
  -- Serialize on owner profile and obtain monotonic watermark
  v_ts := public.advance_owner_watermark(p_owner_id);

  -- Read latest condition snapshot's last_watered for check_soil_first evaluation
  SELECT cs.last_watered
  INTO v_last_watered
  FROM public.plants pl
  LEFT JOIN public.condition_snapshots cs ON cs.id = pl.current_snapshot_id
  WHERE pl.id = p_plant_id
    AND pl.owner_id = p_owner_id
    AND pl.deleted_at IS NULL;

  FOR v_rule IN
    SELECT tr.*
    FROM public.task_rules tr
    WHERE tr.owner_id = p_owner_id
      AND tr.plant_id = p_plant_id
      AND tr.deleted_at IS NULL
    ORDER BY tr.created_at ASC, tr.id ASC
  LOOP
    v_can_schedule := (
      v_rule.rule_state = 'active'
      AND public.can_owner_schedule_rule(
        p_owner_id,
        p_plant_id,
        v_rule.access_class,
        v_rule.plan_id,
        v_rule.first_aid_id,
        p_now
      )
    );

    -- Check existing open/needs_review occurrence for this rule
    SELECT ct.*
    INTO v_open_task
    FROM public.care_tasks ct
    WHERE ct.owner_id = p_owner_id
      AND ct.plant_id = p_plant_id
      AND ct.rule_id = v_rule.id
      AND ct.status IN ('open', 'needs_review')
      AND ct.deleted_at IS NULL
    LIMIT 1;

    IF NOT v_can_schedule THEN
      -- If rule is paused or lost eligibility (e.g., Free slot unassigned or subscription expired),
      -- preserve history and mark any open occurrence reminder_eligible = false without deleting care_entries.
      IF v_open_task.id IS NOT NULL AND v_open_task.reminder_eligible = TRUE THEN
        UPDATE public.care_tasks
        SET reminder_eligible = FALSE,
            inactive_reason = CASE
              WHEN v_rule.rule_state = 'paused' THEN 'rule_paused'
              WHEN v_rule.access_class = 'basic_care' THEN 'free_slot_unassigned'
              WHEN v_rule.access_class = 'premium' THEN 'subscription_expired'
              ELSE 'rule_inactive'
            END,
            updated_at = v_ts
        WHERE id = v_open_task.id;
        v_paused_count := v_paused_count + 1;
      END IF;
      CONTINUE;
    END IF;

    -- Check repeat limit if max_repeats is specified (e.g., treatment protocol or single first_aid_control)
    IF v_rule.max_repeats IS NOT NULL THEN
      SELECT COUNT(*)
      INTO v_completed_repeats
      FROM public.care_tasks ct
      JOIN public.care_entries ce ON ce.task_id = ct.id
      WHERE ct.owner_id = p_owner_id
        AND ct.rule_id = v_rule.id
        AND ct.status = 'completed'
        AND ct.deleted_at IS NULL
        AND ce.undone_at IS NULL
        AND ce.deleted_at IS NULL;

      IF v_completed_repeats >= v_rule.max_repeats THEN
        CONTINUE;
      END IF;
    END IF;

    -- Find latest non-undone care_entry for this rule (or matching action_type for basic_care/routine)
    SELECT ce.id, ce.performed_date
    INTO v_last_entry
    FROM public.care_entries ce
    WHERE ce.owner_id = p_owner_id
      AND ce.plant_id = p_plant_id
      AND ce.undone_at IS NULL
      AND ce.deleted_at IS NULL
      AND (
        (v_rule.access_class = 'first_aid_control' AND ce.id = (
          SELECT f.first_action_entry_id
          FROM public.first_aid_followups f
          WHERE f.id = v_rule.first_aid_id
        ))
        OR (v_rule.access_class <> 'first_aid_control' AND ce.action_type = v_rule.action_type)
      )
    ORDER BY ce.performed_date DESC, ce.created_at DESC
    LIMIT 1;

    -- Compute due_date and condition_code
    IF v_last_entry.id IS NOT NULL THEN
      v_due_date := v_last_entry.performed_date + v_rule.interval_days;
      v_condition_code := CASE
        WHEN v_rule.condition_code = 'check_soil_first' AND v_rule.action_type = 'water' AND v_rule.access_class = 'basic_care'
          THEN 'check_soil_first'
        ELSE NULL
      END;
    ELSE
      v_due_date := COALESCE(v_rule.start_date, p_reference_date);
      IF v_rule.condition_code = 'check_soil_first'
         OR (v_rule.action_type = 'water' AND COALESCE(v_last_watered, 'unknown') = 'unknown') THEN
        v_condition_code := 'check_soil_first';
        -- First watering when history is unknown starts as a soil check today
        IF v_rule.start_date IS NULL THEN
          v_due_date := p_reference_date;
        END IF;
      ELSE
        v_condition_code := v_rule.condition_code;
      END IF;
    END IF;

    IF v_open_task.id IS NOT NULL THEN
      -- Do not overwrite due_date if task is in needs_review (preserve existing task until reviewed or recorded)
      IF v_open_task.status = 'open' AND (
        v_open_task.due_date <> v_due_date
        OR v_open_task.condition_code IS DISTINCT FROM v_condition_code
        OR v_open_task.reminder_eligible = FALSE
      ) THEN
        UPDATE public.care_tasks
        SET due_date = v_due_date,
            condition_code = v_condition_code,
            reminder_eligible = TRUE,
            inactive_reason = NULL,
            updated_at = v_ts
        WHERE id = v_open_task.id;

        INSERT INTO public.schedule_changes (
          owner_id, plant_id, task_id, previous_due_date, new_due_date,
          reason_code, source_entry_id, created_at, updated_at
        ) VALUES (
          p_owner_id, p_plant_id, v_open_task.id, v_open_task.due_date, v_due_date,
          CASE WHEN v_last_entry.id IS NOT NULL THEN 'RecalculatedFromActualCareDate' ELSE 'InitialSchedule' END,
          v_last_entry.id, v_ts, v_ts
        );
        v_updated_count := v_updated_count + 1;
      END IF;
    ELSE
      -- Create the single open occurrence for this rule
      INSERT INTO public.care_tasks (
        owner_id, plant_id, plan_id, first_aid_id, rule_id, access_class,
        action_type, due_date, status, condition_code, reminder_eligible,
        inactive_reason, comparison_traits, photo_angle_hint,
        created_at, updated_at
      ) VALUES (
        p_owner_id, p_plant_id, v_rule.plan_id, v_rule.first_aid_id, v_rule.id, v_rule.access_class,
        v_rule.action_type, v_due_date, 'open', v_condition_code, TRUE,
        NULL, v_rule.comparison_traits, v_rule.photo_angle_hint,
        v_ts, v_ts
      )
      RETURNING id INTO v_new_task_id;

      IF v_rule.access_class = 'first_aid_control' AND v_rule.first_aid_id IS NOT NULL THEN
        UPDATE public.first_aid_followups
        SET control_task_id = v_new_task_id,
            control_due_date = v_due_date,
            updated_at = v_ts
        WHERE id = v_rule.first_aid_id
          AND owner_id = p_owner_id;
      END IF;

      INSERT INTO public.schedule_changes (
        owner_id, plant_id, task_id, previous_due_date, new_due_date,
        reason_code, source_entry_id, created_at, updated_at
      ) VALUES (
        p_owner_id, p_plant_id, v_new_task_id, NULL, v_due_date,
        CASE WHEN v_last_entry.id IS NOT NULL THEN 'RecalculatedFromActualCareDate' ELSE 'InitialSchedule' END,
        v_last_entry.id, v_ts, v_ts
      );

      v_created_count := v_created_count + 1;
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'plant_id', p_plant_id,
    'created_count', v_created_count,
    'updated_count', v_updated_count,
    'paused_count', v_paused_count,
    'watermark', v_ts
  );
END;
$$;
