BEGIN;

-- First local data phase only. T082/T083 finalization remains open.
CREATE FUNCTION public.purge_account_deletion_care_leaves_internal(
    p_owner_id UUID, p_operation_id UUID
) RETURNS BOOLEAN
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
    -- Reuse 065's fresh plan and profile/request locks for this transaction.
    IF public.verify_account_deletion_storage_internal(p_owner_id,p_operation_id) IS NULL THEN
        RETURN false;
    END IF;

    DELETE FROM public.recovery_transitions WHERE owner_id=p_owner_id;
    DELETE FROM public.care_reversals WHERE owner_id=p_owner_id;
    DELETE FROM public.schedule_changes WHERE owner_id=p_owner_id;
    DELETE FROM public.notification_claims WHERE owner_id=p_owner_id;
    -- Errors propagate so all deletions and verification changes roll back.
    RETURN true;
END;
$$;

-- Remove PUBLIC and every nonowner default grant, including custom roles.
DO $$
DECLARE v_role TEXT;
BEGIN
    FOR v_role IN
        SELECT DISTINCT CASE WHEN a.grantee=0 THEN 'PUBLIC' ELSE quote_ident(r.rolname) END
        FROM pg_proc p
        CROSS JOIN LATERAL aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) a
        LEFT JOIN pg_roles r ON r.oid=a.grantee
        WHERE p.oid='public.purge_account_deletion_care_leaves_internal(uuid,uuid)'::regprocedure
          AND a.grantee<>p.proowner
    LOOP
        EXECUTE 'REVOKE ALL ON FUNCTION public.purge_account_deletion_care_leaves_internal(uuid,uuid) FROM '||v_role;
    END LOOP;
END $$;

COMMIT;
