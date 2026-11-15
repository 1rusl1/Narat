BEGIN;

CREATE INDEX photo_assets_original_key_idx ON public.photo_assets(original_key);
CREATE INDEX photo_assets_analysis_key_idx ON public.photo_assets(analysis_key) WHERE analysis_key IS NOT NULL;

-- Only ticket-backed photos with proven canonical keys can be removed from analysis-inputs.
-- Keep the plan readable in purge_data so the same job can sweep a late write.
CREATE FUNCTION public.read_plant_deletion_storage(p_job_id UUID)
RETURNS JSONB LANGUAGE sql VOLATILE SECURITY DEFINER SET search_path = '' AS $$
    WITH job AS MATERIALIZED (
        SELECT d.id, d.owner_id, d.target_id, p.main_photo_id
        FROM public.deletion_jobs d
        JOIN public.plants p ON p.id=d.target_id AND p.owner_id=d.owner_id
        WHERE d.id=p_job_id AND d.scope='plant' AND d.state IN ('purge_storage','purge_data')
          AND p.deleted_at IS NOT NULL
    ), photo_ids AS (
        SELECT j.main_photo_id AS id FROM job j WHERE j.main_photo_id IS NOT NULL
        UNION SELECT a.id FROM job j JOIN public.photo_assets a ON a.plant_id=j.target_id
        UNION SELECT unnest(a.photo_ids) FROM job j
            JOIN public.analysis_jobs a ON a.plant_id=j.target_id AND a.owner_id=j.owner_id
        UNION SELECT t.photo_asset_id FROM job j
            JOIN public.first_aid_followups f ON f.plant_id=j.target_id AND f.owner_id=j.owner_id
            JOIN public.first_aid_photo_upload_tickets t ON t.control_id=f.id
        UNION SELECT o.photo_id FROM job j JOIN public.care_observations o
            ON o.plant_id=j.target_id AND o.owner_id=j.owner_id WHERE o.photo_id IS NOT NULL
        UNION SELECT r.source_photo_id FROM job j JOIN public.analysis_results r
            ON r.plant_id=j.target_id AND r.owner_id=j.owner_id
        UNION SELECT c.source_photo_id FROM job j JOIN public.care_plans c
            ON c.plant_id=j.target_id AND c.owner_id=j.owner_id WHERE c.source_photo_id IS NOT NULL
    ), checks AS MATERIALIZED (
        SELECT i.id, a.original_key,
            (a.owner_id IS DISTINCT FROM j.owner_id
                OR a.original_key IS DISTINCT FROM j.owner_id::text || '/' || i.id::text
                OR (a.analysis_key IS NOT NULL AND a.analysis_key IS DISTINCT FROM a.original_key)
                OR (t.photo_asset_id IS NULL AND f.photo_asset_id IS NULL)
                OR a.draft_id IS NOT NULL
                OR (a.plant_id IS NOT NULL AND a.plant_id <> j.target_id AND EXISTS (
                    SELECT 1 FROM public.plants p WHERE p.id=a.plant_id AND p.deleted_at IS NULL))
                OR EXISTS (SELECT 1 FROM public.plants p WHERE p.main_photo_id=i.id
                    AND p.id<>j.target_id AND p.deleted_at IS NULL)
                OR EXISTS (SELECT 1 FROM public.photo_assets other WHERE other.id<>i.id
                    AND (other.original_key=a.original_key OR other.analysis_key=a.original_key))
                OR EXISTS (SELECT 1 FROM public.guest_drafts g
                    WHERE g.photo_id=i.id AND (
                        (g.claimed_at IS NULL AND g.deleted_at IS NULL)
                        OR (g.source_storage_key=a.original_key AND g.storage_cleaned_at IS NULL)))
                OR EXISTS (SELECT 1 FROM public.analysis_jobs x
                    JOIN public.plants p ON p.id=x.plant_id AND p.deleted_at IS NULL
                    WHERE p.id<>j.target_id AND x.photo_ids @> ARRAY[i.id])
                OR EXISTS (SELECT 1 FROM public.analysis_results r
                    JOIN public.plants p ON p.id=r.plant_id AND p.deleted_at IS NULL
                    WHERE p.id<>j.target_id AND r.source_photo_id=i.id AND r.deleted_at IS NULL)
                OR EXISTS (SELECT 1 FROM public.care_plans c
                    JOIN public.plants p ON p.id=c.plant_id AND p.deleted_at IS NULL
                    WHERE p.id<>j.target_id AND c.source_photo_id=i.id AND c.deleted_at IS NULL)
                OR EXISTS (SELECT 1 FROM public.care_observations o
                    JOIN public.plants p ON p.id=o.plant_id AND p.deleted_at IS NULL
                    WHERE p.id<>j.target_id AND o.photo_id=i.id AND o.deleted_at IS NULL)
                OR EXISTS (SELECT 1 FROM public.first_aid_photo_upload_tickets z
                    JOIN public.first_aid_followups x ON x.id=z.control_id AND x.deleted_at IS NULL
                    JOIN public.plants p ON p.id=x.plant_id AND p.deleted_at IS NULL
                    WHERE p.id<>j.target_id AND z.photo_asset_id=i.id)
            ) AS blocked,
            (coalesce(greatest(t.expires_at,f.expires_at)>clock_timestamp(),false)
                OR EXISTS (SELECT 1 FROM public.analysis_jobs x
                    WHERE x.owner_id=j.owner_id AND x.state='running' AND x.provider_started_at IS NOT NULL
                      AND x.photo_ids @> ARRAY[i.id])
            ) AS waiting
        FROM job j CROSS JOIN photo_ids i
        LEFT JOIN public.photo_assets a ON a.id=i.id
        LEFT JOIN public.diagnosis_upload_tickets t ON t.photo_asset_id=i.id
        LEFT JOIN public.first_aid_photo_upload_tickets f ON f.photo_asset_id=i.id
    ), batch AS (
        SELECT c.id FROM checks c
        JOIN storage.objects o ON o.bucket_id='analysis-inputs' AND o.name=c.original_key
        WHERE NOT c.blocked AND NOT c.waiting ORDER BY c.id LIMIT 20
    )
    SELECT jsonb_build_object('owner_id',j.owner_id,
        'photo_ids', coalesce((SELECT jsonb_agg(id ORDER BY id) FROM batch),'[]'::jsonb),
        'blocked', (SELECT count(*) FROM checks WHERE blocked),
        'waiting', (SELECT count(*) FROM checks WHERE NOT blocked AND waiting))
    FROM job j
