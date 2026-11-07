-- ============================================================================
-- Migration: 202611010002_basic_care.sql
-- Task: T129 (Basic Care enable/disable/free_care.select, atomic slot assignment,
--             paid unlimited / expiry fallback, pause reminders without deleting history)
-- Coverage: FR-023, FR-028, FR-048, FR-050, SC-014, SC-021, V46, V50
-- ============================================================================

-- Ensure at most one active/paused basic_care rule per plant + action_code
CREATE UNIQUE INDEX IF NOT EXISTS idx_task_rules_one_basic_family
    ON public.task_rules (plant_id, action_code)
    WHERE access_class = 'basic_care' AND rule_state <> 'superseded' AND deleted_at IS NULL;

-- 1. Reconcile basic_care_memberships and open basic_care tasks for an owner
--    Called after enable/disable/free_care.select, plant delete, or subscription expiry.
CREATE OR REPLACE FUNCTION public.reconcile_owner_basic_care(
    p_owner_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_has_paid BOOLEAN;
    v_explicit BOOLEAN;
    v_slot INT := 1;
    v_row RECORD;
BEGIN
    PERFORM 1 FROM public.profiles WHERE id = p_owner_id FOR UPDATE;
    SELECT free_selection_explicit INTO v_explicit
    FROM public.profiles
    WHERE id = p_owner_id;

    v_has_paid := public.has_verified_paid_access(p_owner_id);

    -- Remove free_slot from disabled or deleted plants
    UPDATE public.basic_care_memberships m
    SET free_slot = NULL,
        updated_at = clock_timestamp()
    FROM public.plants p
    WHERE m.owner_id = p_owner_id
      AND m.plant_id = p.id
      AND m.free_slot IS NOT NULL
      AND (m.enabled = false OR m.deleted_at IS NOT NULL OR p.deleted_at IS NOT NULL);

    -- When free_selection_explicit is false, automatically assign slots 1..3 by (enabled_at ASC, plant_id ASC)
    IF NOT coalesce(v_explicit, false) THEN
        UPDATE public.basic_care_memberships
        SET free_slot = NULL,
            updated_at = clock_timestamp()
        WHERE owner_id = p_owner_id
          AND free_slot IS NOT NULL;

        FOR v_row IN
            SELECT m.id
            FROM public.basic_care_memberships m
            JOIN public.plants p ON p.id = m.plant_id
            WHERE m.owner_id = p_owner_id
              AND m.enabled = true
              AND m.deleted_at IS NULL
              AND p.deleted_at IS NULL
            ORDER BY m.enabled_at ASC, m.plant_id ASC
            LIMIT 3
        LOOP
            UPDATE public.basic_care_memberships
            SET free_slot = v_slot,
                updated_at = clock_timestamp()
            WHERE id = v_row.id;
            v_slot := v_slot + 1;
        END LOOP;
    END IF;

    -- Sync rule_state and care_tasks.reminder_eligible / inactive_reason for basic_care rules
    IF v_has_paid THEN
        -- Paid user: all enabled basic_care plants are active and reminder-eligible
        UPDATE public.task_rules r
        SET rule_state = CASE WHEN m.enabled THEN 'active' ELSE 'paused' END,
            updated_at = clock_timestamp()
        FROM public.basic_care_memberships m
        WHERE r.owner_id = p_owner_id
          AND r.plant_id = m.plant_id
          AND r.access_class = 'basic_care'
          AND r.rule_state <> 'superseded'
          AND r.deleted_at IS NULL;

        UPDATE public.care_tasks t
        SET reminder_eligible = m.enabled,
            inactive_reason = CASE WHEN m.enabled THEN NULL ELSE 'free_slot_removed' END,
            updated_at = clock_timestamp()
        FROM public.task_rules r
        JOIN public.basic_care_memberships m ON m.plant_id = r.plant_id AND m.owner_id = r.owner_id
        WHERE t.owner_id = p_owner_id
          AND t.rule_id = r.id
          AND r.access_class = 'basic_care'
          AND t.state IN ('open', 'needs_review')
          AND t.deleted_at IS NULL;
    ELSE
        -- Free user: only enabled plants with free_slot 1..3 are active and reminder-eligible
        UPDATE public.task_rules r
        SET rule_state = CASE
                WHEN m.enabled AND m.free_slot BETWEEN 1 AND 3 THEN 'active'
                ELSE 'paused'
            END,
            updated_at = clock_timestamp()
        FROM public.basic_care_memberships m
        WHERE r.owner_id = p_owner_id
          AND r.plant_id = m.plant_id
          AND r.access_class = 'basic_care'
          AND r.rule_state <> 'superseded'
          AND r.deleted_at IS NULL;

        UPDATE public.care_tasks t
        SET reminder_eligible = (m.enabled AND m.free_slot BETWEEN 1 AND 3),
            inactive_reason = CASE
                WHEN m.enabled AND m.free_slot BETWEEN 1 AND 3 THEN NULL
                ELSE 'free_slot_removed'
            END,
            updated_at = clock_timestamp()
        FROM public.task_rules r
        JOIN public.basic_care_memberships m ON m.plant_id = r.plant_id AND m.owner_id = r.owner_id
        WHERE t.owner_id = p_owner_id
          AND t.rule_id = r.id
          AND r.access_class = 'basic_care'
          AND t.state IN ('open', 'needs_review')
          AND t.deleted_at IS NULL;
    END IF;

    RETURN (
        SELECT jsonb_build_object(
            'has_paid_access', v_has_paid,
            'free_selection_explicit', coalesce(v_explicit, false),
            'memberships', coalesce(jsonb_agg(
                jsonb_build_object(
                    'plant_id', m.plant_id,
                    'enabled', m.enabled,
                    'enabled_at', m.enabled_at,
                    'free_slot', m.free_slot
                ) ORDER BY m.enabled_at ASC, m.plant_id ASC
            ), '[]'::jsonb)
        )
        FROM public.basic_care_memberships m
        JOIN public.plants p ON p.id = m.plant_id
        WHERE m.owner_id = p_owner_id
          AND m.deleted_at IS NULL
          AND p.deleted_at IS NULL
    );
END;
$$;

-- 2. Execute basic care command: basic_care.enable | basic_care.disable | free_care.select
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
    v_payload_hash TEXT := encode(digest(coalesce(p_payload::text, '{}'), 'sha256'), 'hex');
    v_existing RECORD;
    v_has_paid BOOLEAN;
    v_plant_id UUID;
    v_selected_ids UUID[];
    v_idx INT;
    v_enabled_count INT;
    v_reconciled JSONB;
    v_response JSONB;
BEGIN
    SELECT status_code, response_body, payload_hash
    INTO v_existing
    FROM public.operation_receipts
    WHERE owner_id = p_owner_id
      AND operation_id = p_operation_id;

    IF FOUND THEN
        IF v_existing.payload_hash <> v_payload_hash THEN
            RAISE EXCEPTION 'idempotency_payload_mismatch' USING ERRCODE = '22023';
        END IF;
        RETURN v_existing.response_body;
    END IF;

    PERFORM 1 FROM public.profiles WHERE id = p_owner_id FOR UPDATE;
    v_has_paid := public.has_verified_paid_access(p_owner_id);

    IF p_command_type = 'basic_care.enable' THEN
        v_plant_id := (p_payload->>'plant_id')::uuid;
        IF NOT EXISTS (
            SELECT 1 FROM public.plants
            WHERE id = v_plant_id AND owner_id = p_owner_id AND deleted_at IS NULL
        ) THEN
            RAISE EXCEPTION 'plant_not_found' USING ERRCODE = 'P0002';
        END IF;

        IF NOT v_has_paid THEN
            SELECT count(*) INTO v_enabled_count
            FROM public.basic_care_memberships m
            JOIN public.plants p ON p.id = m.plant_id
            WHERE m.owner_id = p_owner_id
              AND m.enabled = true
              AND m.free_slot BETWEEN 1 AND 3
              AND m.plant_id <> v_plant_id
              AND m.deleted_at IS NULL
              AND p.deleted_at IS NULL;

            IF v_enabled_count >= 3 THEN
                RAISE EXCEPTION 'free_limit_reached_select_required' USING ERRCODE = '22023';
            END IF;
        END IF;

        -- Preserve original enabled_at if membership row already existed
        INSERT INTO public.basic_care_memberships (
            owner_id, plant_id, enabled_at, enabled, free_slot
        ) VALUES (
            p_owner_id, v_plant_id, clock_timestamp(), true, NULL
        )
        ON CONFLICT (owner_id, plant_id) DO UPDATE
        SET enabled = true,
            deleted_at = NULL,
            updated_at = clock_timestamp();

    ELSIF p_command_type = 'basic_care.disable' THEN
        v_plant_id := (p_payload->>'plant_id')::uuid;
        UPDATE public.basic_care_memberships
        SET enabled = false,
            free_slot = NULL,
            updated_at = clock_timestamp()
        WHERE owner_id = p_owner_id
          AND plant_id = v_plant_id;

    ELSIF p_command_type = 'free_care.select' THEN
        SELECT coalesce(array_agg((elem)::uuid), '{}'::uuid[])
        INTO v_selected_ids
        FROM jsonb_array_elements_text(coalesce(p_payload->'selected_plant_ids', '[]'::jsonb)) AS elem;

        IF coalesce(array_length(v_selected_ids, 1), 0) > 3 THEN
            RAISE EXCEPTION 'free_care_max_three_plants' USING ERRCODE = '22023';
        END IF;

        -- Validate all selected plants belong to owner and are not deleted
        IF EXISTS (
            SELECT 1
            FROM unnest(v_selected_ids) AS sel_id
            LEFT JOIN public.plants p
                ON p.id = sel_id AND p.owner_id = p_owner_id AND p.deleted_at IS NULL
            WHERE p.id IS NULL
        ) THEN
            RAISE EXCEPTION 'selected_plant_not_found' USING ERRCODE = 'P0002';
        END IF;

        UPDATE public.profiles
        SET free_selection_explicit = true,
            free_selection_revision = free_selection_revision + 1,
            updated_at = clock_timestamp()
        WHERE id = p_owner_id;

        -- Clear previous free_slots first
        UPDATE public.basic_care_memberships
        SET free_slot = NULL,
            updated_at = clock_timestamp()
        WHERE owner_id = p_owner_id;

        -- Atomically enable and assign slots 1..N in order
        IF coalesce(array_length(v_selected_ids, 1), 0) > 0 THEN
            FOR v_idx IN 1..array_length(v_selected_ids, 1) LOOP
                v_plant_id := v_selected_ids[v_idx];
                INSERT INTO public.basic_care_memberships (
                    owner_id, plant_id, enabled_at, enabled, free_slot
                ) VALUES (
                    p_owner_id, v_plant_id, clock_timestamp(), true, v_idx
                )
                ON CONFLICT (owner_id, plant_id) DO UPDATE
                SET enabled = true,
                    free_slot = v_idx,
                    deleted_at = NULL,
                    updated_at = clock_timestamp();
            END LOOP;
        END IF;
    ELSE
        RAISE EXCEPTION 'unsupported_basic_care_command' USING ERRCODE = '22023';
    END IF;

    v_reconciled := public.reconcile_owner_basic_care(p_owner_id);
    PERFORM public.advance_owner_watermark(p_owner_id);

    v_response := jsonb_build_object(
        'status', 'committed',
        'command_type', p_command_type,
        'state', v_reconciled
    );

    INSERT INTO public.operation_receipts (
        owner_id, operation_id, command_type, payload_hash, status_code, response_body
    ) VALUES (
        p_owner_id, p_operation_id, p_command_type, v_payload_hash, 200, v_response
    );

    RETURN v_response;
END;
$$;

-- Trigger on plant soft-delete to free slot and reconcile basic care memberships
CREATE OR REPLACE FUNCTION public.trg_plants_soft_delete_basic_care()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF NEW.deleted_at IS NOT NULL AND OLD.deleted_at IS NULL THEN
        UPDATE public.basic_care_memberships
        SET enabled = false,
            free_slot = NULL,
            deleted_at = NEW.deleted_at,
            updated_at = clock_timestamp()
        WHERE owner_id = NEW.owner_id
          AND plant_id = NEW.id;

        PERFORM public.reconcile_owner_basic_care(NEW.owner_id);
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_plants_soft_delete_basic_care ON public.plants;
CREATE TRIGGER trg_plants_soft_delete_basic_care
    AFTER UPDATE OF deleted_at ON public.plants
    FOR EACH ROW
    EXECUTE FUNCTION public.trg_plants_soft_delete_basic_care();
