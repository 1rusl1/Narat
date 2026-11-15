BEGIN;

CREATE FUNCTION public.claim_first_aid_photo_cleanup(p_photo_id UUID DEFAULT NULL)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
    v_entries JSONB;
BEGIN
    -- Attach takes the same asset lock. Reserve deletion before handing a key to Storage.
    WITH candidates AS MATERIALIZED (
        SELECT a.id, a.original_key, a.state, t.expires_at
        FROM public.first_aid_photo_upload_tickets t
        JOIN public.photo_assets a ON a.id = t.photo_asset_id
        WHERE (p_photo_id IS NULL OR a.id = p_photo_id)
            AND t.expires_at <= clock_timestamp()
            AND a.purpose = 'diary' AND a.analysis_key IS NULL
            AND a.plant_id IS NULL AND a.draft_id IS NULL
            AND a.original_key = a.owner_id::text || '/' || a.id::text
            AND NOT EXISTS (SELECT 1 FROM public.care_observations o WHERE o.photo_id = a.id)
            AND (
                (a.deleted_at IS NULL AND a.state IN ('initialized', 'ready', 'deleting'))
                -- A PUT already in Storage can finish after the first removal. Sweep its
                -- private object on a later pass without reopening the database asset.
                OR (a.state = 'deleted' AND a.deleted_at IS NOT NULL AND EXISTS (
                    SELECT 1 FROM storage.objects s
                    WHERE s.bucket_id = 'analysis-inputs' AND s.name = a.original_key
                ))
            )
        ORDER BY t.expires_at, a.id
        LIMIT 20
        FOR UPDATE OF a SKIP LOCKED
    ), fenced AS (
        UPDATE public.photo_assets a
        SET state = 'deleting', updated_at = clock_timestamp()
        FROM candidates c
        WHERE a.id = c.id AND c.state IN ('initialized', 'ready')
        RETURNING a.id
    )
    SELECT coalesce(jsonb_agg(jsonb_build_object('photo_id', c.id, 'source', c.original_key)
        ORDER BY c.expires_at, c.id), '[]'::jsonb)
    INTO v_entries
    FROM candidates c LEFT JOIN fenced f ON f.id = c.id
    WHERE f.id IS NOT NULL OR c.state IN ('deleting', 'deleted');
    RETURN v_entries;
END;
$$;

CREATE FUNCTION public.finish_first_aid_photo_cleanup(p_photo_id UUID)
RETURNS VOID LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $$
    UPDATE public.photo_assets a
    SET state = 'deleted', deleted_at = clock_timestamp(), updated_at = clock_timestamp()
    WHERE a.id = p_photo_id AND a.state = 'deleting' AND a.deleted_at IS NULL
        AND a.plant_id IS NULL AND a.draft_id IS NULL AND a.purpose = 'diary' AND a.analysis_key IS NULL
        AND EXISTS (SELECT 1 FROM public.first_aid_photo_upload_tickets t WHERE t.photo_asset_id = a.id)
        AND NOT EXISTS (SELECT 1 FROM public.care_observations o WHERE o.photo_id = a.id)
$$;

REVOKE ALL ON FUNCTION public.claim_first_aid_photo_cleanup(UUID),
    public.finish_first_aid_photo_cleanup(UUID) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.claim_first_aid_photo_cleanup(UUID),
    public.finish_first_aid_photo_cleanup(UUID) TO service_role;

COMMIT;
