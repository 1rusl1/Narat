BEGIN;

-- SQL-owner-only photo phase; Storage work and retained audit are never rewritten.
CREATE FUNCTION public.purge_account_deletion_photo_rows_internal(
    p_owner_id UUID, p_operation_id UUID
) RETURNS BOOLEAN
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
    v_edge RECORD;
    v_parent REGCLASS;
    v_scope TEXT;
    v_owner TEXT;
    v_hold BOOLEAN;
    v_allowed BOOLEAN;
    v_pass INTEGER;
    v_dependency TEXT;
BEGIN
    PERFORM 1 FROM public.profiles WHERE id=p_owner_id FOR UPDATE;
    IF public.verify_account_deletion_storage_internal(p_owner_id,p_operation_id) IS NULL THEN
        RAISE EXCEPTION 'storage verification' USING ERRCODE='P1613';
    END IF;

    -- Preserve 012 and its predecessors' row lock order.
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
    -- photo_ids has no FK. Row locks cannot prevent a new semantic association.
    -- Only this table needs a writer barrier; retained jobs are never updated.
    LOCK TABLE public.analysis_jobs IN SHARE MODE;
    PERFORM 1 FROM public.photo_assets WHERE owner_id=p_owner_id ORDER BY id FOR UPDATE;

    -- Inventory every outgoing FK, including added/composite parent edges.
    FOR v_edge IN
        SELECT f.confrelid::regclass AS confrelid,f.conname,
            array_agg(a.attname::text ORDER BY k.ord) AS child_keys,
            array_agg(pa.attname::text ORDER BY k.ord) AS parent_keys,
            string_agg(format('c.%I=p.%I',a.attname,pa.attname),' AND ' ORDER BY k.ord) AS join_sql
        FROM pg_constraint f
        CROSS JOIN LATERAL unnest(f.conkey,f.confkey) WITH ORDINALITY k(ck,pk,ord)
        JOIN pg_attribute a ON a.attrelid=f.conrelid AND a.attnum=k.ck
        JOIN pg_attribute pa ON pa.attrelid=f.confrelid AND pa.attnum=k.pk
        WHERE f.contype='f' AND f.conrelid='public.photo_assets'::regclass
        GROUP BY f.oid,f.confrelid,f.conname ORDER BY f.confrelid,f.conname
    LOOP
        v_owner := CASE
            WHEN v_edge.confrelid='public.profiles'::regclass THEN 'id'
            WHEN v_edge.confrelid='public.guest_drafts'::regclass THEN 'guest_owner_id'
            ELSE 'owner_id' END;
        v_allowed := v_edge.parent_keys=ARRAY['id'] AND (
            (v_edge.confrelid='public.profiles'::regclass AND v_edge.child_keys=ARRAY['owner_id']) OR
            (v_edge.confrelid='public.plants'::regclass AND v_edge.child_keys=ARRAY['plant_id']) OR
            (v_edge.confrelid='public.guest_drafts'::regclass AND v_edge.child_keys=ARRAY['draft_id']));
        EXECUTE format(
            'SELECT c.id FROM public.photo_assets c JOIN %s p ON %s
             WHERE c.owner_id=$1 OR to_jsonb(p)->>%L=$1::text
             ORDER BY c.id FOR UPDATE OF c,p',v_edge.confrelid,v_edge.join_sql,v_owner)
            USING p_owner_id;
        EXECUTE format(
            'SELECT EXISTS (SELECT 1 FROM public.photo_assets c JOIN %s p ON %s
             WHERE (c.owner_id=$1 OR to_jsonb(p)->>%L=$1::text)
             AND (NOT $2 OR to_jsonb(p)->>%L IS DISTINCT FROM c.owner_id::text))',
            v_edge.confrelid,v_edge.join_sql,v_owner,v_owner)
            INTO v_hold USING p_owner_id,v_allowed;
        IF v_hold THEN
            RAISE EXCEPTION 'photo parent %',v_edge.conname USING ERRCODE='P1613';
        END IF;
    END LOOP;

    -- Outgoing pointers from retained/removed owner rows must not target a
    -- foreign photo either. Include tombstones and all current FK associations.
    FOR v_edge IN
        SELECT * FROM (VALUES
            ('plants','main_photo_id','owner_id'),
            ('guest_drafts','photo_id','guest_owner_id'),
            ('analysis_results','source_photo_id','owner_id'),
            ('care_plans','source_photo_id','owner_id'),
            ('care_observations','photo_id','owner_id')
        ) AS e(child_table,photo_key,owner_key)
    LOOP
        EXECUTE format(
            'SELECT c.ctid FROM public.%I c JOIN public.photo_assets p ON p.id=c.%I
             WHERE c.%I=$1 OR p.owner_id=$1 ORDER BY c.ctid FOR UPDATE OF c,p',
            v_edge.child_table,v_edge.photo_key,v_edge.owner_key) USING p_owner_id;
        EXECUTE format(
            'SELECT EXISTS (SELECT 1 FROM public.%I c JOIN public.photo_assets p ON p.id=c.%I
             WHERE (c.%I=$1 OR p.owner_id=$1) AND c.%I IS DISTINCT FROM p.owner_id)',
            v_edge.child_table,v_edge.photo_key,v_edge.owner_key,v_edge.owner_key)
            INTO v_hold USING p_owner_id;
        IF v_hold THEN
            RAISE EXCEPTION 'foreign photo pointer %',v_edge.child_table USING ERRCODE='P1613';
        END IF;
    END LOOP;

    -- Both directions, including retained jobs referring to another owner's photo.
    IF EXISTS (
        SELECT 1 FROM public.analysis_jobs j JOIN public.photo_assets a ON a.id=ANY(j.photo_ids)
        WHERE (j.owner_id=p_owner_id OR a.owner_id=p_owner_id)
            AND j.owner_id IS DISTINCT FROM a.owner_id
    ) THEN
        RAISE EXCEPTION 'foreign job photo_ids' USING ERRCODE='P1613';
    END IF;

    PERFORM t.photo_asset_id FROM public.first_aid_photo_upload_tickets t
        JOIN public.photo_assets a ON a.id=t.photo_asset_id
        JOIN public.first_aid_followups f ON f.id=t.control_id
        WHERE a.owner_id=p_owner_id ORDER BY t.photo_asset_id FOR UPDATE OF t,f;
    IF EXISTS (
        SELECT 1 FROM public.first_aid_photo_upload_tickets t
        JOIN public.photo_assets a ON a.id=t.photo_asset_id
        JOIN public.first_aid_followups f ON f.id=t.control_id
        WHERE a.owner_id=p_owner_id AND f.owner_id IS DISTINCT FROM p_owner_id
    ) THEN
        RAISE EXCEPTION 'foreign upload control' USING ERRCODE='P1613';
    END IF;

    FOR v_pass IN 1..2 LOOP
        IF v_pass=2 THEN
            IF NOT public.purge_account_deletion_condition_snapshots_internal(p_owner_id,p_operation_id) THEN
                RAISE EXCEPTION 'snapshot predecessor (012)' USING ERRCODE='P1613';
            END IF;
            UPDATE public.plants p SET main_photo_id=NULL
                WHERE p.owner_id=p_owner_id AND EXISTS (
                    SELECT 1 FROM public.photo_assets a
                    WHERE a.owner_id=p_owner_id AND a.id=p.main_photo_id);
            UPDATE public.guest_drafts g SET photo_id=NULL
                WHERE g.guest_owner_id=p_owner_id AND EXISTS (
                    SELECT 1 FROM public.photo_assets a
                    WHERE a.owner_id=p_owner_id AND a.id=g.photo_id);
        END IF;
        -- Lock all matching children before allowing an edge. Unknown children
        -- of the three supported leaves are holds, even for CASCADE/SET NULL.
        FOREACH v_parent IN ARRAY ARRAY[
            'public.photo_assets'::regclass,'public.diagnosis_upload_tickets'::regclass,
            'public.first_aid_photo_upload_tickets'::regclass,'public.guest_identification_sources'::regclass]
        LOOP
            v_scope := CASE WHEN v_parent='public.photo_assets'::regclass THEN 'p.owner_id=$1'
                WHEN v_parent='public.guest_identification_sources'::regclass THEN
                    'EXISTS (SELECT 1 FROM public.photo_assets a WHERE a.id=p.photo_id AND a.owner_id=$1)'
                ELSE 'EXISTS (SELECT 1 FROM public.photo_assets a WHERE a.id=p.photo_asset_id AND a.owner_id=$1)' END;
            FOR v_edge IN
                SELECT f.conrelid::regclass AS conrelid,f.conname,f.confdeltype,
                    array_agg(a.attname::text ORDER BY k.ord) AS child_keys,
                    array_agg(pa.attname::text ORDER BY k.ord) AS parent_keys,
                    string_agg(format('c.%I=p.%I',a.attname,pa.attname),' AND ' ORDER BY k.ord) AS join_sql
                FROM pg_constraint f
                CROSS JOIN LATERAL unnest(f.conkey,f.confkey) WITH ORDINALITY k(ck,pk,ord)
                JOIN pg_attribute a ON a.attrelid=f.conrelid AND a.attnum=k.ck
                JOIN pg_attribute pa ON pa.attrelid=f.confrelid AND pa.attnum=k.pk
                WHERE f.contype='f' AND f.confrelid=v_parent
                GROUP BY f.oid,f.conrelid,f.conname,f.confdeltype ORDER BY f.conrelid,f.conname
            LOOP
                EXECUTE format(
                    'SELECT c.ctid FROM %s c JOIN %s p ON %s WHERE %s
                     ORDER BY c.ctid FOR UPDATE OF c',v_edge.conrelid,v_parent,v_edge.join_sql,v_scope)
                    USING p_owner_id;
                v_allowed := v_parent='public.photo_assets'::regclass
                    AND v_edge.parent_keys=ARRAY['id'] AND (
                        (v_edge.confdeltype='c' AND (
                            (v_edge.conrelid='public.diagnosis_upload_tickets'::regclass AND v_edge.child_keys=ARRAY['photo_asset_id']) OR
                            (v_edge.conrelid='public.first_aid_photo_upload_tickets'::regclass AND v_edge.child_keys=ARRAY['photo_asset_id']) OR
                            (v_edge.conrelid='public.guest_identification_sources'::regclass AND v_edge.child_keys=ARRAY['photo_id']))) OR
                        (v_pass=1 AND (
                            (v_edge.conrelid='public.plants'::regclass AND v_edge.child_keys=ARRAY['main_photo_id']) OR
                            (v_edge.conrelid='public.guest_drafts'::regclass AND v_edge.child_keys=ARRAY['photo_id']) OR
                            (v_edge.conrelid='public.analysis_results'::regclass AND v_edge.child_keys=ARRAY['source_photo_id']) OR
                            (v_edge.conrelid='public.care_plans'::regclass AND v_edge.child_keys=ARRAY['source_photo_id']) OR
                            (v_edge.conrelid='public.care_observations'::regclass AND v_edge.child_keys=ARRAY['photo_id']))));
                v_owner := CASE WHEN v_edge.conrelid='public.guest_drafts'::regclass
                    THEN 'guest_owner_id' ELSE 'owner_id' END;
                EXECUTE format(
                    'SELECT EXISTS (SELECT 1 FROM %s c JOIN %s p ON %s WHERE %s
                     AND (NOT $2 OR (to_jsonb(c) ? %L AND
                         to_jsonb(c)->>%L IS DISTINCT FROM $1::text)))',
                    v_edge.conrelid,v_parent,v_edge.join_sql,v_scope,v_owner,v_owner)
                    INTO v_hold USING p_owner_id,v_allowed;
                IF v_hold THEN
                    RAISE EXCEPTION 'photo child %',v_edge.conname USING ERRCODE='P1613';
                END IF;
            END LOOP;
        END LOOP;
    END LOOP;
    DELETE FROM public.photo_assets WHERE owner_id=p_owner_id;
    RETURN true;
EXCEPTION WHEN SQLSTATE 'P1613' THEN
    GET STACKED DIAGNOSTICS v_dependency = MESSAGE_TEXT;
    RAISE NOTICE 'ACCOUNT_DELETION_PHOTO_HOLD: %',v_dependency;
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
        WHERE p.oid='public.purge_account_deletion_photo_rows_internal(uuid,uuid)'::regprocedure
          AND a.grantee<>p.proowner
    LOOP
        EXECUTE 'REVOKE ALL ON FUNCTION public.purge_account_deletion_photo_rows_internal(uuid,uuid) FROM '||v_role;
    END LOOP;
END $$;

COMMIT;
