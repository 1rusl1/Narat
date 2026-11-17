BEGIN;

-- SQL owner only: 014 removes instances after 013, never Auth or retained audit.
CREATE FUNCTION public.purge_account_deletion_plant_rows_internal(
    p_owner_id UUID, p_operation_id UUID
) RETURNS BOOLEAN
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
    v_edge RECORD;
    v_hold BOOLEAN;
    v_allowed BOOLEAN;
    v_anchor BOOLEAN;
    v_pass INTEGER;
    v_ids UUID[];
    v_dependency TEXT;
BEGIN
    PERFORM 1 FROM public.profiles WHERE id=p_owner_id FOR UPDATE;
    -- Older/malformed schemas cannot assert ownership of the two retained
    -- SET NULL anchors. Check before 065, whose plan also reads these columns.
    IF NOT EXISTS (SELECT 1 FROM pg_attribute
        WHERE attrelid='public.analysis_jobs'::regclass AND attname='owner_id'
            AND atttypid='uuid'::regtype AND NOT attisdropped)
        OR NOT EXISTS (SELECT 1 FROM pg_attribute
        WHERE attrelid='public.draft_claims'::regclass AND attname='target_owner_id'
            AND atttypid='uuid'::regtype AND NOT attisdropped) THEN
        RAISE EXCEPTION 'anchor ownership schema' USING ERRCODE='P1614';
    END IF;
    IF public.verify_account_deletion_storage_internal(p_owner_id,p_operation_id) IS NULL THEN
        RAISE EXCEPTION 'storage verification' USING ERRCODE='P1614';
    END IF;

    -- The legacy current_snapshot_id alias has no FK. Prevent a new
    -- association while 013/012 removes this owner's snapshots. Serialize the
    -- writer barrier before row locks; other tables retain targeted FK locks.
    IF EXISTS (SELECT 1 FROM public.condition_snapshots WHERE owner_id=p_owner_id) THEN
        LOCK TABLE public.plants IN SHARE ROW EXCLUSIVE MODE;
    END IF;

    -- Match 013's existing lock order before taking the instance set.
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
    PERFORM 1 FROM public.photo_assets WHERE owner_id=p_owner_id ORDER BY id FOR UPDATE;
    PERFORM 1 FROM public.plants WHERE owner_id=p_owner_id ORDER BY id FOR UPDATE;
    SELECT coalesce(array_agg(id ORDER BY id),'{}'::uuid[]) INTO v_ids
        FROM public.plants WHERE owner_id=p_owner_id;

    -- Every actual outgoing FK, including unexpected/composite legacy edges.
    FOR v_edge IN
        SELECT f.confrelid::regclass AS parent_table,f.conname,
            array_agg(a.attname::text ORDER BY k.ord) AS child_keys,
            array_agg(pa.attname::text ORDER BY k.ord) AS parent_keys,
            string_agg(format('c.%I=p.%I',a.attname,pa.attname),' AND ' ORDER BY k.ord) AS join_sql
        FROM pg_constraint f
        CROSS JOIN LATERAL unnest(f.conkey,f.confkey) WITH ORDINALITY k(ck,pk,ord)
        JOIN pg_attribute a ON a.attrelid=f.conrelid AND a.attnum=k.ck
        JOIN pg_attribute pa ON pa.attrelid=f.confrelid AND pa.attnum=k.pk
        WHERE f.contype='f' AND f.conrelid='public.plants'::regclass
        GROUP BY f.oid,f.confrelid,f.conname ORDER BY f.confrelid,f.conname
    LOOP
        v_allowed := v_edge.parent_keys=ARRAY['id'] AND (
            (v_edge.parent_table='public.profiles'::regclass AND v_edge.child_keys=ARRAY['owner_id']) OR
            (v_edge.parent_table='public.catalogue_taxa'::regclass AND v_edge.child_keys=ARRAY['taxon_id']) OR
            (v_edge.parent_table='public.rooms'::regclass AND v_edge.child_keys=ARRAY['room_id']) OR
            (v_edge.parent_table='public.photo_assets'::regclass AND v_edge.child_keys=ARRAY['main_photo_id']) OR
            (v_edge.parent_table='public.condition_snapshots'::regclass
                AND v_edge.child_keys=ARRAY['current_condition_snapshot_id']));
        EXECUTE format(
            'SELECT c.id FROM public.plants c JOIN %s p ON %s
             WHERE c.id=ANY($1) ORDER BY c.id FOR UPDATE OF c,p',
            v_edge.parent_table,v_edge.join_sql) USING v_ids;
        EXECUTE format(
            'SELECT EXISTS (SELECT 1 FROM public.plants c JOIN %s p ON %s
             WHERE c.id=ANY($1) AND (NOT $2 OR
                ($3 AND to_jsonb(p)->>''owner_id'' IS DISTINCT FROM $4::text)))',
            v_edge.parent_table,v_edge.join_sql)
            INTO v_hold USING v_ids,v_allowed,
                v_edge.parent_table NOT IN ('public.profiles'::regclass,'public.catalogue_taxa'::regclass),
                p_owner_id;
        IF v_hold THEN
            RAISE EXCEPTION 'plant parent %',v_edge.conname USING ERRCODE='P1614';
        END IF;
    END LOOP;

    -- Explicit semantic inventory also works when an upgraded schema lacks an
    -- FK. It covers both directions, tombstones and missing ownership assertions.
    -- origin_draft_id is provenance of a guest transfer, not the instance owner.
    FOR v_edge IN
        SELECT * FROM (VALUES
            ('analysis_jobs','plant_id','owner_id'),
            ('draft_claims','result_plant_id','target_owner_id'),
            ('condition_snapshots','plant_id','owner_id'),
            ('photo_assets','plant_id','owner_id'),
            ('analysis_results','plant_id','owner_id'),
            ('care_plans','plant_id','owner_id'),
            ('basic_care_memberships','plant_id','owner_id'),
            ('first_aid_followups','plant_id','owner_id'),
            ('task_rules','plant_id','owner_id'),
            ('care_tasks','plant_id','owner_id'),
            ('care_entries','plant_id','owner_id'),
            ('schedule_changes','plant_id','owner_id'),
            ('care_observations','plant_id','owner_id'),
            ('recovery_transitions','plant_id','owner_id')
        ) AS e(child_table,plant_key,owner_key)
    LOOP
        -- If a legacy semantic link has no FK, a bounded table writer barrier
        -- is necessary; row locks alone cannot exclude new non-FK references.
        IF NOT EXISTS (
            SELECT 1 FROM pg_constraint f
            JOIN pg_attribute a ON a.attrelid=f.conrelid AND a.attnum=f.conkey[1]
            WHERE f.contype='f' AND f.conrelid=to_regclass('public.'||v_edge.child_table)
                AND f.confrelid='public.plants'::regclass
                AND cardinality(f.conkey)=1 AND a.attname=v_edge.plant_key
        ) THEN
            EXECUTE format('LOCK TABLE public.%I IN SHARE ROW EXCLUSIVE MODE',v_edge.child_table);
        END IF;
        EXECUTE format(
            'SELECT c.ctid FROM public.%I c JOIN public.plants p ON p.id=c.%I
             WHERE p.id=ANY($1) OR to_jsonb(c)->>%L=$2::text
             ORDER BY c.ctid,p.id FOR UPDATE OF c,p',
            v_edge.child_table,v_edge.plant_key,v_edge.owner_key) USING v_ids,p_owner_id;
        EXECUTE format(
            'SELECT EXISTS (SELECT 1 FROM public.%I c LEFT JOIN public.plants p ON p.id=c.%I
             WHERE (p.id=ANY($1) OR to_jsonb(c)->>%L=$2::text) AND c.%I IS NOT NULL
             AND (p.id IS NULL OR to_jsonb(c)->>%L IS DISTINCT FROM p.owner_id::text))',
            v_edge.child_table,v_edge.plant_key,v_edge.owner_key,v_edge.plant_key,v_edge.owner_key)
            INTO v_hold USING v_ids,p_owner_id;
        IF v_hold THEN
            RAISE EXCEPTION 'plant owner link %',v_edge.child_table USING ERRCODE='P1614';
        END IF;
    END LOOP;

    -- The legacy snapshot alias has no FK. 012 validates its parent and clears
    -- both aliases together. Lock the linked rows before delegating that check.
    PERFORM p.id FROM public.plants p JOIN public.condition_snapshots s ON s.id=p.current_snapshot_id
        WHERE p.owner_id=p_owner_id OR s.owner_id=p_owner_id ORDER BY p.id FOR UPDATE OF p,s;
    IF EXISTS (SELECT 1 FROM public.plants p JOIN public.condition_snapshots s ON s.id=p.current_snapshot_id
        WHERE (p.owner_id=p_owner_id OR s.owner_id=p_owner_id)
            AND (p.owner_id IS DISTINCT FROM s.owner_id OR p.id IS DISTINCT FROM s.plant_id)) THEN
        RAISE EXCEPTION 'legacy snapshot owner' USING ERRCODE='P1614';
    END IF;

    FOR v_pass IN 1..2 LOOP
        IF v_pass=2 AND NOT public.purge_account_deletion_photo_rows_internal(p_owner_id,p_operation_id) THEN
            RAISE EXCEPTION 'photo predecessor (013)' USING ERRCODE='P1614';
        END IF;
        -- Inventory actual incoming FKs, independent of delete action.
        FOR v_edge IN
            SELECT f.conrelid::regclass AS child_table,f.conname,f.confdeltype,
                array_agg(a.attname::text ORDER BY k.ord) AS child_keys,
                array_agg(pa.attname::text ORDER BY k.ord) AS parent_keys,
                string_agg(format('c.%I=p.%I',a.attname,pa.attname),' AND ' ORDER BY k.ord) AS join_sql
            FROM pg_constraint f
            CROSS JOIN LATERAL unnest(f.conkey,f.confkey) WITH ORDINALITY k(ck,pk,ord)
            JOIN pg_attribute a ON a.attrelid=f.conrelid AND a.attnum=k.ck
            JOIN pg_attribute pa ON pa.attrelid=f.confrelid AND pa.attnum=k.pk
            WHERE f.contype='f' AND f.confrelid='public.plants'::regclass
            GROUP BY f.oid,f.conrelid,f.conname,f.confdeltype ORDER BY f.conrelid,f.conname
        LOOP
            v_anchor := v_edge.parent_keys=ARRAY['id'] AND v_edge.confdeltype='n' AND (
                (v_edge.child_table='public.analysis_jobs'::regclass AND v_edge.child_keys=ARRAY['plant_id']) OR
                (v_edge.child_table='public.draft_claims'::regclass AND v_edge.child_keys=ARRAY['result_plant_id']));
            v_allowed := v_anchor OR (v_pass=1 AND v_edge.parent_keys=ARRAY['id']
                AND v_edge.child_keys=ARRAY['plant_id'] AND v_edge.child_table IN (
                    'public.condition_snapshots'::regclass,'public.photo_assets'::regclass,
                    'public.analysis_results'::regclass,'public.care_plans'::regclass,
                    'public.task_rules'::regclass,'public.care_tasks'::regclass,
                    'public.care_entries'::regclass,'public.schedule_changes'::regclass,
                    'public.care_observations'::regclass,'public.recovery_transitions'::regclass));
            EXECUTE format(
                'SELECT c.ctid FROM %s c JOIN public.plants p ON %s
                 WHERE p.id=ANY($1) ORDER BY c.ctid FOR UPDATE OF c',
                v_edge.child_table,v_edge.join_sql) USING v_ids;
            EXECUTE format(
                'SELECT EXISTS (SELECT 1 FROM %s c JOIN public.plants p ON %s
                 WHERE p.id=ANY($1) AND (NOT $2 OR to_jsonb(c)->>%L IS DISTINCT FROM $3::text))',
                v_edge.child_table,v_edge.join_sql,
                CASE WHEN v_edge.child_table='public.draft_claims'::regclass
                    THEN 'target_owner_id' ELSE 'owner_id' END)
                INTO v_hold USING v_ids,v_allowed,p_owner_id;
            IF v_hold THEN
                RAISE EXCEPTION 'plant child %',v_edge.conname USING ERRCODE='P1614';
            END IF;
        END LOOP;
        -- Even without an FK, no semantic child may disappear implicitly.
        FOR v_edge IN
            SELECT * FROM (VALUES
                ('condition_snapshots'),('photo_assets'),('analysis_results'),('care_plans'),
                ('basic_care_memberships'),('first_aid_followups'),('task_rules'),('care_tasks'),
                ('care_entries'),('schedule_changes'),('care_observations'),('recovery_transitions')
            ) AS e(child_table)
        LOOP
            IF v_pass=1 AND v_edge.child_table NOT IN ('basic_care_memberships','first_aid_followups') THEN
                CONTINUE;
            END IF;
            EXECUTE format('SELECT EXISTS (SELECT 1 FROM public.%I WHERE plant_id=ANY($1))',
                v_edge.child_table) INTO v_hold USING v_ids;
            IF v_hold THEN
                RAISE EXCEPTION 'remaining plant child %',v_edge.child_table USING ERRCODE='P1614';
            END IF;
        END LOOP;
        -- A non-null retained anchor needs the exact bounded SET NULL FK,
        -- even on legacy schemas where only the semantic column remains.
        IF EXISTS (SELECT 1 FROM public.analysis_jobs WHERE plant_id=ANY(v_ids)) AND NOT EXISTS (
            SELECT 1 FROM pg_constraint f
            JOIN pg_attribute a ON a.attrelid=f.conrelid AND a.attnum=f.conkey[1]
            JOIN pg_attribute p ON p.attrelid=f.confrelid AND p.attnum=f.confkey[1]
            WHERE f.contype='f' AND f.conrelid='public.analysis_jobs'::regclass
                AND f.confrelid='public.plants'::regclass AND cardinality(f.conkey)=1
                AND a.attname='plant_id' AND p.attname='id' AND f.confdeltype='n')
            OR EXISTS (SELECT 1 FROM public.draft_claims WHERE result_plant_id=ANY(v_ids)) AND NOT EXISTS (
            SELECT 1 FROM pg_constraint f
            JOIN pg_attribute a ON a.attrelid=f.conrelid AND a.attnum=f.conkey[1]
            JOIN pg_attribute p ON p.attrelid=f.confrelid AND p.attnum=f.confkey[1]
            WHERE f.contype='f' AND f.conrelid='public.draft_claims'::regclass
                AND f.confrelid='public.plants'::regclass AND cardinality(f.conkey)=1
                AND a.attname='result_plant_id' AND p.attname='id' AND f.confdeltype='n') THEN
            RAISE EXCEPTION 'unsupported retained anchor' USING ERRCODE='P1614';
        END IF;
    END LOOP;
    DELETE FROM public.plants WHERE owner_id=p_owner_id AND id=ANY(v_ids);
    RETURN true;
EXCEPTION WHEN SQLSTATE 'P1614' THEN
    GET STACKED DIAGNOSTICS v_dependency = MESSAGE_TEXT;
    RAISE NOTICE 'ACCOUNT_DELETION_PLANT_HOLD: %',v_dependency;
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
        WHERE p.oid='public.purge_account_deletion_plant_rows_internal(uuid,uuid)'::regprocedure
            AND a.grantee<>p.proowner
    LOOP
        EXECUTE 'REVOKE ALL ON FUNCTION public.purge_account_deletion_plant_rows_internal(uuid,uuid) FROM '||v_role;
    END LOOP;
END $$;

COMMIT;
