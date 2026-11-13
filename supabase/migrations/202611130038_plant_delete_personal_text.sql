BEGIN;

ALTER TABLE public.plants DROP CONSTRAINT plants_name_present_chk;
ALTER TABLE public.plants ADD CONSTRAINT plants_name_present_chk
    CHECK (deleted_at IS NOT NULL OR coalesce(personal_name,display_name) IS NOT NULL);

CREATE FUNCTION public.purge_plant_deletion_personal_text(p_job_id UUID)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
    v_owner UUID;
    v_plant UUID;
    v_state TEXT;
    v_plan JSONB;
    v_plant_count INTEGER;
    v_note_count INTEGER;
BEGIN
    SELECT owner_id INTO v_owner FROM public.deletion_jobs
    WHERE id=p_job_id AND scope='plant';
    IF NOT FOUND THEN RETURN NULL; END IF;
    PERFORM 1 FROM public.profiles WHERE id=v_owner FOR UPDATE;
    IF NOT FOUND THEN RETURN NULL; END IF;
    SELECT d.target_id,d.state INTO v_plant,v_state
    FROM public.deletion_jobs d
    JOIN public.plants p ON p.id=d.target_id AND p.owner_id=d.owner_id AND p.deleted_at IS NOT NULL
    WHERE d.id=p_job_id AND d.scope='plant' AND d.owner_id=v_owner
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

    -- The tombstone carries the same ID and watermark. Keep relationships for
    -- idempotency and later Storage passes.
    UPDATE public.plants SET personal_name=NULL,display_name=NULL,cultivar_label=NULL
    WHERE id=v_plant AND owner_id=v_owner AND deleted_at IS NOT NULL
      AND coalesce(personal_name,display_name,cultivar_label) IS NOT NULL;
    GET DIAGNOSTICS v_plant_count = ROW_COUNT;
    UPDATE public.care_observations SET note=NULL
    WHERE plant_id=v_plant AND owner_id=v_owner AND deleted_at IS NOT NULL AND note IS NOT NULL;
    GET DIAGNOSTICS v_note_count = ROW_COUNT;
    RETURN jsonb_build_object('state','cleared','cleared',v_plant_count+v_note_count);
END;
$$;

REVOKE ALL ON FUNCTION public.purge_plant_deletion_personal_text(UUID) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.purge_plant_deletion_personal_text(UUID) TO service_role;

COMMIT;
