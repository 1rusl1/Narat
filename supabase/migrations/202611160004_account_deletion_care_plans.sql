BEGIN;

-- SQL-owner-only plan phase; data/Storage/Auth finalization remains separate.
CREATE FUNCTION public.purge_account_deletion_care_plans_internal(
    p_owner_id UUID, p_operation_id UUID
) RETURNS BOOLEAN
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
    v_edge RECORD;
    v_scope TEXT;
    v_hold BOOLEAN;
BEGIN
    PERFORM 1 FROM public.profiles WHERE id=p_owner_id FOR UPDATE;
    IF public.verify_account_deletion_storage_internal(p_owner_id,p_operation_id) IS NULL THEN
        RAISE SQLSTATE 'P1604';
    END IF;

    -- Preserve 067's journal parent order before taking additional FK locks.
    PERFORM 1 FROM public.care_tasks WHERE owner_id=p_owner_id ORDER BY id FOR UPDATE;
    PERFORM 1 FROM public.care_entries WHERE owner_id=p_owner_id ORDER BY id FOR UPDATE;
    PERFORM 1 FROM public.care_observations WHERE owner_id=p_owner_id ORDER BY id FOR UPDATE;
    PERFORM 1 FROM public.care_plans WHERE owner_id=p_owner_id ORDER BY id FOR UPDATE;
    -- Rules cascade with their plans; protect their incoming links as well.
    PERFORM r.id FROM public.task_rules r JOIN public.care_plans p ON p.id=r.plan_id
        WHERE p.owner_id=p_owner_id ORDER BY r.id FOR UPDATE OF r;

    -- Discover actual FKs, including SET NULL and CASCADE, not just live rows.
    FOR v_edge IN
        SELECT n.nspname AS child_schema, c.relname AS child_table,
            a.attname AS child_column, p.relname AS parent_table,
            cardinality(f.conkey) AS key_count, pa.attname AS parent_column
        FROM pg_constraint f
        JOIN pg_class c ON c.oid=f.conrelid
        JOIN pg_namespace n ON n.oid=c.relnamespace
        JOIN pg_class p ON p.oid=f.confrelid
        JOIN pg_attribute a ON a.attrelid=c.oid AND a.attnum=f.conkey[1]
        JOIN pg_attribute pa ON pa.attrelid=p.oid AND pa.attnum=f.confkey[1]
        WHERE f.contype='f' AND f.confrelid IN
            ('public.care_plans'::regclass,'public.task_rules'::regclass)
        ORDER BY p.relname,n.nspname,c.relname,a.attname,f.oid
    LOOP
        -- Fail closed if the FK shape changes beyond this phase's contract.
        IF v_edge.key_count<>1 OR v_edge.parent_column<>'id' THEN
            RAISE SQLSTATE 'P1604';
        END IF;
        v_scope := CASE WHEN v_edge.parent_table='care_plans' THEN 'p.owner_id=$1'
            ELSE 'EXISTS (SELECT 1 FROM public.care_plans plan
                WHERE plan.id=p.plan_id AND plan.owner_id=$1)' END;
        -- Parent locks exclude new FK links. Existing children also need locks:
        -- changing only owner_id does not revalidate an unchanged FK.
        EXECUTE format(
            'SELECT c.id FROM %I.%I c JOIN public.%I p ON p.id=c.%I
             WHERE %s ORDER BY c.id FOR UPDATE OF c',
            v_edge.child_schema,v_edge.child_table,v_edge.parent_table,
            v_edge.child_column,v_scope) USING p_owner_id;
        -- Separate VOLATILE statement observes rows after any lock wait.
        EXECUTE format(
            'SELECT EXISTS (SELECT 1 FROM %I.%I c JOIN public.%I p ON p.id=c.%I
             WHERE %s AND c.owner_id IS DISTINCT FROM $1)',
            v_edge.child_schema,v_edge.child_table,v_edge.parent_table,
            v_edge.child_column,v_scope) INTO v_hold USING p_owner_id;
        IF v_hold THEN
            RAISE SQLSTATE 'P1604';
        END IF;
    END LOOP;

    IF NOT public.purge_account_deletion_care_journal_internal(p_owner_id,p_operation_id) THEN
        RAISE SQLSTATE 'P1604';
    END IF;
    DELETE FROM public.care_plans WHERE owner_id=p_owner_id;
    RETURN true;
EXCEPTION WHEN SQLSTATE 'P1604' THEN
    -- Includes a nested journal hold and all verification writes in this call.
    RETURN false;
END;
$$;

DO $$
DECLARE v_role TEXT;
BEGIN
    FOR v_role IN
        SELECT DISTINCT CASE WHEN a.grantee=0 THEN 'PUBLIC' ELSE quote_ident(r.rolname) END
        FROM pg_proc p
        CROSS JOIN LATERAL aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) a
        LEFT JOIN pg_roles r ON r.oid=a.grantee
        WHERE p.oid='public.purge_account_deletion_care_plans_internal(uuid,uuid)'::regprocedure
          AND a.grantee<>p.proowner
    LOOP
        EXECUTE 'REVOKE ALL ON FUNCTION public.purge_account_deletion_care_plans_internal(uuid,uuid) FROM '||v_role;
    END LOOP;
END $$;

COMMIT;
