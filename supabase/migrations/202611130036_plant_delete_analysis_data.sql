BEGIN;

-- Keep jobs for the quota ledger and for locating photos during later Storage sweeps.
CREATE FUNCTION public.purge_plant_deletion_analysis_data(p_job_id UUID)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
    v_owner UUID;
    v_plant UUID;
    v_state TEXT;
    v_plan JSONB;
    v_jobs UUID[];
    v_updated INTEGER;
BEGIN
    SELECT owner_id INTO v_owner FROM public.deletion_jobs
    WHERE id=p_job_id AND scope='plant';
    IF NOT FOUND THEN RETURN NULL; END IF;

    -- Use the same owner lock as admission and worker settlement.
    PERFORM 1 FROM public.profiles WHERE id=v_owner FOR UPDATE;
    IF NOT FOUND THEN RETURN NULL; END IF;
    SELECT d.target_id,d.state INTO v_plant,v_state
    FROM public.deletion_jobs d
    JOIN public.plants p ON p.id=d.target_id AND p.owner_id=d.owner_id
    WHERE d.id=p_job_id AND d.scope='plant' AND d.owner_id=v_owner AND p.deleted_at IS NOT NULL
    FOR UPDATE OF d;
    IF NOT FOUND THEN RETURN NULL; END IF;
    IF v_state <> 'purge_data' THEN
        RETURN jsonb_build_object('state','pending','cleared',0);
    END IF;

    v_plan := public.read_plant_deletion_storage(p_job_id);
    IF v_plan IS NULL OR v_plan->'photo_ids' <> '[]'::jsonb
        OR v_plan->>'blocked' <> '0' OR v_plan->>'waiting' <> '0' THEN
        RETURN jsonb_build_object('state','pending','cleared',0);
    END IF;

    SELECT array_agg(j.id ORDER BY j.id) INTO v_jobs
    FROM public.analysis_jobs j
    JOIN public.diagnosis_job_runtime r ON r.job_id=j.id
    WHERE j.owner_id=v_owner
      AND (j.plant_id=v_plant OR (
          -- A saved standalone identification has no plant_id on its job.
          j.plant_id IS NULL AND j.draft_id IS NULL AND j.mode='identification'
          AND cardinality(j.photo_ids)=1 AND EXISTS (
              SELECT 1 FROM public.photo_assets a
              WHERE a.id=j.photo_ids[1] AND a.owner_id=v_owner AND a.plant_id=v_plant
          )
      ));

    IF EXISTS (SELECT 1 FROM public.analysis_jobs
        WHERE id=ANY(v_jobs) AND state NOT IN ('succeeded','failed','timed_out')) THEN
        RETURN jsonb_build_object('state','pending','cleared',0);
    END IF;

    UPDATE public.diagnosis_job_runtime SET projection=NULL,repeat_context=NULL
    WHERE job_id=ANY(v_jobs) AND (projection IS NOT NULL OR repeat_context IS NOT NULL);
    GET DIAGNOSTICS v_updated = ROW_COUNT;
    RETURN jsonb_build_object('state','cleared','cleared',v_updated);
END;
$$;

REVOKE ALL ON FUNCTION public.purge_plant_deletion_analysis_data(UUID) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.purge_plant_deletion_analysis_data(UUID) TO service_role;

COMMIT;
