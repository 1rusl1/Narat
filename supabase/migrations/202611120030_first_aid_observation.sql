BEGIN;

ALTER TABLE public.care_observations
    ADD COLUMN first_aid_control_id UUID REFERENCES public.first_aid_followups(id) ON DELETE SET NULL;
CREATE UNIQUE INDEX care_observations_one_per_first_aid_control
    ON public.care_observations(first_aid_control_id) WHERE first_aid_control_id IS NOT NULL;

CREATE FUNCTION public.complete_first_aid_control(
    p_owner_id UUID, p_operation_id UUID, p_plant_id UUID, p_payload JSONB
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
    v_owner public.profiles%ROWTYPE;
    v_receipt public.operation_receipts%ROWTYPE;
    v_plant public.plants%ROWTYPE;
    v_control public.first_aid_followups%ROWTYPE;
    v_hash TEXT;
    v_has_entitlement BOOLEAN;
    v_observed_at TIMESTAMPTZ;
    v_watermark TIMESTAMPTZ;
    v_observation_id UUID;
    v_result JSONB;
BEGIN
    IF p_operation_id IS NULL OR p_plant_id IS NULL
        OR jsonb_typeof(p_payload) IS DISTINCT FROM 'object' THEN
        RAISE EXCEPTION 'INVALID_OBSERVATION_INPUT' USING ERRCODE = '22023';
    END IF;

    IF p_payload - ARRAY['control_id', 'status_code'] <> '{}'::jsonb
        OR jsonb_typeof(p_payload->'control_id') IS DISTINCT FROM 'string'
        OR coalesce(p_payload->>'status_code', '') NOT IN ('improved', 'unchanged', 'worse', 'unknown') THEN
        RAISE EXCEPTION 'INVALID_OBSERVATION_INPUT' USING ERRCODE = '22023';
    END IF;

    -- Share the owner-first lock order and receipt namespace with care.undo.
    SELECT * INTO v_owner FROM public.profiles WHERE id = p_owner_id FOR UPDATE;
    IF NOT FOUND OR v_owner.account_state <> 'active' OR v_owner.anonymous THEN
        RAISE EXCEPTION 'ACTIVE_PERMANENT_OWNER_REQUIRED' USING ERRCODE = '42501';
    END IF;

    v_hash := encode(sha256(convert_to(
        jsonb_build_array('care.first_aid.observe', p_plant_id, p_payload)::text, 'UTF8')), 'hex');
    SELECT * INTO v_receipt FROM public.operation_receipts
    WHERE owner_id = p_owner_id AND operation_id = p_operation_id;
    IF FOUND THEN
        IF v_receipt.command_name <> 'care.first_aid.observe' OR v_receipt.payload_hash <> v_hash THEN
            RAISE EXCEPTION 'IDEMPOTENCY_CONFLICT' USING ERRCODE = '23505';
        END IF;
        RETURN v_receipt.response_payload;
    END IF;

    SELECT * INTO v_plant FROM public.plants
    WHERE id = p_plant_id AND owner_id = p_owner_id AND deleted_at IS NULL
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PLANT_NOT_FOUND' USING ERRCODE = 'P0002';
    END IF;

    SELECT * INTO v_control FROM public.first_aid_followups
    WHERE id = (p_payload->>'control_id')::uuid
        AND owner_id = p_owner_id AND plant_id = p_plant_id AND deleted_at IS NULL
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'FIRST_AID_CONTROL_NOT_FOUND' USING ERRCODE = 'P0002';
    END IF;

    IF v_control.state <> 'active' OR v_control.control_task_id IS NOT NULL
        OR v_control.context_revision <> v_plant.care_revision
        OR NOT EXISTS (
            SELECT 1
            FROM public.care_entries e
            JOIN public.analysis_jobs j ON j.id = e.first_aid_job_id
                AND j.owner_id = e.owner_id AND j.plant_id = e.plant_id
            JOIN public.kb_releases k ON k.id = j.kb_release_id AND k.state = 'published'
            WHERE e.id = v_control.action_entry_id AND e.owner_id = p_owner_id
                AND e.plant_id = p_plant_id AND e.state = 'active' AND e.deleted_at IS NULL
                AND e.action_code = 'check_soil' AND e.task_id IS NULL
                AND j.mode = 'diagnosis' AND j.state = 'succeeded'
                AND j.kb_release_id = v_control.kb_release_id
                AND j.snapshot_id IS NOT DISTINCT FROM v_plant.current_condition_snapshot_id
        ) THEN
        RAISE EXCEPTION 'FIRST_AID_CONTROL_INACTIVE' USING ERRCODE = '23505';
    END IF;

    -- Evaluate expiry after waiting for the owner, control and any entitlement update.
    PERFORM 1 FROM public.entitlements WHERE owner_id = p_owner_id FOR SHARE;
    v_has_entitlement := FOUND;
    v_observed_at := clock_timestamp();
    IF v_has_entitlement AND NOT public.has_verified_paid_access(p_owner_id, v_observed_at) THEN
        RAISE EXCEPTION 'FIRST_AID_CONTROL_EXPIRED' USING ERRCODE = '23505';
    END IF;

    v_watermark := public.advance_owner_watermark(p_owner_id);
    INSERT INTO public.care_observations(
        owner_id, plant_id, first_aid_control_id, status_code, observed_at, operation_id, updated_at
    ) VALUES (
        p_owner_id, p_plant_id, v_control.id, p_payload->>'status_code', v_observed_at, p_operation_id, v_watermark
    ) RETURNING id INTO v_observation_id;
    UPDATE public.first_aid_followups
    SET state = 'completed', updated_at = v_watermark WHERE id = v_control.id;

    v_result := jsonb_build_object('plant_id', p_plant_id, 'control_id', v_control.id,
        'observation_id', v_observation_id, 'state', 'completed', 'watermark', v_watermark);
    INSERT INTO public.operation_receipts(owner_id, operation_id, command_name, payload_hash, response_payload)
    VALUES (p_owner_id, p_operation_id, 'care.first_aid.observe', v_hash, v_result);
    RETURN v_result;
END;
$$;

REVOKE ALL ON FUNCTION public.complete_first_aid_control(UUID, UUID, UUID, JSONB)
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.complete_first_aid_control(UUID, UUID, UUID, JSONB) TO service_role;

-- Preserve the existing sync projection for historical observations and unrelated entities.
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
        ) || CASE WHEN co.first_aid_control_id IS NULL THEN '{}'::jsonb
            ELSE jsonb_build_object('first_aid_control_id', co.first_aid_control_id)
        END END AS data
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

COMMIT;
