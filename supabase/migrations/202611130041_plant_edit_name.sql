BEGIN;

CREATE FUNCTION public.execute_plant_edit_command(
    p_owner_id UUID, p_operation_id UUID, p_plant_id UUID, p_payload JSONB
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
    v_plant public.plants%ROWTYPE;
    v_receipt public.operation_receipts%ROWTYPE;
    v_hash TEXT;
    v_name TEXT;
    v_watermark TIMESTAMPTZ;
    v_result JSONB;
BEGIN
    PERFORM 1 FROM public.profiles
    WHERE id=p_owner_id AND account_state='active' AND NOT anonymous FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'ACTIVE_PERMANENT_OWNER_REQUIRED' USING ERRCODE = '42501';
    END IF;

    IF p_operation_id IS NULL OR p_plant_id IS NULL
       OR jsonb_typeof(p_payload) IS DISTINCT FROM 'object'
       OR p_payload - 'personal_name' <> '{}'::jsonb
       OR jsonb_typeof(p_payload->'personal_name') IS DISTINCT FROM 'string' THEN
        RAISE EXCEPTION 'INVALID_PLANT_EDIT_INPUT' USING ERRCODE = '22023';
    END IF;
    v_name := regexp_replace(p_payload->>'personal_name', '^[[:space:]]+|[[:space:]]+$', '', 'g');
    IF char_length(v_name) NOT BETWEEN 1 AND 120 THEN
        RAISE EXCEPTION 'INVALID_PLANT_EDIT_INPUT' USING ERRCODE = '22023';
    END IF;

    v_hash := encode(sha256(convert_to(
        jsonb_build_array('plant.edit',p_plant_id,p_payload)::text,'UTF8')),'hex');
    SELECT * INTO v_receipt FROM public.operation_receipts
    WHERE owner_id=p_owner_id AND operation_id=p_operation_id;
    IF FOUND THEN
        IF v_receipt.command_name <> 'plant.edit' OR v_receipt.payload_hash <> v_hash THEN
            RAISE EXCEPTION 'IDEMPOTENCY_CONFLICT' USING ERRCODE = '23505';
        END IF;
        RETURN v_receipt.response_payload;
    END IF;

    SELECT * INTO v_plant FROM public.plants
    WHERE id=p_plant_id AND owner_id=p_owner_id AND deleted_at IS NULL FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PLANT_NOT_FOUND' USING ERRCODE = 'P0002';
    END IF;
    IF v_plant.personal_name IS DISTINCT FROM v_name OR v_plant.display_name IS DISTINCT FROM v_name THEN
        v_watermark := public.advance_owner_watermark(p_owner_id);
        UPDATE public.plants
        SET personal_name=v_name, display_name=v_name, revision=revision+1, updated_at=v_watermark
        WHERE id=p_plant_id AND owner_id=p_owner_id RETURNING * INTO v_plant;
    END IF;
    v_result := jsonb_build_object(
        'plant_id',p_plant_id,'revision',v_plant.revision,'care_revision',v_plant.care_revision,
        'condition_snapshot_id',v_plant.current_condition_snapshot_id,'watermark',v_plant.updated_at);
    INSERT INTO public.operation_receipts(owner_id,operation_id,command_name,payload_hash,response_payload)
    VALUES (p_owner_id,p_operation_id,'plant.edit',v_hash,v_result);
    RETURN v_result;
END;
$$;

REVOKE ALL ON FUNCTION public.execute_plant_edit_command(UUID,UUID,UUID,JSONB) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.execute_plant_edit_command(UUID,UUID,UUID,JSONB) TO service_role;

COMMIT;
