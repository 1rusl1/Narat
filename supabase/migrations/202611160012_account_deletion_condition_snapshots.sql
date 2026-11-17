BEGIN;

-- Private snapshot phase. Retained jobs are never rewritten to make a purge safe.
CREATE FUNCTION public.purge_account_deletion_condition_snapshots_internal(
    p_owner_id UUID, p_operation_id UUID
) RETURNS BOOLEAN
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
    v_edge RECORD;
    v_hold BOOLEAN;
    v_pass INTEGER;
    v_dependency TEXT;
BEGIN
    PERFORM 1 FROM public.profiles WHERE id=p_owner_id FOR UPDATE;
    IF public.verify_account_deletion_storage_internal(p_owner_id,p_operation_id) IS NULL THEN
        RAISE EXCEPTION 'storage verification' USING ERRCODE='P1612';
    END IF;

    -- Match 011/010/004's lock order before acquiring snapshot parents.
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
    PERFORM 1 FROM public.condition_snapshots WHERE owner_id=p_owner_id ORDER BY id FOR UPDATE;

    -- Both directions, including soft-deleted rows and the legacy non-FK alias.
    -- A same-owner pointer must also describe the snapshot's actual parent.
    FOR v_edge IN
        SELECT * FROM (VALUES
            ('condition_snapshots','plants','c.plant_id=p.id','owner_id','false'),
            ('condition_snapshots','guest_drafts','c.draft_id=p.id','guest_owner_id','false'),
            ('plants','condition_snapshots','c.current_condition_snapshot_id=p.id','owner_id',
                'c.id IS DISTINCT FROM p.plant_id'),
            ('plants','condition_snapshots','c.current_snapshot_id=p.id','owner_id',
                'c.id IS DISTINCT FROM p.plant_id'),
            ('guest_drafts','condition_snapshots','c.condition_snapshot_id=p.id','owner_id',
                'c.id IS DISTINCT FROM p.draft_id'),
            ('analysis_jobs','condition_snapshots','c.snapshot_id=p.id','owner_id',
                'c.plant_id IS DISTINCT FROM p.plant_id OR c.draft_id IS DISTINCT FROM p.draft_id'),
            ('analysis_results','condition_snapshots','c.source_snapshot_id=p.id','owner_id',
                'c.plant_id IS DISTINCT FROM p.plant_id OR c.draft_id IS DISTINCT FROM p.draft_id'),
            ('care_plans','condition_snapshots','c.snapshot_id=p.id','owner_id',
                'c.plant_id IS DISTINCT FROM p.plant_id')
        ) AS edges(child_table,parent_table,join_sql,parent_owner,parent_mismatch)
    LOOP
        EXECUTE format(
            'SELECT c.ctid FROM public.%I c JOIN public.%I p ON %s
             WHERE c.%I=$1 OR p.%I=$1 ORDER BY c.ctid,p.ctid FOR UPDATE OF c,p',
            v_edge.child_table,v_edge.parent_table,v_edge.join_sql,
            CASE WHEN v_edge.child_table='guest_drafts' THEN 'guest_owner_id' ELSE 'owner_id' END,
            v_edge.parent_owner) USING p_owner_id;
        -- Refresh after waiting, including updates which only change ownership.
        EXECUTE format(
            'SELECT EXISTS (SELECT 1 FROM public.%I c JOIN public.%I p ON %s
             WHERE (c.%I=$1 OR p.%I=$1)
             AND (c.%I IS DISTINCT FROM p.%I OR (%s)))',
            v_edge.child_table,v_edge.parent_table,v_edge.join_sql,
            CASE WHEN v_edge.child_table='guest_drafts' THEN 'guest_owner_id' ELSE 'owner_id' END,
            v_edge.parent_owner,
            CASE WHEN v_edge.child_table='guest_drafts' THEN 'guest_owner_id' ELSE 'owner_id' END,
            v_edge.parent_owner,v_edge.parent_mismatch) INTO v_hold USING p_owner_id;
        IF v_hold THEN
            RAISE EXCEPTION '%.% ownership/parent',v_edge.child_table,v_edge.parent_table
                USING ERRCODE='P1612';
        END IF;
    END LOOP;
    IF EXISTS (
        SELECT 1 FROM public.condition_snapshots s
        LEFT JOIN public.plants p ON p.id=s.plant_id
        LEFT JOIN public.guest_drafts d ON d.id=s.draft_id
        WHERE s.owner_id=p_owner_id AND
            (num_nonnulls(s.plant_id,s.draft_id)<>1
             OR (s.plant_id IS NOT NULL AND p.id IS NULL)
             OR (s.draft_id IS NOT NULL AND d.id IS NULL))
    ) THEN
        RAISE EXCEPTION 'missing snapshot parent' USING ERRCODE='P1612';
    END IF;

    IF EXISTS (
        SELECT 1 FROM public.plants c WHERE c.owner_id=p_owner_id AND (
            (c.current_condition_snapshot_id IS NOT NULL AND NOT EXISTS (
                SELECT 1 FROM public.condition_snapshots s
                WHERE s.id=c.current_condition_snapshot_id AND s.owner_id=p_owner_id AND s.plant_id=c.id))
            OR (c.current_snapshot_id IS NOT NULL AND NOT EXISTS (
                SELECT 1 FROM public.condition_snapshots s
                WHERE s.id=c.current_snapshot_id AND s.owner_id=p_owner_id AND s.plant_id=c.id)))
    ) THEN
        RAISE EXCEPTION 'unsafe plant aliases' USING ERRCODE='P1612';
    END IF;

    FOR v_pass IN 1..2 LOOP
        IF v_pass=2 THEN
            -- Exactly one predecessor call, only after every preflight is safe.
            IF NOT public.purge_account_deletion_analysis_results_internal(p_owner_id,p_operation_id) THEN
                RAISE EXCEPTION 'analysis predecessor (011)' USING ERRCODE='P1612';
            END IF;
            -- Clear both aliases together: the compatibility trigger otherwise
            -- restores the non-null value. Never clear another snapshot's alias.
            UPDATE public.plants c
            SET current_condition_snapshot_id=NULL,current_snapshot_id=NULL
            WHERE c.owner_id=p_owner_id AND EXISTS (
                SELECT 1 FROM public.condition_snapshots s WHERE s.owner_id=p_owner_id
                AND s.plant_id=c.id
                AND (s.id=c.current_condition_snapshot_id OR s.id=c.current_snapshot_id));
            UPDATE public.guest_drafts c SET condition_snapshot_id=NULL
            WHERE c.guest_owner_id=p_owner_id AND EXISTS (
                SELECT 1 FROM public.condition_snapshots s WHERE s.owner_id=p_owner_id
                AND s.draft_id=c.id AND s.id=c.condition_snapshot_id);
        END IF;
        -- Real FK inventory, including unknown/composite/restrictive children.
        -- Jobs are a hold even for the same owner; their stored input is retained.
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
            WHERE f.contype='f' AND f.confrelid='public.condition_snapshots'::regclass
            GROUP BY f.oid,f.conname,f.conrelid,n.nspname,c.relname
            ORDER BY n.nspname,c.relname,f.conname
        LOOP
            EXECUTE format(
                'SELECT c.ctid FROM %I.%I c JOIN public.condition_snapshots p ON %s
                 WHERE p.owner_id=$1 ORDER BY c.ctid FOR UPDATE OF c',
                v_edge.nspname,v_edge.relname,v_edge.join_sql) USING p_owner_id;
            IF v_pass=1 AND v_edge.parent_keys=ARRAY['id'] AND (
                (v_edge.conrelid='public.analysis_results'::regclass
                    AND v_edge.child_keys=ARRAY['source_snapshot_id']) OR
                (v_edge.conrelid='public.care_plans'::regclass
                    AND v_edge.child_keys=ARRAY['snapshot_id']) OR
                (v_edge.conrelid='public.plants'::regclass
                    AND v_edge.child_keys=ARRAY['current_condition_snapshot_id']) OR
                (v_edge.conrelid='public.guest_drafts'::regclass
                    AND v_edge.child_keys=ARRAY['condition_snapshot_id'])) THEN
                CONTINUE;
            END IF;
            EXECUTE format(
                'SELECT EXISTS (SELECT 1 FROM %I.%I c JOIN public.condition_snapshots p ON %s
                 WHERE p.owner_id=$1)',
                v_edge.nspname,v_edge.relname,v_edge.join_sql) INTO v_hold USING p_owner_id;
            IF v_hold THEN
                RAISE EXCEPTION '%.% constraint %',v_edge.nspname,v_edge.relname,v_edge.conname
                    USING ERRCODE='P1612';
            END IF;
        END LOOP;
    END LOOP;
    -- The legacy alias has no FK and therefore needs a separate final inventory.
    PERFORM c.id FROM public.plants c JOIN public.condition_snapshots s
        ON s.id=c.current_snapshot_id WHERE s.owner_id=p_owner_id ORDER BY c.id FOR UPDATE OF c;
    IF EXISTS (SELECT 1 FROM public.plants c JOIN public.condition_snapshots s
        ON s.id=c.current_snapshot_id WHERE s.owner_id=p_owner_id) THEN
        RAISE EXCEPTION 'remaining legacy snapshot alias' USING ERRCODE='P1612';
    END IF;
    DELETE FROM public.condition_snapshots WHERE owner_id=p_owner_id;
    RETURN true;
EXCEPTION WHEN SQLSTATE 'P1612' THEN
    GET STACKED DIAGNOSTICS v_dependency = MESSAGE_TEXT;
    RAISE NOTICE 'ACCOUNT_DELETION_SNAPSHOT_HOLD: %',v_dependency;
    -- Roll back fresh evidence, predecessor work and reference clearing together.
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
        WHERE p.oid='public.purge_account_deletion_condition_snapshots_internal(uuid,uuid)'::regprocedure
          AND a.grantee<>p.proowner
    LOOP
        EXECUTE 'REVOKE ALL ON FUNCTION public.purge_account_deletion_condition_snapshots_internal(uuid,uuid) FROM '||v_role;
    END LOOP;
END $$;

COMMIT;
