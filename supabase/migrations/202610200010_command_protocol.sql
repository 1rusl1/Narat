-- ============================================================================
-- Migration: 202610200010_command_protocol.sql
-- Tasks: T017
-- Coverage: FR-010, FR-024–FR-030, SC-005 (idempotent operation_receipts & delta GET /sync)
-- ============================================================================

-- 1. Lookup or verify existing operation_receipt before side effects
CREATE OR REPLACE FUNCTION public.lookup_operation_receipt(
    p_owner_id UUID,
    p_operation_id UUID,
    p_command_name TEXT,
    p_payload_hash TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_existing RECORD;
BEGIN
    SELECT command_name, payload_hash, response_payload
      INTO v_existing
      FROM public.operation_receipts
     WHERE owner_id = p_owner_id
       AND operation_id = p_operation_id;

    IF NOT FOUND THEN
        RETURN NULL;
    END IF;

    IF v_existing.command_name <> p_command_name OR v_existing.payload_hash <> p_payload_hash THEN
        RAISE EXCEPTION 'operation_payload_mismatch' USING ERRCODE = '23505';
    END IF;

    RETURN v_existing.response_payload;
END;
$$;

-- 2. Save operation_receipt inside the same transaction as the state mutation
CREATE OR REPLACE FUNCTION public.save_operation_receipt(
    p_owner_id UUID,
    p_operation_id UUID,
    p_command_name TEXT,
    p_payload_hash TEXT,
    p_response_payload JSONB,
    p_committed_at TIMESTAMPTZ DEFAULT clock_timestamp()
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    INSERT INTO public.operation_receipts (
        owner_id,
        operation_id,
        command_name,
        payload_hash,
        response_payload,
        committed_at
    )
    VALUES (
        p_owner_id,
        p_operation_id,
        p_command_name,
        p_payload_hash,
        p_response_payload,
        p_committed_at
    );

    RETURN p_response_payload;
END;
$$;

-- 3. Unified Delta Stream View across all 15 synchronizable owner projections
CREATE OR REPLACE VIEW public.owner_sync_entries AS
    -- 1. rooms
    SELECT
        r.owner_id,
        'rooms'::text AS entity_type,
        r.id,
        r.updated_at,
        r.deleted_at,
        CASE WHEN r.deleted_at IS NOT NULL THEN NULL ELSE jsonb_build_object(
            'id', r.id,
            'name', r.name,
            'revision', r.revision
        ) END AS data
    FROM public.rooms r
    UNION ALL
    -- 2. plants
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
            'room_id', p.room_id,
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
            'enabled', bcm.enabled,
            'free_slot', bcm.free_slot
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

-- 4. Delta Query Function: locks owner profile to capture authoritative `until` watermark and paginates by (updated_at, entity_type, id)
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
        free_selection_revision,
        free_selection_explicit,
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
            'free_selection_revision', v_profile.free_selection_revision,
            'free_selection_explicit', v_profile.free_selection_explicit,
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
