BEGIN;

-- Durable local prerequisite only: saved evidence never authorizes finalization.
-- Retention and claim/quota purging require separate decisions.
CREATE TABLE public.account_deletion_proofs (
    owner_id UUID NOT NULL PRIMARY KEY,
    operation_id UUID NOT NULL,
    deletion_job_id UUID NOT NULL,
    requested_at TIMESTAMPTZ NOT NULL,
    storage_verified_at TIMESTAMPTZ NOT NULL
);
ALTER TABLE public.account_deletion_proofs ENABLE ROW LEVEL SECURITY;

CREATE FUNCTION public.persist_account_deletion_proof_internal(
    p_owner_id UUID, p_operation_id UUID
) RETURNS BOOLEAN
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
    v_request public.account_deletion_requests%ROWTYPE;
    v_job public.deletion_jobs%ROWTYPE;
    v_proof public.account_deletion_proofs%ROWTYPE;
BEGIN
    -- Same owner serialization point as 020, including every replay.
    PERFORM 1 FROM public.profiles WHERE id=p_owner_id FOR UPDATE;
    IF NOT FOUND OR p_owner_id IS NULL OR p_operation_id IS NULL THEN
        RETURN false;
    END IF;
    -- Always repeat fresh Storage/receipt validation before reading saved proof.
    IF NOT public.anchor_account_deletion_work_internal(p_owner_id,p_operation_id) THEN
        RAISE EXCEPTION 'work anchor (020) hold' USING ERRCODE='P1621';
    END IF;
    SELECT * INTO v_request FROM public.account_deletion_requests
        WHERE owner_id=p_owner_id FOR UPDATE;
    IF NOT FOUND OR v_request.operation_id IS DISTINCT FROM p_operation_id
        OR v_request.requested_at IS NULL OR v_request.storage_verified_at IS NULL THEN
        RAISE EXCEPTION 'request identity hold' USING ERRCODE='P1621';
    END IF;
    SELECT * INTO v_job FROM public.deletion_jobs
        WHERE owner_id=p_owner_id AND operation_id=p_operation_id FOR UPDATE;
    IF NOT FOUND OR v_job.scope IS DISTINCT FROM 'account'
        OR v_job.target_id IS DISTINCT FROM p_owner_id
        OR v_job.state IS DISTINCT FROM 'purge_data'
        OR v_job.completed_at IS NOT NULL OR v_job.encrypted_apple_ref IS NOT NULL THEN
        RAISE EXCEPTION 'processing reference hold' USING ERRCODE='P1621';
    END IF;
    INSERT INTO public.account_deletion_proofs(
        owner_id,operation_id,deletion_job_id,requested_at,storage_verified_at)
    VALUES(p_owner_id,p_operation_id,v_job.id,v_request.requested_at,v_request.storage_verified_at)
    ON CONFLICT (owner_id) DO NOTHING;
    SELECT * INTO v_proof FROM public.account_deletion_proofs
        WHERE owner_id=p_owner_id FOR UPDATE;
    IF NOT FOUND OR v_proof.owner_id IS DISTINCT FROM p_owner_id
        OR v_proof.operation_id IS DISTINCT FROM p_operation_id
        OR v_proof.deletion_job_id IS DISTINCT FROM v_job.id
        OR v_proof.requested_at IS DISTINCT FROM v_request.requested_at
        OR v_proof.storage_verified_at IS DISTINCT FROM v_request.storage_verified_at THEN
        RAISE EXCEPTION 'durable identity hold' USING ERRCODE='P1621';
    END IF;
    RETURN true;
EXCEPTION WHEN SQLSTATE 'P1621' THEN
    -- The exception subtransaction restores all predecessor writes on a late hold.
    RETURN false;
END;
$$;

-- Remove all default ACL entries, including grants to custom/inherited roles.
DO $$
DECLARE v_role TEXT;
BEGIN
    FOR v_role IN
        SELECT DISTINCT CASE WHEN a.grantee=0 THEN 'PUBLIC' ELSE quote_ident(r.rolname) END
        FROM pg_class c
        CROSS JOIN LATERAL aclexplode(coalesce(c.relacl,acldefault('r',c.relowner))) a
        LEFT JOIN pg_roles r ON r.oid=a.grantee
        WHERE c.oid='public.account_deletion_proofs'::regclass AND a.grantee<>c.relowner
    LOOP
        EXECUTE 'REVOKE ALL ON TABLE public.account_deletion_proofs FROM '||v_role;
    END LOOP;
    FOR v_role IN
        SELECT DISTINCT CASE WHEN a.grantee=0 THEN 'PUBLIC' ELSE quote_ident(r.rolname) END
        FROM pg_proc p
        CROSS JOIN LATERAL aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) a
        LEFT JOIN pg_roles r ON r.oid=a.grantee
        WHERE p.oid='public.persist_account_deletion_proof_internal(uuid,uuid)'::regprocedure
            AND a.grantee<>p.proowner
    LOOP
        EXECUTE 'REVOKE ALL ON FUNCTION public.persist_account_deletion_proof_internal(uuid,uuid) FROM '||v_role;
    END LOOP;
END $$;

COMMIT;
