BEGIN;

-- Persist evidence only. T082/T083 data and Auth finalization remain open.
ALTER TABLE public.account_deletion_requests
    ADD COLUMN storage_verified_at TIMESTAMPTZ;

CREATE FUNCTION public.verify_account_deletion_storage_internal(
    p_owner_id UUID, p_operation_id UUID
) RETURNS TIMESTAMPTZ
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
    v_profile public.profiles%ROWTYPE;
    v_request public.account_deletion_requests%ROWTYPE;
    v_receipt public.operation_receipts%ROWTYPE;
    v_plan JSONB;
    v_verified_at TIMESTAMPTZ;
BEGIN
    -- All future finalizers must repeat this fresh check under this owner lock
    -- in the same transaction before destructive work. A saved timestamp alone
    -- is never authorization to finalize.
    SELECT * INTO v_profile FROM public.profiles WHERE id=p_owner_id FOR UPDATE;
    IF NOT FOUND OR v_profile.anonymous OR v_profile.account_state<>'deleting' THEN
        RETURN NULL;
    END IF;
    SELECT * INTO v_request FROM public.account_deletion_requests
    WHERE owner_id=p_owner_id FOR UPDATE;
    IF NOT FOUND OR v_request.operation_id IS DISTINCT FROM p_operation_id THEN
        RETURN NULL;
    END IF;
    SELECT * INTO v_receipt FROM public.operation_receipts
    WHERE owner_id=p_owner_id AND operation_id=p_operation_id FOR SHARE;
    IF NOT FOUND THEN
        RETURN NULL;
    END IF;
    IF v_receipt.command_name IS DISTINCT FROM 'account.delete'
        OR v_receipt.payload_hash IS DISTINCT FROM encode(sha256(convert_to(
            jsonb_build_array('account.delete','{}'::jsonb)::text,'UTF8')),'hex')
        OR v_receipt.committed_at IS DISTINCT FROM v_request.requested_at
        OR v_receipt.response_payload IS DISTINCT FROM jsonb_build_object(
            'owner_id',p_owner_id,'operation_id',p_operation_id,
            'state','deleting','watermark',v_request.requested_at) THEN
        RETURN NULL;
    END IF;

    -- VOLATILE supplies a fresh SQL snapshot after acquiring the locks.
    -- Readiness comes exclusively from the first-page SQL plan.
    v_plan := public.read_account_deletion_storage_work_plan(p_owner_id);
    IF (v_plan->'storage_ready') IS DISTINCT FROM 'true'::jsonb THEN
        IF v_request.storage_verified_at IS NOT NULL THEN
            UPDATE public.account_deletion_requests SET storage_verified_at=NULL
            WHERE owner_id=p_owner_id AND operation_id=p_operation_id;
        END IF;
        RETURN NULL;
    END IF;
    IF v_request.storage_verified_at IS NOT NULL THEN
        RETURN v_request.storage_verified_at;
    END IF;
    UPDATE public.account_deletion_requests SET storage_verified_at=clock_timestamp()
    WHERE owner_id=p_owner_id AND operation_id=p_operation_id
    RETURNING storage_verified_at INTO v_verified_at;
    RETURN v_verified_at;
END;
$$;

-- Strip every inherited default grant, including custom roles.
DO $$
DECLARE v_role TEXT;
BEGIN
    FOR v_role IN
        SELECT DISTINCT CASE WHEN a.grantee=0 THEN 'PUBLIC' ELSE quote_ident(r.rolname) END
        FROM pg_proc p
        CROSS JOIN LATERAL aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) a
        LEFT JOIN pg_roles r ON r.oid=a.grantee
        WHERE p.oid='public.verify_account_deletion_storage_internal(uuid,uuid)'::regprocedure
          AND a.grantee<>p.proowner
    LOOP
        EXECUTE 'REVOKE ALL ON FUNCTION public.verify_account_deletion_storage_internal(uuid,uuid) FROM '||v_role;
    END LOOP;
END $$;

COMMIT;
