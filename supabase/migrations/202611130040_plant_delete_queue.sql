BEGIN;

CREATE INDEX deletion_jobs_plant_purge_cursor_idx ON public.deletion_jobs(id)
WHERE scope='plant' AND state IN ('purge_storage','purge_data');

CREATE FUNCTION public.list_plant_deletion_jobs(p_after UUID DEFAULT NULL)
RETURNS JSONB LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
    SELECT coalesce(jsonb_agg(id ORDER BY id),'[]'::jsonb)
    FROM (
        SELECT d.id FROM public.deletion_jobs d
        JOIN public.plants p ON p.id=d.target_id AND p.owner_id=d.owner_id AND p.deleted_at IS NOT NULL
        WHERE d.scope='plant' AND d.state IN ('purge_storage','purge_data')
          AND (p_after IS NULL OR d.id>p_after)
        ORDER BY d.id LIMIT 10
    ) AS batch
$$;

REVOKE ALL ON FUNCTION public.list_plant_deletion_jobs(UUID) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.list_plant_deletion_jobs(UUID) TO service_role;

COMMIT;
