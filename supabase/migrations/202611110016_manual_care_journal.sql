BEGIN;

CREATE FUNCTION public.execute_manual_care_command(
    p_owner_id UUID, p_operation_id UUID, p_plant_id UUID,
    p_command_name TEXT, p_payload JSONB
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
    v_owner public.profiles%ROWTYPE;
    v_receipt public.operation_receipts%ROWTYPE;
    v_hash TEXT;
    v_occurred_at TIMESTAMPTZ;
    v_timezone TEXT;
    v_ts TIMESTAMPTZ;
    v_entry_id UUID;
    v_reversal_id UUID;
    v_entry_state TEXT;
    v_result JSONB;
BEGIN
    IF p_operation_id IS NULL OR p_plant_id IS NULL OR p_command_name IS NULL
       OR p_command_name NOT IN ('care.record', 'care.undo')
       OR jsonb_typeof(p_payload) IS DISTINCT FROM 'object' THEN
        RAISE EXCEPTION 'INVALID_CARE_INPUT' USING ERRCODE = '22023';
    END IF;

    SELECT * INTO v_owner FROM public.profiles WHERE id = p_owner_id FOR UPDATE;
    IF NOT FOUND OR v_owner.account_state <> 'active' OR v_owner.anonymous THEN
        RAISE EXCEPTION 'ACTIVE_PERMANENT_OWNER_REQUIRED' USING ERRCODE = '42501';
    END IF;

    v_hash := encode(sha256(convert_to(
        jsonb_build_array(p_command_name, p_plant_id, p_payload)::text, 'UTF8')), 'hex');
    SELECT * INTO v_receipt FROM public.operation_receipts
    WHERE owner_id = p_owner_id AND operation_id = p_operation_id;
    IF FOUND THEN
        IF v_receipt.command_name <> p_command_name OR v_receipt.payload_hash <> v_hash THEN
            RAISE EXCEPTION 'IDEMPOTENCY_CONFLICT' USING ERRCODE = '23505';
        END IF;
        RETURN v_receipt.response_payload;
    END IF;

    PERFORM 1 FROM public.plants
    WHERE id = p_plant_id AND owner_id = p_owner_id AND deleted_at IS NULL
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PLANT_NOT_FOUND' USING ERRCODE = 'P0002';
    END IF;

    IF p_command_name = 'care.record' THEN
        v_timezone := p_payload->>'timezone';
        IF p_payload - ARRAY['action_code', 'occurred_at', 'timezone'] <> '{}'::jsonb
           OR p_payload->>'action_code' IS DISTINCT FROM 'water'
           OR coalesce(p_payload->>'occurred_at', '') !~
               '^[0-9]{4}-[0-9]{2}-[0-9]{2}T([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9]([.][0-9]{1,6})?(Z|[+-](0[0-9]|1[0-5]):[0-5][0-9])$'
           OR v_timezone IS NULL OR length(v_timezone) > 128
           OR NOT EXISTS (SELECT 1 FROM pg_catalog.pg_timezone_names WHERE name = v_timezone) THEN
            RAISE EXCEPTION 'INVALID_CARE_INPUT' USING ERRCODE = '22023';
        END IF;
        v_occurred_at := (p_payload->>'occurred_at')::timestamptz;
        IF v_occurred_at > clock_timestamp() THEN
            RAISE EXCEPTION 'FUTURE_CARE_ENTRY' USING ERRCODE = '22023';
        END IF;
        v_ts := public.advance_owner_watermark(p_owner_id);
        INSERT INTO public.care_entries (
            owner_id, plant_id, action_code, occurred_at, occurred_local_date,
            timezone, operation_id, recorded_at, updated_at
        ) VALUES (
            p_owner_id, p_plant_id, 'water', v_occurred_at, timezone(v_timezone, v_occurred_at)::date,
            v_timezone, p_operation_id, v_ts, v_ts
        ) RETURNING id INTO v_entry_id;
        v_entry_state := 'active';
    ELSE
        IF p_payload - 'entry_id' <> '{}'::jsonb OR p_payload->>'entry_id' IS NULL THEN
            RAISE EXCEPTION 'INVALID_CARE_INPUT' USING ERRCODE = '22023';
        END IF;
        v_entry_id := (p_payload->>'entry_id')::uuid;
        SELECT state INTO v_entry_state FROM public.care_entries
        WHERE id = v_entry_id AND owner_id = p_owner_id AND plant_id = p_plant_id
            AND task_id IS NULL AND action_code = 'water' AND deleted_at IS NULL
        FOR UPDATE;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'CARE_ENTRY_NOT_FOUND' USING ERRCODE = 'P0002';
        END IF;
        IF v_entry_state <> 'active' THEN
            RAISE EXCEPTION 'CARE_ENTRY_ALREADY_VOIDED' USING ERRCODE = '23505';
        END IF;
        v_ts := public.advance_owner_watermark(p_owner_id);
        UPDATE public.care_entries SET state = 'voided', updated_at = v_ts WHERE id = v_entry_id;
        INSERT INTO public.care_reversals (owner_id, entry_id, operation_id, recorded_at, updated_at)
        VALUES (p_owner_id, v_entry_id, p_operation_id, v_ts, v_ts)
        RETURNING id INTO v_reversal_id;
        v_entry_state := 'voided';
    END IF;

    v_result := jsonb_build_object(
        'plant_id', p_plant_id, 'entry_id', v_entry_id, 'reversal_id', v_reversal_id,
        'state', v_entry_state, 'watermark', v_ts);
    INSERT INTO public.operation_receipts (owner_id, operation_id, command_name, payload_hash, response_payload)
    VALUES (p_owner_id, p_operation_id, p_command_name, v_hash, v_result);
    RETURN v_result;
END;
$$;

REVOKE ALL ON FUNCTION public.execute_manual_care_command(UUID, UUID, UUID, TEXT, JSONB)
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.execute_manual_care_command(UUID, UUID, UUID, TEXT, JSONB)
TO service_role;

COMMIT;
