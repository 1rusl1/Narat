BEGIN;

-- Aggregate holds only. Cleanup and product account deletion remain open (T082/T083).
CREATE FUNCTION public.read_account_deletion_namespace_holds(p_owner_id UUID)
RETURNS JSONB LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
    WITH owner_request AS MATERIALIZED (
        -- Reuse 061's exact persisted 060 request/receipt validation.
        SELECT p_owner_id AS owner_id
        WHERE public.read_account_deletion_media_inventory(p_owner_id) IS NOT NULL
    )
    SELECT jsonb_build_object(
        'orphan_objects',(
            SELECT count(*) FROM storage.objects s
            WHERE s.bucket_id='analysis-inputs'
              AND EXISTS (SELECT 1 FROM storage.buckets b
                  WHERE b.id=s.bucket_id AND NOT b.public)
              AND left(s.name,length(o.owner_id::text)+1)=o.owner_id::text || '/'
              AND NOT EXISTS (SELECT 1 FROM public.photo_assets a
                  WHERE a.owner_id=o.owner_id
                    AND a.original_key=o.owner_id::text || '/' || a.id::text
                    AND a.original_key=s.name)),
        'guest_draft_sources',(
            SELECT count(*) FROM public.guest_drafts g
            WHERE g.guest_owner_id=o.owner_id AND g.storage_cleaned_at IS NULL
              AND (g.photo_id IS NOT NULL OR g.source_storage_key IS NOT NULL)),
        'guest_identification_sources',(
            SELECT count(*) FROM public.guest_identification_sources g
            JOIN public.photo_assets a ON a.id=g.photo_id
            WHERE a.owner_id=o.owner_id AND g.storage_cleaned_at IS NULL),
        'incoming_claims',(
            SELECT count(*) FROM public.draft_claims c
            JOIN public.guest_drafts g ON g.id=c.draft_id
            WHERE c.target_owner_id=o.owner_id AND g.storage_cleaned_at IS NULL
              AND (c.state='copying'
                  OR (c.state='prepared' AND c.expires_at>statement_timestamp()))))
    FROM owner_request o
    -- Expiry, tombstones and publication do not prove source cleanup. Copying
    -- holds survive expiry until cleanup is confirmed, even without an object.
$$;

REVOKE ALL ON FUNCTION public.read_account_deletion_namespace_holds(UUID)
    FROM PUBLIC, anon, authenticated, service_role;

COMMIT;
