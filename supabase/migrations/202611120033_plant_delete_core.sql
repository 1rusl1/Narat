BEGIN;

-- Preserve direct soft-delete reconciliation when live basic care still exists.
-- The command below tombstones the affected rows before updating the plant.
CREATE OR REPLACE FUNCTION public.trg_plants_soft_delete_basic_care()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
    IF NEW.deleted_at IS NOT NULL AND OLD.deleted_at IS NULL THEN
        UPDATE public.basic_care_memberships
        SET enabled = false, free_slot = NULL, deleted_at = NEW.deleted_at, updated_at = clock_timestamp()
        WHERE owner_id = NEW.owner_id AND plant_id = NEW.id AND deleted_at IS NULL;
        IF FOUND OR EXISTS (
            SELECT 1 FROM public.task_rules
            WHERE owner_id = NEW.owner_id AND plant_id = NEW.id
              AND access_class = 'basic_care' AND deleted_at IS NULL
        ) THEN
            PERFORM public.reconcile_owner_basic_care(NEW.owner_id);
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

CREATE FUNCTION public.execute_plant_delete_command(
    p_owner_id UUID, p_operation_id UUID, p_plant_id UUID, p_payload JSONB
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
    v_receipt public.operation_receipts%ROWTYPE;
    v_deleted_at TIMESTAMPTZ;
    v_watermark TIMESTAMPTZ;
    v_job_id UUID;
    v_hash TEXT;
    v_result JSONB;
BEGIN
    PERFORM 1 FROM public.profiles
    WHERE id = p_owner_id AND account_state = 'active' AND NOT anonymous
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'ACTIVE_PERMANENT_OWNER_REQUIRED' USING ERRCODE = '42501';
    END IF;
    IF p_operation_id IS NULL OR p_plant_id IS NULL OR p_payload IS DISTINCT FROM '{}'::jsonb THEN
        RAISE EXCEPTION 'INVALID_PLANT_DELETE_INPUT' USING ERRCODE = '22023';
    END IF;

    v_hash := encode(sha256(convert_to(
        jsonb_build_array('plant.delete', p_plant_id, p_payload)::text, 'UTF8')), 'hex');
    SELECT * INTO v_receipt FROM public.operation_receipts
    WHERE owner_id = p_owner_id AND operation_id = p_operation_id;
    IF FOUND THEN
        IF v_receipt.command_name <> 'plant.delete' OR v_receipt.payload_hash <> v_hash THEN
            RAISE EXCEPTION 'IDEMPOTENCY_CONFLICT' USING ERRCODE = '23505';
        END IF;
        RETURN v_receipt.response_payload;
    END IF;

    SELECT deleted_at INTO v_deleted_at FROM public.plants
    WHERE id = p_plant_id AND owner_id = p_owner_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'PLANT_NOT_FOUND' USING ERRCODE = 'P0002'; END IF;
    IF v_deleted_at IS NOT NULL THEN
        RAISE EXCEPTION 'PLANT_ALREADY_DELETED' USING ERRCODE = '23505';
    END IF;

    v_watermark := public.advance_owner_watermark(p_owner_id);
    UPDATE public.condition_snapshots SET deleted_at = v_watermark, updated_at = v_watermark
    WHERE owner_id = p_owner_id AND plant_id = p_plant_id AND deleted_at IS NULL;
    UPDATE public.photo_assets SET state = 'deleting', deleted_at = v_watermark, updated_at = v_watermark
    WHERE owner_id = p_owner_id AND plant_id = p_plant_id AND deleted_at IS NULL;
    UPDATE public.analysis_results SET deleted_at = v_watermark, updated_at = v_watermark
    WHERE owner_id = p_owner_id AND plant_id = p_plant_id AND deleted_at IS NULL;
    UPDATE public.care_plans SET deleted_at = v_watermark, updated_at = v_watermark
    WHERE owner_id = p_owner_id AND plant_id = p_plant_id AND deleted_at IS NULL;
    UPDATE public.task_rules SET deleted_at = v_watermark, updated_at = v_watermark
    WHERE owner_id = p_owner_id AND plant_id = p_plant_id AND deleted_at IS NULL;
    UPDATE public.care_tasks SET reminder_eligible = false, deleted_at = v_watermark, updated_at = v_watermark
    WHERE owner_id = p_owner_id AND plant_id = p_plant_id AND deleted_at IS NULL;
    UPDATE public.care_reversals r SET deleted_at = v_watermark, updated_at = v_watermark
    FROM public.care_entries e
    WHERE r.owner_id = p_owner_id AND e.owner_id = p_owner_id AND e.plant_id = p_plant_id
      AND r.entry_id = e.id AND r.deleted_at IS NULL;
    UPDATE public.care_entries SET deleted_at = v_watermark, updated_at = v_watermark
    WHERE owner_id = p_owner_id AND plant_id = p_plant_id AND deleted_at IS NULL;
    UPDATE public.schedule_changes SET deleted_at = v_watermark, updated_at = v_watermark
    WHERE owner_id = p_owner_id AND plant_id = p_plant_id AND deleted_at IS NULL;
    UPDATE public.basic_care_memberships
    SET enabled = false, free_slot = NULL, deleted_at = v_watermark, updated_at = v_watermark
    WHERE owner_id = p_owner_id AND plant_id = p_plant_id AND deleted_at IS NULL;
    UPDATE public.first_aid_followups SET deleted_at = v_watermark, updated_at = v_watermark
    WHERE owner_id = p_owner_id AND plant_id = p_plant_id AND deleted_at IS NULL;
    UPDATE public.care_observations SET deleted_at = v_watermark, updated_at = v_watermark
    WHERE owner_id = p_owner_id AND plant_id = p_plant_id AND deleted_at IS NULL;
    UPDATE public.recovery_transitions SET deleted_at = v_watermark, updated_at = v_watermark
    WHERE owner_id = p_owner_id AND plant_id = p_plant_id AND deleted_at IS NULL;
    UPDATE public.plants SET deleted_at = v_watermark, updated_at = v_watermark
    WHERE id = p_plant_id AND owner_id = p_owner_id;

    INSERT INTO public.deletion_jobs(owner_id, scope, target_id, state, operation_id)
    VALUES (p_owner_id, 'plant', p_plant_id, 'purge_storage', p_operation_id)
    RETURNING id INTO v_job_id;
    v_result := jsonb_build_object('plant_id', p_plant_id, 'deletion_job_id', v_job_id,
        'state', 'deleting', 'watermark', v_watermark);
    INSERT INTO public.operation_receipts(owner_id, operation_id, command_name, payload_hash, response_payload)
    VALUES (p_owner_id, p_operation_id, 'plant.delete', v_hash, v_result);
    RETURN v_result;
END;
$$;

REVOKE ALL ON FUNCTION public.execute_plant_delete_command(UUID, UUID, UUID, JSONB)
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.execute_plant_delete_command(UUID, UUID, UUID, JSONB) TO service_role;

COMMIT;
