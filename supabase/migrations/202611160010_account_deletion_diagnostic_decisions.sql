BEGIN;

-- Private diagnostic phase. No analysis, plant, profile or Auth finalization.
CREATE FUNCTION public.purge_account_deletion_diagnostic_decisions_internal(
    p_owner_id UUID, p_operation_id UUID
) RETURNS BOOLEAN
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
    v_edge RECORD;
    v_join TEXT;
    v_hold BOOLEAN;
    v_dependency TEXT;
BEGIN
    PERFORM 1 FROM public.profiles WHERE id=p_owner_id FOR UPDATE;
    IF public.verify_account_deletion_storage_internal(p_owner_id,p_operation_id) IS NULL THEN
        RAISE EXCEPTION 'storage verification' USING ERRCODE='P1610';
    END IF;

    -- Keep 004/067's table order before locking diagnostic parents.
    PERFORM 1 FROM public.care_tasks WHERE owner_id=p_owner_id ORDER BY id FOR UPDATE;
    PERFORM 1 FROM public.care_entries WHERE owner_id=p_owner_id ORDER BY id FOR UPDATE;
    PERFORM 1 FROM public.care_observations WHERE owner_id=p_owner_id ORDER BY id FOR UPDATE;
    PERFORM p.id FROM public.care_plans p
        WHERE p.owner_id=p_owner_id OR EXISTS (
            SELECT 1 FROM public.diagnostic_decisions d
            WHERE d.owner_id=p_owner_id AND d.id=p.diagnostic_decision_id)
        ORDER BY p.id FOR UPDATE;
    PERFORM r.id FROM public.task_rules r JOIN public.care_plans p ON p.id=r.plan_id
        WHERE p.owner_id=p_owner_id ORDER BY r.id FOR UPDATE OF r;
    PERFORM 1 FROM public.diagnostic_decisions WHERE owner_id=p_owner_id
        ORDER BY id,revision FOR UPDATE;
    PERFORM 1 FROM public.diagnostic_answers WHERE owner_id=p_owner_id ORDER BY id FOR UPDATE;

    -- These stored links have no FK (and include soft-deleted history).
    -- Check both directions, including mixed ownership across revisions of an id.
    FOR v_edge IN
        SELECT * FROM (VALUES
            ('diagnostic_decisions','diagnostic_decisions','c.id=p.id',
                'diagnostic_decisions.id/revision ownership'),
            ('diagnostic_decisions','diagnostic_decisions','c.origin_decision_id=p.id',
                'diagnostic_decisions.origin_decision_id'),
            ('diagnostic_answers','diagnostic_decisions','c.decision_id=p.id',
                'diagnostic_answers.decision_id'),
            ('diagnostic_decisions','diagnostic_answers','p.id=ANY(c.answer_snapshot_ids)',
                'diagnostic_decisions.answer_snapshot_ids'),
            ('diagnostic_decisions','analysis_results','c.analysis_result_id=p.id',
                'diagnostic_decisions.analysis_result_id'),
            ('care_plans','diagnostic_decisions','c.diagnostic_decision_id=p.id',
                'care_plans.diagnostic_decision_id (including partial legacy keys)')
        ) AS edges(child_table,parent_table,join_sql,dependency)
    LOOP
        EXECUTE format(
            'SELECT c.ctid FROM public.%I c JOIN public.%I p ON %s
             WHERE (c.owner_id=$1 OR p.owner_id=$1)
               AND c.owner_id IS DISTINCT FROM p.owner_id
             ORDER BY c.ctid,p.ctid FOR UPDATE OF c,p',
            v_edge.child_table,v_edge.parent_table,v_edge.join_sql) USING p_owner_id;
        -- Refresh after lock waits; an owner-only update need not recheck a FK.
        EXECUTE format(
            'SELECT EXISTS (SELECT 1 FROM public.%I c JOIN public.%I p ON %s
             WHERE (c.owner_id=$1 OR p.owner_id=$1)
               AND c.owner_id IS DISTINCT FROM p.owner_id)',
            v_edge.child_table,v_edge.parent_table,v_edge.join_sql)
            INTO v_hold USING p_owner_id;
        IF v_hold THEN
            RAISE EXCEPTION '%',v_edge.dependency USING ERRCODE='P1610';
        END IF;
    END LOOP;

    -- Inventory actual incoming references, including upgraded/legacy schemas.
    -- Only 004's exact plan edge is eligible for predecessor cleanup.
    FOR v_edge IN
        SELECT f.conname,f.conrelid,n.nspname,c.relname,p.relname AS parent_table,
            array_agg(a.attname::text ORDER BY k.ord) AS child_keys,
            array_agg(pa.attname::text ORDER BY k.ord) AS parent_keys,
            string_agg(format('c.%I=p.%I',a.attname,pa.attname),' AND ' ORDER BY k.ord) AS join_sql
        FROM pg_constraint f
        JOIN pg_class c ON c.oid=f.conrelid
        JOIN pg_namespace n ON n.oid=c.relnamespace
        JOIN pg_class p ON p.oid=f.confrelid
        CROSS JOIN LATERAL unnest(f.conkey,f.confkey) WITH ORDINALITY k(child_key,parent_key,ord)
        JOIN pg_attribute a ON a.attrelid=f.conrelid AND a.attnum=k.child_key
        JOIN pg_attribute pa ON pa.attrelid=f.confrelid AND pa.attnum=k.parent_key
        WHERE f.contype='f' AND f.confrelid IN
            ('public.diagnostic_decisions'::regclass,'public.diagnostic_answers'::regclass)
        GROUP BY f.oid,f.conname,f.conrelid,n.nspname,c.relname,p.relname
        ORDER BY p.relname,n.nspname,c.relname,f.conname
    LOOP
        v_join := v_edge.join_sql;
        EXECUTE format(
            'SELECT c.ctid FROM %I.%I c JOIN public.%I p ON %s
             WHERE p.owner_id=$1 ORDER BY c.ctid FOR UPDATE OF c',
            v_edge.nspname,v_edge.relname,v_edge.parent_table,v_join) USING p_owner_id;
        IF v_edge.conrelid='public.care_plans'::regclass
            AND v_edge.parent_table='diagnostic_decisions'
            AND v_edge.child_keys=ARRAY['diagnostic_decision_id','diagnostic_decision_revision']
            AND v_edge.parent_keys=ARRAY['id','revision'] THEN
            -- Foreign plan associations were checked above, even partial keys.
            CONTINUE;
        END IF;
        EXECUTE format(
            'SELECT EXISTS (SELECT 1 FROM %I.%I c JOIN public.%I p ON %s WHERE p.owner_id=$1)',
            v_edge.nspname,v_edge.relname,v_edge.parent_table,v_join)
            INTO v_hold USING p_owner_id;
        IF v_hold THEN
            RAISE EXCEPTION '%.% constraint %',v_edge.nspname,v_edge.relname,v_edge.conname
                USING ERRCODE='P1610';
        END IF;
    END LOOP;

    IF NOT public.purge_account_deletion_care_plans_internal(p_owner_id,p_operation_id) THEN
        RAISE EXCEPTION 'purge_account_deletion_care_plans_internal (004)' USING ERRCODE='P1610';
    END IF;
    DELETE FROM public.diagnostic_answers WHERE owner_id=p_owner_id;
    DELETE FROM public.diagnostic_decisions WHERE owner_id=p_owner_id;
    RETURN true;
EXCEPTION WHEN SQLSTATE 'P1610' THEN
    GET STACKED DIAGNOSTICS v_dependency = MESSAGE_TEXT;
    -- The exception block restores evidence and every predecessor mutation.
    RAISE NOTICE 'ACCOUNT_DELETION_DIAGNOSTIC_HOLD: %',v_dependency;
    RETURN false;
END;
$$;

-- Strip all default grants, including custom roles; SQL function owner only.
DO $$
DECLARE v_role TEXT;
BEGIN
    FOR v_role IN
        SELECT DISTINCT CASE WHEN a.grantee=0 THEN 'PUBLIC' ELSE quote_ident(r.rolname) END
        FROM pg_proc p
        CROSS JOIN LATERAL aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) a
        LEFT JOIN pg_roles r ON r.oid=a.grantee
        WHERE p.oid='public.purge_account_deletion_diagnostic_decisions_internal(uuid,uuid)'::regprocedure
          AND a.grantee<>p.proowner
    LOOP
        EXECUTE 'REVOKE ALL ON FUNCTION public.purge_account_deletion_diagnostic_decisions_internal(uuid,uuid) FROM '||v_role;
    END LOOP;
END $$;

COMMIT;
