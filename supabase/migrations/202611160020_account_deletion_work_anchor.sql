BEGIN;

-- Local-only processing reference. purge_data is not permission to delete Auth.
CREATE FUNCTION public.anchor_account_deletion_work_internal(
    p_owner_id UUID, p_operation_id UUID
) RETURNS BOOLEAN
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
    v_job public.deletion_jobs%ROWTYPE;
BEGIN
    -- Preserve the accepted order: profile, 019's installation/predecessor
    -- locks, then the processing reference. No worker or plant path is changed.
    PERFORM 1 FROM public.profiles WHERE id=p_owner_id FOR UPDATE;
    IF NOT public.unlink_account_deletion_installations_internal(p_owner_id,p_operation_id) THEN
        RAISE EXCEPTION 'installation predecessor (019)' USING ERRCODE='P1620';
    END IF;

    -- The owner lock serializes cooperating producers. The unique constraint
    -- also handles a competing insert without replacing any existing fields.
    INSERT INTO public.deletion_jobs(owner_id,operation_id,scope,target_id,state)
    VALUES(p_owner_id,p_operation_id,'account',p_owner_id,'purge_data')
    ON CONFLICT (owner_id,operation_id) DO NOTHING;
    SELECT * INTO v_job FROM public.deletion_jobs
        WHERE owner_id=p_owner_id AND operation_id=p_operation_id FOR UPDATE;
    IF NOT FOUND OR v_job.scope IS DISTINCT FROM 'account'
        OR v_job.target_id IS DISTINCT FROM p_owner_id
        OR v_job.state IS DISTINCT FROM 'purge_data'
        OR v_job.completed_at IS NOT NULL
        OR v_job.encrypted_apple_ref IS NOT NULL THEN
        RAISE EXCEPTION 'incompatible account processing reference' USING ERRCODE='P1620';
    END IF;
    -- Exact replay preserves id, timestamps and every other field. Later,
    -- failed or malformed records are holds, never reset to an earlier state.
    RETURN true;
EXCEPTION WHEN SQLSTATE 'P1620' THEN
    -- A late conflict must undo the entire predecessor chain in this call.
    RETURN false;
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
        WHERE p.oid='public.anchor_account_deletion_work_internal(uuid,uuid)'::regprocedure
            AND a.grantee<>p.proowner
    LOOP
        EXECUTE 'REVOKE ALL ON FUNCTION public.anchor_account_deletion_work_internal(uuid,uuid) FROM '||v_role;
    END LOOP;
END $$;

COMMIT;
