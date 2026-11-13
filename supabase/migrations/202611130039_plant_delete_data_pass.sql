BEGIN;

CREATE FUNCTION public.purge_plant_deletion_data(p_job_id UUID)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
    v_analysis JSONB;
    v_text JSONB;
BEGIN
    v_analysis := public.purge_plant_deletion_analysis_data(p_job_id);
    IF v_analysis IS NULL OR v_analysis->>'state' = 'pending' THEN RETURN v_analysis; END IF;

    v_text := public.purge_plant_deletion_personal_text(p_job_id);
    -- A Storage write may finish between the two checks. Roll back the data
    -- changes and retry the Storage phase when that happens.
    IF v_text->>'state' IS DISTINCT FROM 'cleared' THEN
        RAISE EXCEPTION 'PLANT_STORAGE_PURGE_PENDING' USING ERRCODE = '40001';
    END IF;
    RETURN jsonb_build_object('state','cleared',
        'cleared',(v_analysis->>'cleared')::integer+(v_text->>'cleared')::integer);
END;
$$;

REVOKE ALL ON FUNCTION public.purge_plant_deletion_data(UUID) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.purge_plant_deletion_data(UUID) TO service_role;

COMMIT;
