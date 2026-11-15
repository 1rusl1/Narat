BEGIN;

-- Internal photo_assets inventory only; not a purge or a completion signal.
-- Installation/draft orphan paths, cleanup and workers remain open (T082/T083).
CREATE FUNCTION public.read_account_deletion_media_inventory(
    p_owner_id UUID, p_after_photo_id UUID DEFAULT NULL
) RETURNS JSONB LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
    WITH owner_request AS MATERIALIZED (
        SELECT q.owner_id
        FROM public.account_deletion_requests q
        JOIN public.profiles p ON p.id=q.owner_id
        JOIN public.operation_receipts r
          ON r.owner_id=q.owner_id AND r.operation_id=q.operation_id
        WHERE q.owner_id=p_owner_id AND NOT p.anonymous AND p.account_state='deleting'
          AND r.command_name='account.delete'
          AND r.payload_hash=encode(sha256(convert_to(
              jsonb_build_array('account.delete','{}'::jsonb)::text,'UTF8')),'hex')
          AND r.committed_at=q.requested_at
          AND r.response_payload=jsonb_build_object('owner_id',q.owner_id,
              'operation_id',q.operation_id,'state','deleting','watermark',q.requested_at)
    ), checks AS MATERIALIZED (
        SELECT a.id, a.original_key,
            (a.original_key IS DISTINCT FROM o.owner_id::text || '/' || a.id::text
                OR (a.analysis_key IS NOT NULL AND a.analysis_key IS DISTINCT FROM a.original_key)
                OR (t.photo_asset_id IS NULL AND f.photo_asset_id IS NULL)
                OR NOT EXISTS (SELECT 1 FROM storage.buckets b
                    WHERE b.id='analysis-inputs' AND NOT b.public)
                OR a.draft_id IS NOT NULL
                OR EXISTS (SELECT 1 FROM public.plants p
                    WHERE (p.id=a.plant_id OR p.main_photo_id=a.id) AND p.owner_id<>o.owner_id)
                OR EXISTS (SELECT 1 FROM public.photo_assets other WHERE other.id<>a.id
                    AND (other.original_key=a.original_key OR other.analysis_key=a.original_key))
                OR EXISTS (SELECT 1 FROM public.guest_drafts g
                    WHERE (g.photo_id=a.id AND g.claimed_at IS NULL AND g.deleted_at IS NULL)
                       OR (g.source_storage_key=a.original_key AND g.storage_cleaned_at IS NULL))
                OR EXISTS (SELECT 1 FROM public.guest_identification_sources s
                    WHERE s.photo_id=a.id AND s.storage_cleaned_at IS NULL)
                OR EXISTS (SELECT 1 FROM public.analysis_jobs j
                    WHERE j.photo_ids @> ARRAY[a.id] AND j.owner_id<>o.owner_id)
                OR EXISTS (SELECT 1 FROM public.analysis_results r
                    WHERE r.source_photo_id=a.id AND r.owner_id<>o.owner_id)
                OR EXISTS (SELECT 1 FROM public.care_plans c
                    WHERE c.source_photo_id=a.id AND c.owner_id<>o.owner_id)
                OR EXISTS (SELECT 1 FROM public.care_observations c
                    WHERE c.photo_id=a.id AND c.owner_id<>o.owner_id)
                OR EXISTS (SELECT 1 FROM public.first_aid_photo_upload_tickets z
                    JOIN public.first_aid_followups c ON c.id=z.control_id
                    WHERE z.photo_asset_id=a.id AND c.owner_id<>o.owner_id)
            ) AS blocked,
            (coalesce(greatest(t.expires_at,f.expires_at)>statement_timestamp(),false)
                -- Do not settle expired jobs here. Unsettled work must remain visible,
                -- including a provider that outlived its deadline.
                OR EXISTS (SELECT 1 FROM public.analysis_jobs j
                    WHERE j.photo_ids @> ARRAY[a.id] AND j.state IN ('queued','running'))
                OR EXISTS (SELECT 1 FROM public.draft_claims c
                    JOIN public.guest_drafts g ON g.id=c.draft_id
                    WHERE (g.photo_id=a.id OR g.source_storage_key=a.original_key)
                      AND (c.state='copying' OR
                          (c.state='prepared' AND c.expires_at>statement_timestamp())))
            ) AS waiting
        FROM owner_request o
        JOIN public.photo_assets a ON a.owner_id=o.owner_id
        LEFT JOIN public.diagnosis_upload_tickets t ON t.photo_asset_id=a.id
        LEFT JOIN public.first_aid_photo_upload_tickets f ON f.photo_asset_id=a.id
        -- Tombstones still participate: a DB flag does not prove Storage cleanup.
    ), batch AS MATERIALIZED (
        SELECT c.id FROM checks c
        WHERE NOT c.blocked AND NOT c.waiting
          AND (p_after_photo_id IS NULL OR c.id>p_after_photo_id)
          AND EXISTS (SELECT 1 FROM storage.objects s
              WHERE s.bucket_id='analysis-inputs' AND s.name=c.original_key)
        ORDER BY c.id LIMIT 20
    )
    SELECT jsonb_build_object('owner_id',o.owner_id,
        'photo_ids',coalesce((SELECT jsonb_agg(id ORDER BY id) FROM batch),'[]'::jsonb),
        'next_cursor',(SELECT id FROM batch ORDER BY id DESC LIMIT 1),
        -- Global counts are deliberately independent of the page cursor.
        -- A photo may have both a hold and an in-flight operation.
        'blocked',(SELECT count(*) FROM checks WHERE blocked),
        'waiting',(SELECT count(*) FROM checks WHERE waiting))
    FROM owner_request o
$$;

REVOKE ALL ON FUNCTION public.read_account_deletion_media_inventory(UUID,UUID)
    FROM PUBLIC, anon, authenticated, service_role;

COMMIT;
