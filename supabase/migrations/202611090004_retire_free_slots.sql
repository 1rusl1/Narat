-- T161: retire selection and automatic Free slots without rewriting history.
-- Physical membership/profile fields and legacy operation receipts are retained.
-- No reconciliation is run during upgrade.

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

    -- The persisted schema expresses applicability through plan state and
    -- its source context/snapshot, not the nonexistent applicability_status
    -- column referenced by the original scheduling function.
    RETURN (
      v_has_paid OR NOT EXISTS (
        SELECT 1 FROM public.entitlements e WHERE e.owner_id = p_owner_id
      )
    ) AND EXISTS (
      SELECT 1
      FROM public.care_plans cp
      JOIN public.plants pl ON pl.id = cp.plant_id AND pl.owner_id = cp.owner_id
      JOIN public.basic_care_memberships m
        ON m.owner_id = cp.owner_id AND m.plant_id = cp.plant_id
      WHERE cp.id = p_plan_id
        AND cp.owner_id = p_owner_id
        AND cp.plant_id = p_plant_id
        AND cp.state = 'active'
        AND cp.deleted_at IS NULL
        AND cp.context_revision = pl.care_revision
        AND cp.snapshot_id = pl.current_condition_snapshot_id
        AND m.enabled = TRUE
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

CREATE OR REPLACE FUNCTION public.reconcile_owner_basic_care(p_owner_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_now TIMESTAMPTZ;
  v_has_paid BOOLEAN;
  v_rules_changed INT;
  v_tasks_changed INT;
BEGIN
  PERFORM 1 FROM public.profiles WHERE id = p_owner_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'owner_profile_not_found' USING ERRCODE = 'P0002';
  END IF;
  v_now := clock_timestamp();
  v_has_paid := public.has_verified_paid_access(p_owner_id, v_now);

  -- Reconciliation never writes memberships or historical selection flags.
  -- Missing/disabled/deleted membership and stale/deleted plans all pause.
  UPDATE public.task_rules r
  SET rule_state = CASE WHEN public.can_owner_schedule_rule(
        r.owner_id, r.plant_id, r.access_class, r.plan_id, r.first_aid_id, v_now
      ) THEN 'active' ELSE 'paused' END,
      updated_at = clock_timestamp()
  WHERE r.owner_id = p_owner_id
    AND r.access_class = 'basic_care'
    AND r.rule_state <> 'superseded'
    AND r.deleted_at IS NULL
    AND r.rule_state IS DISTINCT FROM CASE WHEN public.can_owner_schedule_rule(
      r.owner_id, r.plant_id, r.access_class, r.plan_id, r.first_aid_id, v_now
    ) THEN 'active' ELSE 'paused' END;
  GET DIAGNOSTICS v_rules_changed = ROW_COUNT;

  -- Keep the existing inactive_reason vocabulary. An unavailable basic plan
  -- uses plan_superseded; no new reason refers to retired selection slots.
  WITH eligibility AS (
    SELECT t.id,
      (r.rule_state = 'active' AND r.deleted_at IS NULL
       AND t.plant_id = r.plant_id
       AND public.can_owner_schedule_rule(
         r.owner_id, r.plant_id, r.access_class, r.plan_id, r.first_aid_id, v_now
       )) AS allowed
    FROM public.care_tasks t
    JOIN public.task_rules r ON r.id = t.rule_id AND r.owner_id = t.owner_id
    WHERE t.owner_id = p_owner_id
      AND r.access_class = 'basic_care'
      AND t.state IN ('open', 'needs_review')
      AND t.deleted_at IS NULL
  )
  UPDATE public.care_tasks t
  SET reminder_eligible = e.allowed,
      inactive_reason = CASE WHEN e.allowed THEN NULL ELSE 'plan_superseded' END,
      updated_at = clock_timestamp()
  FROM eligibility e
  WHERE t.id = e.id
    AND (t.reminder_eligible IS DISTINCT FROM e.allowed
      OR t.inactive_reason IS DISTINCT FROM
         CASE WHEN e.allowed THEN NULL ELSE 'plan_superseded' END);
  GET DIAGNOSTICS v_tasks_changed = ROW_COUNT;

  IF v_rules_changed > 0 OR v_tasks_changed > 0 THEN
    -- Teardown may reconcile an already inactive owner; do not block deletion.
    UPDATE public.profiles
    SET updated_at = greatest(clock_timestamp(), updated_at + interval '1 microsecond')
    WHERE id = p_owner_id;
  END IF;

  RETURN (
    SELECT jsonb_build_object(
      'has_paid_access', v_has_paid,
      'memberships', coalesce(jsonb_agg(jsonb_build_object(
        'plant_id', m.plant_id,
        'enabled', m.enabled,
        'enabled_at', m.enabled_at
      ) ORDER BY m.enabled_at ASC, m.plant_id ASC), '[]'::jsonb)
    )
    FROM public.basic_care_memberships m
    JOIN public.plants p ON p.id = m.plant_id AND p.owner_id = m.owner_id
    WHERE m.owner_id = p_owner_id
      AND m.deleted_at IS NULL
      AND p.deleted_at IS NULL
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.execute_basic_care_command(
  p_owner_id UUID,
  p_operation_id UUID,
  p_command_type TEXT,
  p_payload JSONB
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  -- Preserve the exact legacy hash, including its handling of SQL NULL.
  v_payload_hash TEXT := encode(digest(coalesce(p_payload::text, '{}'), 'sha256'), 'hex');
  v_state TEXT;
  v_cached JSONB;
  v_plant_id UUID;
  v_reconciled JSONB;
  v_response JSONB;
  v_ts TIMESTAMPTZ;
BEGIN
  -- Serialize before receipt lookup, including concurrent retries.
  SELECT account_state INTO v_state
  FROM public.profiles WHERE id = p_owner_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'owner_profile_not_found' USING ERRCODE = 'P0002';
  END IF;
  IF v_state <> 'active' THEN
    RAISE EXCEPTION 'account_not_active' USING ERRCODE = '42501';
  END IF;

  IF p_command_type IS NULL OR p_command_type NOT IN (
    'basic_care.enable', 'basic_care.disable', 'free_care.select'
  ) THEN
    RAISE EXCEPTION 'unsupported_basic_care_command' USING ERRCODE = '22023';
  END IF;

  v_cached := public.lookup_operation_receipt(
    p_owner_id, p_operation_id, p_command_type, v_payload_hash
  );
  IF v_cached IS NOT NULL THEN
    RETURN v_cached;
  END IF;

  IF p_command_type = 'free_care.select' THEN
    RAISE EXCEPTION 'FREE_SELECTION_RETIRED' USING ERRCODE = '22023';
  END IF;

  v_plant_id := (p_payload->>'plant_id')::uuid;
  IF NOT EXISTS (
    SELECT 1 FROM public.plants
    WHERE id = v_plant_id AND owner_id = p_owner_id AND deleted_at IS NULL
  ) THEN
    RAISE EXCEPTION 'plant_not_found' USING ERRCODE = 'P0002';
  END IF;

  IF p_command_type = 'basic_care.enable' THEN
    INSERT INTO public.basic_care_memberships (
      owner_id, plant_id, enabled_at, enabled
    ) VALUES (
      p_owner_id, v_plant_id, clock_timestamp(), true
    )
    ON CONFLICT (owner_id, plant_id) DO UPDATE
    SET enabled = true,
        deleted_at = NULL,
        updated_at = clock_timestamp();
  ELSE
    -- The legacy slot_requires_enabled constraint requires this one explicit
    -- clear on disable. Reconcile/upgrade never clears historical slots.
    UPDATE public.basic_care_memberships
    SET enabled = false,
        free_slot = NULL,
        updated_at = clock_timestamp()
    WHERE owner_id = p_owner_id AND plant_id = v_plant_id
      AND deleted_at IS NULL
      AND (enabled OR free_slot IS NOT NULL);
  END IF;

  v_reconciled := public.reconcile_owner_basic_care(p_owner_id);
  v_ts := public.advance_owner_watermark(p_owner_id);
  v_response := jsonb_build_object(
    'status', 'committed',
    'command_type', p_command_type,
    'state', v_reconciled
  );

  RETURN public.save_operation_receipt(
    p_owner_id, p_operation_id, p_command_type, v_payload_hash, v_response, v_ts
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.compute_next_available_step(
  p_owner_id UUID,
  p_plant_id UUID,
  p_intent TEXT,
  p_has_diagnosis BOOLEAN,
  p_plan_availability TEXT,
  p_now TIMESTAMPTZ DEFAULT now()
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_has_paid BOOLEAN;
  v_has_first_aid BOOLEAN;
  v_has_active_plan BOOLEAN;
  v_step TEXT;
  v_paid_action TEXT := NULL;
BEGIN
  v_has_paid := public.has_verified_paid_access(p_owner_id, p_now);

  SELECT EXISTS (
    SELECT 1 FROM public.care_plans cp
    WHERE cp.owner_id = p_owner_id
      AND cp.plant_id = p_plant_id
      AND cp.state = 'active'
      AND cp.deleted_at IS NULL
  ) INTO v_has_active_plan;

  SELECT EXISTS (
    SELECT 1 FROM public.first_aid_followups f
    WHERE f.owner_id = p_owner_id
      AND f.plant_id = p_plant_id
      AND f.state = 'active'
      AND f.deleted_at IS NULL
  ) INTO v_has_first_aid;

  IF p_intent = 'problem' AND p_has_diagnosis THEN
    IF v_has_first_aid THEN
      v_step := 'open_first_aid_control';
    ELSE
      v_step := 'record_first_aid';
    END IF;
    IF p_plan_availability = 'available' THEN
      v_paid_action := 'generate_full_recovery_plan';
    END IF;
  ELSE
    IF p_plan_availability <> 'available' THEN
      v_step := 'view_plant';
    ELSIF v_has_active_plan AND v_has_paid THEN
      v_step := 'open_plan';
    ELSIF v_has_paid OR NOT EXISTS (
      SELECT 1 FROM public.entitlements e WHERE e.owner_id = p_owner_id
    ) THEN
      v_step := 'enable_basic_care';
      IF NOT v_has_paid THEN
        v_paid_action := 'generate_full_routine_plan';
      END IF;
    ELSE
      -- An expired/revoked/retrying entitlement never re-enables Free care.
      v_step := 'view_plant';
      v_paid_action := 'generate_full_routine_plan';
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'next_available_step', v_step,
    'paid_action', v_paid_action,
    'plan_availability', p_plan_availability
  );
END;
$$;

-- Preserve the latest room retirement and every other projection verbatim.
CREATE OR REPLACE VIEW public.owner_sync_entries AS
    -- Plants (historical rooms are no longer synchronized)

    SELECT
        p.owner_id,
        'plants'::text AS entity_type,
        p.id,
        p.updated_at,
        p.deleted_at,
        CASE WHEN p.deleted_at IS NOT NULL THEN NULL ELSE jsonb_build_object(
            'id', p.id,
            'origin_flow_id', p.origin_flow_id,
            'creation_intent', p.creation_intent,
            'add_method', p.add_method,
            'personal_name', p.personal_name,
            'display_name', p.personal_name,
            'taxon_id', p.taxon_id,
            'plant_id', p.plant_id,
            'cultivar_label', p.cultivar_label,
            'main_photo_id', p.main_photo_id,
            'current_condition_snapshot_id', p.current_condition_snapshot_id,
            'origin_draft_id', p.origin_draft_id,
            'creation_source', p.creation_source,
            'revision', p.revision,
            'care_revision', p.care_revision,
            'created_at', p.created_at
        ) END AS data
    FROM public.plants p
    UNION ALL
    -- 3. condition_snapshots
    SELECT
        cs.owner_id,
        'condition_snapshots'::text AS entity_type,
        cs.id,
        cs.updated_at,
        cs.deleted_at,
        CASE WHEN cs.deleted_at IS NOT NULL THEN NULL ELSE jsonb_build_object(
            'id', cs.id,
            'plant_id', cs.plant_id,
            'version', cs.version,
            'light_code', cs.light_code,
            'light_source', cs.light_source,
            'light_confirmed', cs.light_confirmed,
            'watering_code', cs.watering_code,
            'drainage_code', cs.drainage_code,
            'pot_type', cs.pot_type,
            'season_override', cs.season_override,
            'created_at', cs.created_at
        ) END AS data
    FROM public.condition_snapshots cs
    WHERE cs.plant_id IS NOT NULL
    UNION ALL
    -- 4. photo_assets (safe metadata only; no storage keys or signed URLs)
    SELECT
        pa.owner_id,
        'photo_assets'::text AS entity_type,
        pa.id,
        pa.updated_at,
        pa.deleted_at,
        CASE WHEN pa.deleted_at IS NOT NULL THEN NULL ELSE jsonb_build_object(
            'id', pa.id,
            'plant_id', pa.plant_id,
            'purpose', pa.purpose,
            'content_hash', pa.content_hash,
            'capture_at', pa.capture_at,
            'uploaded_at', pa.uploaded_at,
            'state', pa.state
        ) END AS data
    FROM public.photo_assets pa
    WHERE pa.plant_id IS NOT NULL
    UNION ALL
    -- 5. analysis_summaries (free projection without raw internal objects)
    SELECT
        ar.owner_id,
        'analysis_summaries'::text AS entity_type,
        ar.id,
        ar.updated_at,
        ar.deleted_at,
        CASE WHEN ar.deleted_at IS NOT NULL THEN NULL ELSE jsonb_build_object(
            'id', ar.id,
            'origin_analysis_id', ar.origin_analysis_id,
            'mode', ar.mode,
            'plant_id', ar.plant_id,
            'source_photo_id', ar.source_photo_id,
            'source_snapshot_id', ar.source_snapshot_id,
            'source_care_revision', ar.source_care_revision,
            'locale', ar.locale,
            'kb_release_id', ar.kb_release_id,
            'protocol_id', ar.protocol_id,
            'identification', ar.identification,
            'diagnosis_status', ar.diagnosis_status,
            'probable_cause', ar.probable_cause,
            'evidence_basis', ar.evidence_basis,
            'limitations', ar.limitations,
            'first_action', ar.first_action,
            'context_state', ar.context_state,
            'created_at', ar.created_at
        ) END AS data
    FROM public.analysis_results ar
    WHERE ar.plant_id IS NOT NULL
    UNION ALL
    -- 6. care_plan_summaries (excludes full_body)
    SELECT
        cp.owner_id,
        'care_plan_summaries'::text AS entity_type,
        cp.id,
        cp.updated_at,
        cp.deleted_at,
        CASE WHEN cp.deleted_at IS NOT NULL THEN NULL ELSE jsonb_build_object(
            'id', cp.id,
            'plant_id', cp.plant_id,
            'locale', cp.locale,
            'plan_kind', cp.plan_kind,
            'access_tier', cp.access_tier,
            'source_kind', cp.source_kind,
            'source_analysis_id', cp.source_analysis_id,
            'snapshot_id', cp.snapshot_id,
            'kb_release_id', cp.kb_release_id,
            'context_revision', cp.context_revision,
            'version', cp.version,
            'next_check_date', cp.next_check_date,
            'comparison_traits', cp.comparison_traits,
            'photo_angle_hint', cp.photo_angle_hint,
            'state', cp.state,
            'created_at', cp.created_at
        ) END AS data
    FROM public.care_plans cp
    UNION ALL
    -- 7. care_tasks
    SELECT
        ct.owner_id,
        'care_tasks'::text AS entity_type,
        ct.id,
        ct.updated_at,
        ct.deleted_at,
        CASE WHEN ct.deleted_at IS NOT NULL THEN NULL ELSE jsonb_build_object(
            'id', ct.id,
            'plant_id', ct.plant_id,
            'rule_id', ct.rule_id,
            'occurrence_key', ct.occurrence_key,
            'action_code', ct.action_code,
            'due_local_date', ct.due_local_date,
            'timezone', ct.timezone,
            'condition_code', ct.condition_code,
            'reminder_eligible', ct.reminder_eligible,
            'inactive_reason', ct.inactive_reason,
            'localized_reason_snapshot', ct.localized_reason_snapshot,
            'comparison_traits', ct.comparison_traits,
            'photo_angle_hint', ct.photo_angle_hint,
            'state', ct.state,
            'revision', ct.revision,
            'completed_entry_id', ct.completed_entry_id
        ) END AS data
    FROM public.care_tasks ct
    UNION ALL
    -- 8. care_entries
    SELECT
        ce.owner_id,
        'care_entries'::text AS entity_type,
        ce.id,
        ce.updated_at,
        ce.deleted_at,
        CASE WHEN ce.deleted_at IS NOT NULL THEN NULL ELSE jsonb_build_object(
            'id', ce.id,
            'plant_id', ce.plant_id,
            'task_id', ce.task_id,
            'action_code', ce.action_code,
            'occurred_at', ce.occurred_at,
            'occurred_local_date', ce.occurred_local_date,
            'timezone', ce.timezone,
            'recorded_at', ce.recorded_at,
            'state', ce.state,
            'operation_id', ce.operation_id
        ) END AS data
    FROM public.care_entries ce
    UNION ALL
    -- 9. care_reversals
    SELECT
        cr.owner_id,
        'care_reversals'::text AS entity_type,
        cr.id,
        cr.updated_at,
        cr.deleted_at,
        CASE WHEN cr.deleted_at IS NOT NULL THEN NULL ELSE jsonb_build_object(
            'id', cr.id,
            'entry_id', cr.entry_id,
            'operation_id', cr.operation_id,
            'recorded_at', cr.recorded_at
        ) END AS data
    FROM public.care_reversals cr
    UNION ALL
    -- 10. schedule_changes
    SELECT
        sc.owner_id,
        'schedule_changes'::text AS entity_type,
        sc.id,
        sc.updated_at,
        sc.deleted_at,
        CASE WHEN sc.deleted_at IS NOT NULL THEN NULL ELSE jsonb_build_object(
            'id', sc.id,
            'plant_id', sc.plant_id,
            'from_date', sc.from_date,
            'to_date', sc.to_date,
            'cause_code', sc.cause_code,
            'source_event_id', sc.source_event_id,
            'explanation_code', sc.explanation_code,
            'created_at', sc.created_at
        ) END AS data
    FROM public.schedule_changes sc
    UNION ALL
    -- 11. basic_care_memberships
    SELECT
        bcm.owner_id,
        'basic_care_memberships'::text AS entity_type,
        bcm.id,
        bcm.updated_at,
        bcm.deleted_at,
        CASE WHEN bcm.deleted_at IS NOT NULL THEN NULL ELSE jsonb_build_object(
            'id', bcm.id,
            'plant_id', bcm.plant_id,
            'enabled_at', bcm.enabled_at,
            'enabled', bcm.enabled
        ) END AS data
    FROM public.basic_care_memberships bcm
    UNION ALL
    -- 12. first_aid_followups
    SELECT
        faf.owner_id,
        'first_aid_followups'::text AS entity_type,
        faf.id,
        faf.updated_at,
        faf.deleted_at,
        CASE WHEN faf.deleted_at IS NOT NULL THEN NULL ELSE jsonb_build_object(
            'id', faf.id,
            'plant_id', faf.plant_id,
            'origin_analysis_id', faf.origin_analysis_id,
            'decision_revision', faf.decision_revision,
            'kb_release_id', faf.kb_release_id,
            'protocol_id', faf.protocol_id,
            'action_code', faf.action_code,
            'first_action_snapshot', faf.first_action_snapshot,
            'check_policy_snapshot', faf.check_policy_snapshot,
            'action_entry_id', faf.action_entry_id,
            'control_task_id', faf.control_task_id,
            'context_revision', faf.context_revision,
            'state', faf.state
        ) END AS data
    FROM public.first_aid_followups faf
    UNION ALL
    -- 13. care_observations
    SELECT
        co.owner_id,
        'care_observations'::text AS entity_type,
        co.id,
        co.updated_at,
        co.deleted_at,
        CASE WHEN co.deleted_at IS NOT NULL THEN NULL ELSE jsonb_build_object(
            'id', co.id,
            'plant_id', co.plant_id,
            'task_id', co.task_id,
            'status_code', co.status_code,
            'note', co.note,
            'photo_id', co.photo_id,
            'observed_at', co.observed_at,
            'operation_id', co.operation_id
        ) END AS data
    FROM public.care_observations co
    UNION ALL
    -- 14. recovery_transitions
    SELECT
        rt.owner_id,
        'recovery_transitions'::text AS entity_type,
        rt.id,
        rt.updated_at,
        rt.deleted_at,
        CASE WHEN rt.deleted_at IS NOT NULL THEN NULL ELSE jsonb_build_object(
            'id', rt.id,
            'plant_id', rt.plant_id,
            'recovery_plan_id', rt.recovery_plan_id,
            'observation_id', rt.observation_id,
            'expected_care_revision', rt.expected_care_revision,
            'state', rt.state,
            'routine_plan_id', rt.routine_plan_id,
            'created_at', rt.created_at
        ) END AS data
    FROM public.recovery_transitions rt
    UNION ALL
    -- 15. notification_claim_summaries
    SELECT
        nc.owner_id,
        'notification_claim_summaries'::text AS entity_type,
        nc.id,
        nc.updated_at,
        nc.deleted_at,
        CASE WHEN nc.deleted_at IS NOT NULL THEN NULL ELSE jsonb_build_object(
            'id', nc.id,
            'kind', nc.kind,
            'period_key', nc.period_key,
            'installation_id', nc.installation_id,
            'scheduled_at', nc.scheduled_at,
            'state', nc.state
        ) END AS data
    FROM public.notification_claims nc;

CREATE OR REPLACE FUNCTION public.fetch_sync_delta(
    p_owner_id UUID,
    p_since TIMESTAMPTZ DEFAULT NULL,
    p_until TIMESTAMPTZ DEFAULT NULL,
    p_cursor_updated_at TIMESTAMPTZ DEFAULT NULL,
    p_cursor_entity_type TEXT DEFAULT NULL,
    p_cursor_id UUID DEFAULT NULL,
    p_limit INT DEFAULT 200
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_profile RECORD;
    v_entitlement RECORD;
    v_until TIMESTAMPTZ;
    v_rows JSONB;
    v_count INT;
    v_last_updated_at TIMESTAMPTZ;
    v_last_entity_type TEXT;
    v_last_id UUID;
    v_has_more BOOLEAN := false;
BEGIN
    SELECT
        id,
        account_state,
        preferred_locale,
        reminder_hour_local,
        report_notifications_enabled,
        trial_reminder_enabled,
        updated_at
      INTO v_profile
      FROM public.profiles
     WHERE id = p_owner_id
       FOR UPDATE;

    IF NOT FOUND OR v_profile.account_state <> 'active' THEN
        RAISE EXCEPTION 'owner_forbidden' USING ERRCODE = '42501';
    END IF;

    v_until := COALESCE(p_until, v_profile.updated_at);

    SELECT
        product_id,
        state,
        offer_kind,
        valid_until,
        grace_until,
        trial_end_at,
        auto_renew_enabled
      INTO v_entitlement
      FROM public.entitlements
     WHERE owner_id = p_owner_id;

    WITH ordered_entries AS (
        SELECT
            e.entity_type,
            e.id,
            e.updated_at,
            e.deleted_at,
            e.data
        FROM public.owner_sync_entries e
        WHERE e.owner_id = p_owner_id
          AND (p_since IS NULL OR e.updated_at > p_since)
          AND e.updated_at <= v_until
          AND (
              p_cursor_updated_at IS NULL
              OR (e.updated_at, e.entity_type, e.id) > (p_cursor_updated_at, p_cursor_entity_type, p_cursor_id)
          )
        ORDER BY e.updated_at ASC, e.entity_type ASC, e.id ASC
        LIMIT (p_limit + 1)
    ),
    page_rows AS (
        SELECT * FROM ordered_entries LIMIT p_limit
    )
    SELECT
        COALESCE(jsonb_agg(
            jsonb_build_object(
                'entity_type', pr.entity_type,
                'id', pr.id,
                'updated_at', pr.updated_at,
                'deleted_at', pr.deleted_at,
                'data', pr.data
            )
        ), '[]'::jsonb),
        (SELECT count(*) FROM ordered_entries),
        (SELECT updated_at FROM page_rows ORDER BY updated_at DESC, entity_type DESC, id DESC LIMIT 1),
        (SELECT entity_type FROM page_rows ORDER BY updated_at DESC, entity_type DESC, id DESC LIMIT 1),
        (SELECT id FROM page_rows ORDER BY updated_at DESC, entity_type DESC, id DESC LIMIT 1)
    INTO v_rows, v_count, v_last_updated_at, v_last_entity_type, v_last_id
    FROM page_rows pr;

    v_has_more := v_count > p_limit;

    RETURN jsonb_build_object(
        'until', v_until,
        'has_more', v_has_more,
        'last_cursor', CASE WHEN v_has_more THEN jsonb_build_object(
            'since', p_since,
            'until', v_until,
            'updated_at', v_last_updated_at,
            'entity_type', v_last_entity_type,
            'id', v_last_id
        ) ELSE NULL END,
        'next_since', CASE WHEN v_has_more THEN NULL ELSE v_until END,
        'profile', jsonb_build_object(
            'preferred_locale', v_profile.preferred_locale,
            'reminder_hour_local', v_profile.reminder_hour_local,
            'report_notifications_enabled', v_profile.report_notifications_enabled,
            'trial_reminder_enabled', v_profile.trial_reminder_enabled
        ),
        'entitlement', CASE WHEN v_entitlement.product_id IS NULL THEN NULL ELSE jsonb_build_object(
            'product_id', v_entitlement.product_id,
            'state', v_entitlement.state,
            'offer_kind', v_entitlement.offer_kind,
            'valid_until', v_entitlement.valid_until,
            'grace_until', v_entitlement.grace_until,
            'trial_end_at', v_entitlement.trial_end_at,
            'auto_renew_enabled', v_entitlement.auto_renew_enabled
        ) END,
        'changes', v_rows
    );
END;
$$;
