BEGIN;

-- Local-only forward step. The accepted 018 chain owns authorization, fresh
-- Storage verification and readiness, including on empty-set retries.
CREATE FUNCTION public.unlink_account_deletion_installations_internal(
    p_owner_id UUID, p_operation_id UUID
) RETURNS BOOLEAN
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
    -- All association producers serialize on the target profile first:
    -- register_installation_access, bind_installation_{to_owner,credential},
    -- merge_installation_starters and get_analysis_access_snapshot.
    -- Legacy commit_guest_claim takes this lock through advance_owner_watermark
    -- before calling bind. Photo claim prepare/process take profile locks before
    -- the installation and cannot associate a deleting target.
    PERFORM 1 FROM public.profiles WHERE id=p_owner_id FOR UPDATE;
    -- Lock the current rows, in stable order, before 018 takes job/draft locks.
    -- Another active owner's bind can append under this same installation lock.
    -- Updating the locked row's current array preserves that association.
    PERFORM i.id FROM public.installation_access i
        WHERE p_owner_id=ANY(i.linked_owner_ids) ORDER BY i.id FOR UPDATE;
    -- array_remove supports only one-dimensional arrays. Reject legacy null
    -- aliases and noncanonical bounds too, without silently rewriting neighbors.
    IF EXISTS (SELECT 1 FROM public.installation_access i
        WHERE p_owner_id=ANY(i.linked_owner_ids) AND (
            array_ndims(i.linked_owner_ids) IS DISTINCT FROM 1
            OR array_lower(i.linked_owner_ids,1) IS DISTINCT FROM 1
            OR EXISTS (SELECT 1 FROM unnest(i.linked_owner_ids) a(owner_id)
                WHERE a.owner_id IS NULL))) THEN
        RAISE EXCEPTION 'unsupported installation aliases' USING ERRCODE='P1619';
    END IF;
    IF NOT public.purge_account_deletion_diagnosis_runtime_internal(p_owner_id,p_operation_id) THEN
        RAISE EXCEPTION 'diagnosis runtime predecessor (018)' USING ERRCODE='P1619';
    END IF;
    -- Remove every occurrence of exactly this UUID. Keep timestamps, digests,
    -- quota flags, job pointers and the ordered remaining aliases byte-exact.
    UPDATE public.installation_access
        SET linked_owner_ids=array_remove(linked_owner_ids,p_owner_id)
        WHERE p_owner_id=ANY(linked_owner_ids);
    RETURN true;
EXCEPTION WHEN SQLSTATE 'P1619' THEN
    -- A hold rolls back verification and every preceding phase in this call.
    RETURN false;
END;
$$;

-- Strip inherited default grants, including custom roles.
DO $$
DECLARE v_role TEXT;
BEGIN
    FOR v_role IN
        SELECT DISTINCT CASE WHEN a.grantee=0 THEN 'PUBLIC' ELSE quote_ident(r.rolname) END
        FROM pg_proc p
        CROSS JOIN LATERAL aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) a
        LEFT JOIN pg_roles r ON r.oid=a.grantee
        WHERE p.oid='public.unlink_account_deletion_installations_internal(uuid,uuid)'::regprocedure
            AND a.grantee<>p.proowner
    LOOP
        EXECUTE 'REVOKE ALL ON FUNCTION public.unlink_account_deletion_installations_internal(uuid,uuid) FROM '||v_role;
    END LOOP;
END $$;

COMMIT;
