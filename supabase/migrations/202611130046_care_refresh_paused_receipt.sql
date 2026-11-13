BEGIN;

CREATE FUNCTION public.execute_care_recommendation_refresh(
    p_owner_id UUID, p_operation_id UUID, p_plant_id UUID, p_payload JSONB
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
    v_watermark TIMESTAMPTZ;
    v_revision INT;
    v_hash TEXT;
    v_receipt public.operation_receipts%ROWTYPE;
    v_candidate JSONB;
    v_result JSONB;
BEGIN
    SELECT updated_at INTO v_watermark FROM public.profiles
    WHERE id=p_owner_id AND account_state='active' AND NOT anonymous FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'ACTIVE_PERMANENT_OWNER_REQUIRED' USING ERRCODE='42501';
    END IF;
    IF p_operation_id IS NULL OR p_plant_id IS NULL
       OR jsonb_typeof(p_payload) IS DISTINCT FROM 'object'
       OR p_payload-'expected_care_revision' <> '{}'::jsonb
       OR jsonb_typeof(p_payload->'expected_care_revision') IS DISTINCT FROM 'number'
       OR (p_payload->>'expected_care_revision') !~ '^[1-9][0-9]{0,9}$' THEN
        RAISE EXCEPTION 'INVALID_CARE_REFRESH_INPUT' USING ERRCODE='22023';
    END IF;
    IF (p_payload->>'expected_care_revision')::bigint > 2147483647 THEN
        RAISE EXCEPTION 'INVALID_CARE_REFRESH_INPUT' USING ERRCODE='22023';
    END IF;
    v_revision := (p_payload->>'expected_care_revision')::int;
    v_hash := encode(sha256(convert_to(
        jsonb_build_array('care.recommendation.refresh',p_plant_id,v_revision)::text,'UTF8')),'hex');
    SELECT * INTO v_receipt FROM public.operation_receipts
    WHERE owner_id=p_owner_id AND operation_id=p_operation_id;
    IF FOUND THEN
        IF v_receipt.command_name <> 'care.recommendation.refresh' OR v_receipt.payload_hash <> v_hash THEN
            RAISE EXCEPTION 'IDEMPOTENCY_CONFLICT' USING ERRCODE='23505';
        END IF;
        RETURN v_receipt.response_payload;
    END IF;

    v_candidate := public.resolve_basic_care_refresh_candidate(p_owner_id,p_plant_id,v_revision);
    -- Keep the positive path retryable until the schedule writer is installed.
    IF v_candidate->>'state' IS DISTINCT FROM 'paused' THEN
        RAISE EXCEPTION 'CARE_REFRESH_WRITER_UNAVAILABLE' USING ERRCODE='55000';
    END IF;
    v_result := jsonb_build_object('plant_id',p_plant_id,'care_revision',v_revision,
        'state','paused','reason',v_candidate->>'reason','watermark',v_watermark);
    INSERT INTO public.operation_receipts(owner_id,operation_id,command_name,payload_hash,response_payload)
    VALUES (p_owner_id,p_operation_id,'care.recommendation.refresh',v_hash,v_result);
    RETURN v_result;
END;
$$;

REVOKE ALL ON FUNCTION public.execute_care_recommendation_refresh(UUID,UUID,UUID,JSONB)
    FROM PUBLIC,anon,authenticated,service_role;

COMMIT;
