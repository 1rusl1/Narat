BEGIN;

-- Journal phase only. Parent, Storage and Auth finalization remain separate.
CREATE FUNCTION public.purge_account_deletion_care_journal_internal(
    p_owner_id UUID, p_operation_id UUID
) RETURNS BOOLEAN
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
    v_edge RECORD;
    v_hold BOOLEAN;
BEGIN
    -- Match 065's lock ordering before locking any journal row.
    PERFORM 1 FROM public.profiles WHERE id=p_owner_id FOR UPDATE;
    IF public.verify_account_deletion_storage_internal(p_owner_id,p_operation_id) IS NULL THEN
        RETURN false;
    END IF;

    -- FOR UPDATE conflicts with the KEY SHARE taken by FK writers. Keep a
    -- deterministic table/id order. VOLATILE statements get fresh snapshots
    -- after waits, including FK links committed before these locks were taken.
    PERFORM 1 FROM public.care_tasks WHERE owner_id=p_owner_id ORDER BY id FOR UPDATE;
    PERFORM 1 FROM public.care_entries WHERE owner_id=p_owner_id ORDER BY id FOR UPDATE;
    PERFORM 1 FROM public.care_observations WHERE owner_id=p_owner_id ORDER BY id FOR UPDATE;

    FOR v_edge IN
        SELECT * FROM (VALUES
            ('care_tasks','completed_entry_id','care_entries'),
            ('care_entries','task_id','care_tasks'),
            ('care_observations','task_id','care_tasks'),
            ('first_aid_followups','action_entry_id','care_entries'),
            ('first_aid_followups','control_task_id','care_tasks'),
            ('care_reversals','entry_id','care_entries'),
            ('recovery_transitions','observation_id','care_observations')
        ) AS edges(child_table,child_column,parent_table)
    LOOP
        -- Lock existing referencing rows too. An owner-only UPDATE need not
        -- recheck its unchanged FK, so parent locks alone are insufficient.
        EXECUTE format(
            'SELECT c.id FROM public.%I c JOIN public.%I p ON p.id=c.%I
             WHERE p.owner_id=$1 ORDER BY c.id FOR UPDATE OF c',
            v_edge.child_table,v_edge.parent_table,v_edge.child_column)
        USING p_owner_id;
        EXECUTE format(
            'SELECT EXISTS (SELECT 1 FROM public.%I c JOIN public.%I p ON p.id=c.%I
             WHERE p.owner_id=$1 AND c.owner_id IS DISTINCT FROM $1)',
            v_edge.child_table,v_edge.parent_table,v_edge.child_column)
        INTO v_hold USING p_owner_id;
        IF v_hold THEN
            -- Unwind 065's evidence update as well as any work in this call.
            RAISE EXCEPTION 'ACCOUNT_DELETION_CROSS_OWNER_JOURNAL_LINK' USING ERRCODE='P0067';
        END IF;
    END LOOP;

    IF NOT public.purge_account_deletion_care_leaves_internal(p_owner_id,p_operation_id) THEN
        RETURN false;
    END IF;
    DELETE FROM public.care_observations WHERE owner_id=p_owner_id;
    -- The schema nulls same-owner completed_entry_id and action_entry_id.
    DELETE FROM public.care_entries WHERE owner_id=p_owner_id;
    -- The schema nulls same-owner control_task_id.
    DELETE FROM public.care_tasks WHERE owner_id=p_owner_id;
    RETURN true;
EXCEPTION WHEN SQLSTATE 'P0067' THEN
    RETURN false;
END;
$$;

-- Strip PUBLIC and every nonowner default grant, including custom roles.
DO $$
DECLARE v_role TEXT;
BEGIN
    FOR v_role IN
        SELECT DISTINCT CASE WHEN a.grantee=0 THEN 'PUBLIC' ELSE quote_ident(r.rolname) END
        FROM pg_proc p
        CROSS JOIN LATERAL aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) a
        LEFT JOIN pg_roles r ON r.oid=a.grantee
        WHERE p.oid='public.purge_account_deletion_care_journal_internal(uuid,uuid)'::regprocedure
          AND a.grantee<>p.proowner
    LOOP
        EXECUTE 'REVOKE ALL ON FUNCTION public.purge_account_deletion_care_journal_internal(uuid,uuid) FROM '||v_role;
    END LOOP;
END $$;

COMMIT;
