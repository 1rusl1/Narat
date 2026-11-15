BEGIN;

CREATE OR REPLACE FUNCTION public.finish_plant_deletion_storage(p_job_id UUID)
RETURNS TEXT LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
    v_owner UUID;
    v_plant UUID;
    v_plan JSONB;
    v_expired UUID;
    v_now TIMESTAMPTZ;
BEGIN
    SELECT owner_id INTO v_owner FROM public.deletion_jobs
    WHERE id=p_job_id AND scope='plant' AND state IN ('purge_storage','purge_data');
    IF NOT FOUND THEN RETURN NULL; END IF;
    PERFORM 1 FROM public.profiles WHERE id=v_owner FOR UPDATE;
    IF NOT FOUND THEN RETURN NULL; END IF;
    SELECT d.target_id INTO v_plant
    FROM public.deletion_jobs d
    JOIN public.plants p ON p.id=d.target_id AND p.owner_id=d.owner_id AND p.deleted_at IS NOT NULL
    WHERE d.id=p_job_id AND d.scope='plant' AND d.owner_id=v_owner
      AND d.state IN ('purge_storage','purge_data')
    FOR UPDATE OF d;
    IF NOT FOUND THEN RETURN NULL; END IF;

    -- A revoked GET no longer recovers its expired lease. Use the existing
    -- timeout settlement under the owner lock before checking Storage again.
    v_now := clock_timestamp();
    FOR v_expired IN
        SELECT j.id FROM public.analysis_jobs j
        JOIN public.diagnosis_job_runtime r ON r.job_id=j.id
        WHERE j.owner_id=v_owner AND j.state IN ('queued','running')
          AND j.deadline_at<=v_now AND j.quota_state='reserved'
          AND (j.plant_id=v_plant OR (
              j.plant_id IS NULL AND j.draft_id IS NULL AND j.mode='identification'
              AND cardinality(j.photo_ids)=1 AND EXISTS (
                  SELECT 1 FROM public.photo_assets a
                  WHERE a.id=j.photo_ids[1] AND a.owner_id=v_owner AND a.plant_id=v_plant
              )
          ))
        ORDER BY j.id
    LOOP
        PERFORM public.finalize_analysis_quota(v_expired,'timed_out',true,v_now);
        UPDATE public.analysis_jobs SET error_code='ANALYSIS_TIMEOUT' WHERE id=v_expired;
    END LOOP;

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

COMMIT;
