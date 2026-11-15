BEGIN;

-- Internal read-only work plan. T082/T083 still require worker, data and Auth work.
-- Always start at the first page: retries must retain surviving Storage objects.
CREATE FUNCTION public.read_account_deletion_storage_work_plan(p_owner_id UUID)
RETURNS JSONB LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
    WITH media AS MATERIALIZED (
        SELECT public.read_account_deletion_media_inventory(p_owner_id) AS body
    ), holds AS MATERIALIZED (
        SELECT public.read_account_deletion_namespace_holds(p_owner_id) AS body
    )
    SELECT (m.body - 'next_cursor') || h.body || jsonb_build_object(
        'storage_ready',
            EXISTS (SELECT 1 FROM storage.buckets b
                WHERE b.id='analysis-inputs' AND NOT b.public)
            AND m.body->'photo_ids'='[]'::jsonb
            AND (m.body->>'blocked')::bigint=0
            AND (m.body->>'waiting')::bigint=0
            AND (h.body->>'orphan_objects')::bigint=0
            AND (h.body->>'guest_draft_sources')::bigint=0
            AND (h.body->>'guest_identification_sources')::bigint=0
            AND (h.body->>'incoming_claims')::bigint=0)
    FROM media m CROSS JOIN holds h
    WHERE m.body IS NOT NULL AND h.body IS NOT NULL
$$;

-- Remove default ACL grants as well as the standard API roles: owner only.
DO $$
DECLARE v_role text;
BEGIN
    FOR v_role IN
        SELECT DISTINCT CASE WHEN a.grantee=0 THEN 'PUBLIC' ELSE quote_ident(r.rolname) END
        FROM pg_proc p
        CROSS JOIN LATERAL aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) a
        LEFT JOIN pg_roles r ON r.oid=a.grantee
        WHERE p.oid='public.read_account_deletion_storage_work_plan(uuid)'::regprocedure
          AND a.grantee<>p.proowner
    LOOP
        EXECUTE 'REVOKE ALL ON FUNCTION public.read_account_deletion_storage_work_plan(uuid) FROM '||v_role;
    END LOOP;
END $$;
COMMIT;
