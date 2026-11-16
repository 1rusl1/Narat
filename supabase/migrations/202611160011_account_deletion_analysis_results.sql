BEGIN;

-- Private result phase. Jobs, runtime, quota, plants and Auth remain intact.
CREATE FUNCTION public.purge_account_deletion_analysis_results_internal(
    p_owner_id UUID, p_operation_id UUID
) RETURNS BOOLEAN
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
    v_edge RECORD;
    v_hold BOOLEAN;
    v_dependency TEXT;
    v_pass INTEGER;
BEGIN
    PERFORM 1 FROM public.profiles WHERE id=p_owner_id FOR UPDATE;
    IF public.verify_account_deletion_storage_internal(p_owner_id,p_operation_id) IS NULL THEN
        RAISE EXCEPTION 'storage verification' USING ERRCODE='P1611';
    END IF;

    -- Preserve 010's predecessor lock order before locking result parents.
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
    PERFORM 1 FROM public.analysis_results WHERE owner_id=p_owner_id ORDER BY id FOR UPDATE;

    -- Ownership anchors, including origin_job_id's stored lineage (no FK).
    -- Global KB/protocol records and opaque origin_analysis_id are not owners.
    -- Inspect both directions; include soft-deleted history and nullable links.
    FOR v_edge IN
        SELECT * FROM (VALUES
            ('analysis_results','analysis_jobs','c.job_id=p.id','owner_id'),
            ('analysis_results','analysis_jobs','c.origin_job_id=p.id','owner_id'),
            ('analysis_results','plants','c.plant_id=p.id','owner_id'),
            ('analysis_results','guest_drafts','c.draft_id=p.id','guest_owner_id'),
            ('analysis_results','photo_assets','c.source_photo_id=p.id','owner_id'),
            ('analysis_results','condition_snapshots','c.source_snapshot_id=p.id','owner_id'),
            ('diagnostic_decisions','analysis_results','c.analysis_result_id=p.id','owner_id'),
            ('care_plans','analysis_results','c.source_analysis_id=p.id','owner_id')
        ) AS edges(child_table,parent_table,join_sql,parent_owner)
    LOOP
        EXECUTE format(
            'SELECT c.ctid FROM public.%I c JOIN public.%I p ON %s
             WHERE c.owner_id=$1 OR p.%I=$1 ORDER BY c.ctid,p.ctid FOR UPDATE OF c,p',
            v_edge.child_table,v_edge.parent_table,v_edge.join_sql,v_edge.parent_owner)
            USING p_owner_id;
        -- Fresh snapshot after any lock wait, including owner-only updates.
        EXECUTE format(
            'SELECT EXISTS (SELECT 1 FROM public.%I c JOIN public.%I p ON %s
             WHERE (c.owner_id=$1 OR p.%I=$1) AND c.owner_id IS DISTINCT FROM p.%I)',
            v_edge.child_table,v_edge.parent_table,v_edge.join_sql,
            v_edge.parent_owner,v_edge.parent_owner) INTO v_hold USING p_owner_id;
        IF v_hold THEN
            RAISE EXCEPTION '%.% ownership',v_edge.child_table,v_edge.parent_table
                USING ERRCODE='P1611';
        END IF;
    END LOOP;

    -- Inventory every actual incoming FK, irrespective of delete action.
    -- Before 010, allow only its exact canonical children. After 010, require
    -- no references at all so no cascade/nulling can do work outside that phase.
    FOR v_pass IN 1..2 LOOP
        IF v_pass=2 AND NOT public.purge_account_deletion_diagnostic_decisions_internal(
            p_owner_id,p_operation_id) THEN
            RAISE EXCEPTION 'diagnostic predecessor (010)' USING ERRCODE='P1611';
        END IF;
        FOR v_edge IN
            SELECT f.conname,f.conrelid,n.nspname,c.relname,
                array_agg(a.attname::text ORDER BY k.ord) AS child_keys,
                array_agg(pa.attname::text ORDER BY k.ord) AS parent_keys,
                string_agg(format('c.%I=p.%I',a.attname,pa.attname),' AND ' ORDER BY k.ord) AS join_sql
            FROM pg_constraint f
            JOIN pg_class c ON c.oid=f.conrelid
            JOIN pg_namespace n ON n.oid=c.relnamespace
            CROSS JOIN LATERAL unnest(f.conkey,f.confkey) WITH ORDINALITY k(child_key,parent_key,ord)
            JOIN pg_attribute a ON a.attrelid=f.conrelid AND a.attnum=k.child_key
            JOIN pg_attribute pa ON pa.attrelid=f.confrelid AND pa.attnum=k.parent_key
            WHERE f.contype='f' AND f.confrelid='public.analysis_results'::regclass
            GROUP BY f.oid,f.conname,f.conrelid,n.nspname,c.relname
            ORDER BY n.nspname,c.relname,f.conname
        LOOP
            EXECUTE format(
                'SELECT c.ctid FROM %I.%I c JOIN public.analysis_results p ON %s
                 WHERE p.owner_id=$1 ORDER BY c.ctid FOR UPDATE OF c',
                v_edge.nspname,v_edge.relname,v_edge.join_sql) USING p_owner_id;
            IF v_pass=1 AND v_edge.parent_keys=ARRAY['id'] AND (
                (v_edge.conrelid='public.diagnostic_decisions'::regclass
                    AND v_edge.child_keys=ARRAY['analysis_result_id']) OR
                (v_edge.conrelid='public.care_plans'::regclass
                    AND v_edge.child_keys=ARRAY['source_analysis_id'])) THEN
                CONTINUE;
            END IF;
            EXECUTE format(
                'SELECT EXISTS (SELECT 1 FROM %I.%I c JOIN public.analysis_results p ON %s
                 WHERE p.owner_id=$1)',
                v_edge.nspname,v_edge.relname,v_edge.join_sql) INTO v_hold USING p_owner_id;
            IF v_hold THEN
                RAISE EXCEPTION '%.% constraint %',v_edge.nspname,v_edge.relname,v_edge.conname
                    USING ERRCODE='P1611';
            END IF;
        END LOOP;
    END LOOP;
    DELETE FROM public.analysis_results WHERE owner_id=p_owner_id;
    RETURN true;
EXCEPTION WHEN SQLSTATE 'P1611' THEN
    GET STACKED DIAGNOSTICS v_dependency = MESSAGE_TEXT;
    RAISE NOTICE 'ACCOUNT_DELETION_ANALYSIS_HOLD: %',v_dependency;
    -- Restore verification evidence and every predecessor mutation on a hold.
    RETURN false;
END;
$$;

-- SQL function owner only, including installations with custom default grants.
DO $$
DECLARE v_role TEXT;
BEGIN
    FOR v_role IN
        SELECT DISTINCT CASE WHEN a.grantee=0 THEN 'PUBLIC' ELSE quote_ident(r.rolname) END
        FROM pg_proc p
        CROSS JOIN LATERAL aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) a
        LEFT JOIN pg_roles r ON r.oid=a.grantee
        WHERE p.oid='public.purge_account_deletion_analysis_results_internal(uuid,uuid)'::regprocedure
          AND a.grantee<>p.proowner
    LOOP
        EXECUTE 'REVOKE ALL ON FUNCTION public.purge_account_deletion_analysis_results_internal(uuid,uuid) FROM '||v_role;
    END LOOP;
END $$;

COMMIT;
