BEGIN;

-- Local forward-only step. Claims and job/draft replay anchors are retained:
-- no claim state currently proves that deleting its proof is replay-safe.
CREATE FUNCTION public.purge_account_deletion_guest_drafts_internal(
    p_owner_id UUID, p_operation_id UUID
) RETURNS BOOLEAN
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
    v_ids UUID[];
    v_edge RECORD;
    v_hold BOOLEAN;
    v_allowed BOOLEAN;
    v_pass INTEGER;
BEGIN
    PERFORM 1 FROM public.profiles WHERE id=p_owner_id FOR UPDATE;
    IF public.verify_account_deletion_storage_internal(p_owner_id,p_operation_id) IS NULL THEN
        RAISE EXCEPTION 'storage verification' USING ERRCODE='P1617';
    END IF;
    -- Verification requires a permanent deleting owner. Both supported producers
    -- (create_guest_photo_draft / create_bound_guest_diagnosis_draft) first lock
    -- this profile and require an active guest, so no eligible insert can race
    -- this empty-set check. Keep 014 cleanup, proof rechecks and replay intact.
    IF NOT EXISTS (SELECT 1 FROM public.guest_drafts WHERE guest_owner_id=p_owner_id) THEN
        IF NOT public.purge_account_deletion_plant_rows_internal(p_owner_id,p_operation_id) THEN
            RAISE EXCEPTION 'plant predecessor (014)' USING ERRCODE='P1617';
        END IF;
        RETURN true;
    END IF;
    -- Nonempty legacy graphs still need semantic writer barriers, including
    -- upgrades without FKs. Preserve their order and reread the set under them.
    LOCK TABLE public.guest_drafts,public.draft_claims,public.analysis_jobs,
        public.condition_snapshots,public.photo_assets,public.analysis_results,
        public.plants IN SHARE ROW EXCLUSIVE MODE;
    SELECT coalesce(array_agg(id ORDER BY id),'{}'::uuid[]) INTO v_ids
        FROM public.guest_drafts WHERE guest_owner_id=p_owner_id;

    -- Legacy non-FK columns are authoritative too. Keep all claims, including
    -- expired/published same-owner claims: their proof can anchor exact replay.
    IF EXISTS (SELECT 1 FROM public.draft_claims WHERE draft_id=ANY(v_ids))
        OR EXISTS (SELECT 1 FROM public.analysis_jobs WHERE draft_id=ANY(v_ids))
        OR EXISTS (SELECT 1 FROM public.guest_drafts
            WHERE id=ANY(v_ids) AND analysis_job_id IS NOT NULL) THEN
        RAISE EXCEPTION 'claim or analysis replay anchor' USING ERRCODE='P1617';
    END IF;
    FOR v_edge IN
        SELECT * FROM (VALUES ('photo_assets'),('condition_snapshots'),('analysis_results')) e(child_table)
    LOOP
        EXECUTE format(
            'SELECT EXISTS (SELECT 1 FROM public.%I
             WHERE draft_id=ANY($1) AND owner_id IS DISTINCT FROM $2)',v_edge.child_table)
            INTO v_hold USING v_ids,p_owner_id;
        IF v_hold THEN
            RAISE EXCEPTION 'foreign semantic child %',v_edge.child_table USING ERRCODE='P1617';
        END IF;
    END LOOP;
    -- Inventory every outgoing FK, not only today's canonical schema.
    FOR v_edge IN
        SELECT f.confrelid::regclass AS parent_table,
            array_agg(a.attname::text ORDER BY k.ord) AS child_keys,
            array_agg(pa.attname::text ORDER BY k.ord) AS parent_keys,
            string_agg(format('c.%I=p.%I',a.attname,pa.attname),' AND ' ORDER BY k.ord) AS join_sql
        FROM pg_constraint f
        CROSS JOIN LATERAL unnest(f.conkey,f.confkey) WITH ORDINALITY k(ck,pk,ord)
        JOIN pg_attribute a ON a.attrelid=f.conrelid AND a.attnum=k.ck
        JOIN pg_attribute pa ON pa.attrelid=f.confrelid AND pa.attnum=k.pk
        WHERE f.contype='f' AND f.conrelid='public.guest_drafts'::regclass
        GROUP BY f.oid,f.confrelid ORDER BY f.oid
    LOOP
        v_allowed := v_edge.parent_keys=ARRAY['id'] AND (
            (v_edge.parent_table='public.profiles'::regclass AND v_edge.child_keys=ARRAY['guest_owner_id']) OR
            (v_edge.parent_table='public.photo_assets'::regclass AND v_edge.child_keys=ARRAY['photo_id']) OR
            (v_edge.parent_table='public.condition_snapshots'::regclass AND v_edge.child_keys=ARRAY['condition_snapshot_id']) OR
            (v_edge.parent_table='public.catalogue_taxa'::regclass AND v_edge.child_keys=ARRAY['confirmed_taxon_id']) OR
            (v_edge.parent_table='public.installation_access'::regclass AND v_edge.child_keys=ARRAY['installation_id']));
        EXECUTE format('SELECT p.ctid FROM public.guest_drafts c JOIN %s p ON %s
            WHERE c.id=ANY($1) FOR UPDATE OF p',v_edge.parent_table,v_edge.join_sql) USING v_ids;
        EXECUTE format('SELECT EXISTS (SELECT 1 FROM public.guest_drafts c JOIN %s p ON %s
            WHERE c.id=ANY($1) AND (NOT $2 OR
                ($3 AND to_jsonb(p)->>''owner_id'' IS DISTINCT FROM $4::text)))',
            v_edge.parent_table,v_edge.join_sql) INTO v_hold USING v_ids,v_allowed,
            v_edge.parent_table IN ('public.photo_assets'::regclass,'public.condition_snapshots'::regclass),p_owner_id;
        IF v_hold THEN
            RAISE EXCEPTION 'unsupported or foreign draft parent' USING ERRCODE='P1617';
        END IF;
    END LOOP;
    -- Validate legacy parent aliases even when the corresponding FK is absent.
    IF EXISTS (SELECT 1 FROM public.guest_drafts g
        LEFT JOIN public.photo_assets a ON a.id=g.photo_id
        LEFT JOIN public.condition_snapshots s ON s.id=g.condition_snapshot_id
        LEFT JOIN public.installation_access i ON i.id=g.installation_id
        WHERE g.id=ANY(v_ids) AND (
            (g.photo_id IS NOT NULL AND a.owner_id IS DISTINCT FROM p_owner_id) OR
            (g.condition_snapshot_id IS NOT NULL AND s.owner_id IS DISTINCT FROM p_owner_id) OR
            (g.installation_id IS NOT NULL AND
                NOT coalesce(p_owner_id=ANY(i.linked_owner_ids),false)))) THEN
        RAISE EXCEPTION 'legacy draft parent ownership' USING ERRCODE='P1617';
    END IF;

    FOR v_pass IN 1..2 LOOP
        IF v_pass=2 AND NOT public.purge_account_deletion_plant_rows_internal(p_owner_id,p_operation_id) THEN
            RAISE EXCEPTION 'plant predecessor (014)' USING ERRCODE='P1617';
        END IF;
        FOR v_edge IN
            SELECT f.conrelid::regclass AS child_table,
                array_agg(a.attname::text ORDER BY k.ord) AS child_keys,
                array_agg(pa.attname::text ORDER BY k.ord) AS parent_keys,
                string_agg(format('c.%I=p.%I',a.attname,pa.attname),' AND ' ORDER BY k.ord) AS join_sql
            FROM pg_constraint f
            CROSS JOIN LATERAL unnest(f.conkey,f.confkey) WITH ORDINALITY k(ck,pk,ord)
            JOIN pg_attribute a ON a.attrelid=f.conrelid AND a.attnum=k.ck
            JOIN pg_attribute pa ON pa.attrelid=f.confrelid AND pa.attnum=k.pk
            WHERE f.contype='f' AND f.confrelid='public.guest_drafts'::regclass
            GROUP BY f.oid,f.conrelid ORDER BY f.conrelid,f.oid
        LOOP
            EXECUTE format('LOCK TABLE %s IN SHARE ROW EXCLUSIVE MODE',v_edge.child_table);
            v_allowed := v_pass=1 AND v_edge.parent_keys=ARRAY['id']
                AND v_edge.child_keys=ARRAY['draft_id'] AND v_edge.child_table IN (
                    'public.photo_assets'::regclass,'public.condition_snapshots'::regclass,
                    'public.analysis_results'::regclass);
            EXECUTE format('SELECT EXISTS (SELECT 1 FROM %s c JOIN public.guest_drafts p ON %s
                WHERE p.id=ANY($1) AND (NOT $2 OR
                    to_jsonb(c)->>''owner_id'' IS DISTINCT FROM $3::text))',
                v_edge.child_table,v_edge.join_sql) INTO v_hold USING v_ids,v_allowed,p_owner_id;
            IF v_hold THEN
                RAISE EXCEPTION 'remaining or unknown draft dependency' USING ERRCODE='P1617';
            END IF;
        END LOOP;
    END LOOP;
    -- No cascade is permitted, including legacy semantic links without FKs.
    IF EXISTS (SELECT 1 FROM public.photo_assets WHERE draft_id=ANY(v_ids))
        OR EXISTS (SELECT 1 FROM public.condition_snapshots WHERE draft_id=ANY(v_ids))
        OR EXISTS (SELECT 1 FROM public.analysis_results WHERE draft_id=ANY(v_ids)) THEN
        RAISE EXCEPTION 'remaining semantic draft dependency' USING ERRCODE='P1617';
    END IF;
    -- plants.origin_draft_id is provenance, not ownership. Leave committed
    -- destination plants intact; an actual FK on that alias fails closed above.
    DELETE FROM public.guest_drafts WHERE guest_owner_id=p_owner_id AND id=ANY(v_ids);
    RETURN true;
EXCEPTION WHEN SQLSTATE 'P1617' THEN
    -- Rolls back verification and every predecessor, including late holds.
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
        WHERE p.oid='public.purge_account_deletion_guest_drafts_internal(uuid,uuid)'::regprocedure
            AND a.grantee<>p.proowner
    LOOP
        EXECUTE 'REVOKE ALL ON FUNCTION public.purge_account_deletion_guest_drafts_internal(uuid,uuid) FROM '||v_role;
    END LOOP;
END $$;

COMMIT;