$$;

CREATE FUNCTION public.finish_plant_deletion_storage(p_job_id UUID)
RETURNS TEXT LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
    v_plan JSONB;
BEGIN
    PERFORM 1 FROM public.deletion_jobs
    WHERE id=p_job_id AND scope='plant' AND state IN ('purge_storage','purge_data') FOR UPDATE;
    IF NOT FOUND THEN RETURN NULL; END IF;
    v_plan := public.read_plant_deletion_storage(p_job_id);
    IF v_plan IS NULL THEN RETURN NULL; END IF;
    IF v_plan->'photo_ids' <> '[]'::jsonb OR v_plan->>'blocked' <> '0' OR v_plan->>'waiting' <> '0' THEN
        UPDATE public.deletion_jobs SET state='purge_storage' WHERE id=p_job_id AND state='purge_data';
        RETURN 'purge_storage';
    END IF;
    UPDATE public.deletion_jobs SET state='purge_data' WHERE id=p_job_id AND state='purge_storage';
    RETURN 'purge_data';
END;
$$;

REVOKE ALL ON FUNCTION public.read_plant_deletion_storage(UUID),
    public.finish_plant_deletion_storage(UUID) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.read_plant_deletion_storage(UUID),
    public.finish_plant_deletion_storage(UUID) TO service_role;

COMMIT;
