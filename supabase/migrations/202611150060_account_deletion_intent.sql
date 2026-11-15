BEGIN;

-- Internal precursor only: no product route, service_role writer, purge or revocation.
-- Before exposure, review direct authenticated table access, workers and Auth revocation.
-- T082/T083 remain open.
CREATE TABLE public.account_deletion_requests (
    owner_id UUID PRIMARY KEY REFERENCES public.profiles(id),
    operation_id UUID NOT NULL,
    requested_at TIMESTAMPTZ NOT NULL
);
ALTER TABLE public.account_deletion_requests ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.account_deletion_requests
    FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION public.request_account_deletion_internal(
    p_owner_id UUID, p_operation_id UUID
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
    v_profile public.profiles%ROWTYPE;
    v_receipt public.operation_receipts%ROWTYPE;
    v_hash TEXT;
    v_watermark TIMESTAMPTZ;
    v_result JSONB;
BEGIN
    -- Same serialization point as other owner commands, including exact retries.
    SELECT * INTO v_profile FROM public.profiles WHERE id=p_owner_id FOR UPDATE;
    IF NOT FOUND OR v_profile.anonymous OR v_profile.account_state NOT IN ('active','deleting') THEN
        RAISE EXCEPTION 'ACTIVE_PERMANENT_OWNER_REQUIRED' USING ERRCODE='42501';
    END IF;
    IF p_operation_id IS NULL THEN
        RAISE EXCEPTION 'INVALID_ACCOUNT_DELETE_INPUT' USING ERRCODE='22023';
    END IF;

    v_hash := encode(sha256(convert_to(
        jsonb_build_array('account.delete','{}'::jsonb)::text,'UTF8')),'hex');
    SELECT * INTO v_receipt FROM public.operation_receipts
    WHERE owner_id=p_owner_id AND operation_id=p_operation_id;
    IF FOUND THEN
        IF v_receipt.command_name <> 'account.delete' OR v_receipt.payload_hash <> v_hash THEN
            RAISE EXCEPTION 'IDEMPOTENCY_CONFLICT' USING ERRCODE='23505';
        END IF;
        RETURN v_receipt.response_payload;
    END IF;
    IF v_profile.account_state <> 'active' THEN
        RAISE EXCEPTION 'ACTIVE_PERMANENT_OWNER_REQUIRED' USING ERRCODE='42501';
    END IF;

    -- Advance while active; retiring the owner must not call the active-only helper again.
    v_watermark := public.advance_owner_watermark(p_owner_id);
    INSERT INTO public.account_deletion_requests(owner_id,operation_id,requested_at)
    VALUES(p_owner_id,p_operation_id,v_watermark);
    UPDATE public.profiles SET account_state='deleting' WHERE id=p_owner_id;
    v_result := jsonb_build_object('owner_id',p_owner_id,'operation_id',p_operation_id,
        'state','deleting','watermark',v_watermark);
    INSERT INTO public.operation_receipts(
        owner_id,operation_id,command_name,payload_hash,response_payload,committed_at)
    VALUES(p_owner_id,p_operation_id,'account.delete',v_hash,v_result,v_watermark);
    RETURN v_result;
END;
$$;
REVOKE ALL ON FUNCTION public.request_account_deletion_internal(UUID,UUID)
    FROM PUBLIC, anon, authenticated, service_role;

COMMIT;
