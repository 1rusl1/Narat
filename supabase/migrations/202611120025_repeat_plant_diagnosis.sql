BEGIN;

ALTER TABLE public.diagnosis_job_runtime ADD COLUMN repeat_context JSONB;

CREATE OR REPLACE FUNCTION public.diagnosis_job_payload(p_job_id UUID)
RETURNS JSONB LANGUAGE sql STABLE SET search_path = '' AS $$
    SELECT jsonb_build_object(
        'job_id', j.id, 'mode', j.mode,
        'status', CASE WHEN j.state = 'timed_out' THEN 'expired' ELSE j.state END,
        'quota_kind', j.quota_kind, 'quota_state', j.quota_state,
        'result', r.projection, 'error_code', j.error_code,
        'error_message', CASE WHEN j.error_code IS NOT NULL THEN
            CASE WHEN j.locale = 'pl' THEN 'Nie udało się ukończyć analizy.'
                 ELSE 'The analysis could not be completed.' END END
    ) || CASE WHEN r.repeat_context IS NOT NULL THEN jsonb_build_object(
        'target_plant_id', r.repeat_context->'target_plant_id', 'photo_asset_id', j.photo_ids[1]
    ) ELSE '{}'::jsonb END
    FROM public.analysis_jobs j JOIN public.diagnosis_job_runtime r ON r.job_id = j.id
    WHERE j.id = p_job_id
$$;

CREATE OR REPLACE FUNCTION public.lease_diagnosis_job(p_job_id UUID)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
    v_owner UUID;
    v_guest BOOLEAN;
    v_job public.analysis_jobs%ROWTYPE;
    v_upload JSONB;
BEGIN
    SELECT owner_id INTO v_owner FROM public.analysis_jobs WHERE id = p_job_id;
    SELECT anonymous INTO v_guest FROM public.profiles
    WHERE id = v_owner AND account_state = 'active' FOR UPDATE;
    IF NOT FOUND THEN RETURN NULL; END IF;
    UPDATE public.analysis_jobs j SET state = 'running', lease_token = gen_random_uuid(), updated_at = clock_timestamp()
    WHERE j.id = p_job_id AND j.owner_id = v_owner AND j.mode IN ('identification', 'diagnosis')
      AND (NOT v_guest OR (j.mode = 'identification' AND j.quota_installation_id IS NOT NULL))
      AND j.state = 'queued' AND j.quota_state = 'reserved' AND j.lease_token IS NULL
      AND j.provider_started_at IS NULL AND j.deadline_at > clock_timestamp()
      AND EXISTS (SELECT 1 FROM public.diagnosis_job_runtime r WHERE r.job_id = j.id)
    RETURNING j.* INTO v_job;
    IF NOT FOUND THEN RETURN NULL; END IF;
    v_upload := public.read_diagnosis_upload(v_job.owner_id, v_job.photo_ids[1]);
    RETURN jsonb_build_object('job_id', v_job.id, 'owner_id', v_job.owner_id, 'lease_token', v_job.lease_token,
        'mode', v_job.mode, 'locale', v_job.locale, 'kb_release_id', v_job.kb_release_id,
        'quota_kind', v_job.quota_kind, 'deadline_at', v_job.deadline_at, 'upload', v_upload,
        'repeat_context', (SELECT repeat_context - 'target_plant_id'
                           FROM public.diagnosis_job_runtime WHERE job_id = v_job.id));
END;
$$;

CREATE FUNCTION public.create_plant_diagnosis_job(
    p_owner_id UUID, p_operation_id UUID, p_photo_asset_id UUID, p_flow_id UUID,
    p_locale TEXT, p_can_dispatch BOOLEAN, p_target_plant_id UUID
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
    v_receipt public.operation_receipts%ROWTYPE;
    v_plant public.plants%ROWTYPE;
    v_snapshot public.condition_snapshots%ROWTYPE;
    v_photo public.photo_assets%ROWTYPE;
    v_now TIMESTAMPTZ;
    v_hash TEXT;
    v_job UUID;
    v_result JSONB;
    v_journal JSONB;
BEGIN
    PERFORM 1 FROM public.profiles
    WHERE id = p_owner_id AND account_state = 'active' AND NOT anonymous FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'ACTIVE_PERMANENT_OWNER_REQUIRED' USING ERRCODE = '42501';
    END IF;
    IF p_operation_id IS NULL OR p_photo_asset_id IS NULL OR p_target_plant_id IS NULL
       OR p_locale IS NULL OR p_locale NOT IN ('en', 'pl') THEN
        RAISE EXCEPTION 'INVALID_JOB_INPUT' USING ERRCODE = '22023';
    END IF;

    v_hash := encode(sha256(convert_to(jsonb_build_array(
        'diagnosis', p_photo_asset_id, p_flow_id, p_locale, p_target_plant_id)::text, 'UTF8')), 'hex');
    SELECT * INTO v_receipt FROM public.operation_receipts
    WHERE owner_id = p_owner_id AND operation_id = p_operation_id;
    IF FOUND THEN
        IF v_receipt.command_name <> 'analysis.job.create' OR v_receipt.payload_hash <> v_hash THEN
            RAISE EXCEPTION 'IDEMPOTENCY_CONFLICT' USING ERRCODE = '23505';
        END IF;
        RETURN jsonb_build_object('replayed', true, 'job', v_receipt.response_payload);
    END IF;

    SELECT * INTO v_plant FROM public.plants
    WHERE id = p_target_plant_id AND owner_id = p_owner_id AND deleted_at IS NULL
    FOR SHARE;
    IF NOT FOUND THEN RAISE EXCEPTION 'PLANT_NOT_FOUND' USING ERRCODE = 'P0002'; END IF;

    SELECT a.* INTO v_photo FROM public.photo_assets a
    JOIN public.diagnosis_upload_tickets t ON t.photo_asset_id = a.id
    WHERE a.id = p_photo_asset_id AND a.owner_id = p_owner_id
      AND a.deleted_at IS NULL AND a.state = 'ready' AND a.uploaded_at IS NOT NULL
    FOR UPDATE OF a;
    IF NOT FOUND THEN RAISE EXCEPTION 'PHOTO_NOT_READY' USING ERRCODE = 'P0002'; END IF;
    IF v_photo.plant_id IS NOT NULL OR v_photo.draft_id IS NOT NULL
       OR EXISTS (SELECT 1 FROM public.plants p WHERE p.owner_id = p_owner_id AND p.main_photo_id = v_photo.id)
       OR EXISTS (
          SELECT 1 FROM public.analysis_jobs j
          LEFT JOIN public.diagnosis_job_runtime r ON r.job_id = j.id
          WHERE j.owner_id = p_owner_id AND v_photo.id = ANY(j.photo_ids)
            AND (r.repeat_context->>'target_plant_id' IS DISTINCT FROM p_target_plant_id::text
                 OR j.state NOT IN ('failed', 'timed_out'))
       ) THEN
        RAISE EXCEPTION 'PHOTO_ALREADY_USED' USING ERRCODE = '23505';
    END IF;

    SELECT * INTO v_snapshot FROM public.condition_snapshots
    WHERE id = v_plant.current_condition_snapshot_id AND plant_id = p_target_plant_id
      AND owner_id = p_owner_id AND deleted_at IS NULL;
    v_now := clock_timestamp();
    SELECT coalesce(jsonb_agg(jsonb_build_object(
        'action_code', entry.action_code, 'occurred_local_date', entry.occurred_local_date
    ) ORDER BY entry.occurred_at DESC, entry.id), '[]'::jsonb) INTO v_journal
    FROM (
        SELECT id, action_code, occurred_at, occurred_local_date FROM public.care_entries
        WHERE plant_id = p_target_plant_id AND owner_id = p_owner_id
          AND deleted_at IS NULL AND state = 'active' AND occurred_at <= v_now
          AND action_code IN ('check_soil', 'inspect_roots', 'inspect_leaves', 'observe',
              'water', 'fertilize', 'repot', 'prune', 'isolate', 'wash_pests', 'treat_pests',
              'adjust_light', 'adjust_humidity', 'check_up')
        ORDER BY occurred_at DESC, id
        LIMIT 12
    ) entry;

    -- The ordinary admission owns release selection, dispatch availability and accounting.
    -- The owner lock keeps this context, job binding and final receipt in the same transaction.
    v_result := public.create_diagnosis_job(
        p_owner_id, p_operation_id, p_photo_asset_id, p_flow_id, p_locale, p_can_dispatch);
    v_job := (v_result->'job'->>'job_id')::uuid;
    UPDATE public.analysis_jobs
    SET plant_id = p_target_plant_id, snapshot_id = v_snapshot.id, payload_hash = v_hash
    WHERE id = v_job;
    UPDATE public.diagnosis_job_runtime SET repeat_context = jsonb_build_object(
        'target_plant_id', p_target_plant_id,
        'light', coalesce(v_snapshot.light_code, 'unknown'),
        'watering_frequency', coalesce(v_snapshot.watering_code, 'unknown'),
        'drainage', CASE WHEN v_snapshot.drainage_code IN ('yes', 'no') THEN v_snapshot.drainage_code ELSE 'unknown' END,
        'care_history', v_journal
    ) WHERE job_id = v_job;

    v_result := public.diagnosis_job_payload(v_job);
    UPDATE public.operation_receipts SET payload_hash = v_hash, response_payload = v_result
    WHERE owner_id = p_owner_id AND operation_id = p_operation_id;
    RETURN jsonb_build_object('replayed', false, 'job', v_result);
END;
$$;

REVOKE ALL ON FUNCTION public.create_plant_diagnosis_job(UUID, UUID, UUID, UUID, TEXT, BOOLEAN, UUID)
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.create_plant_diagnosis_job(UUID, UUID, UUID, UUID, TEXT, BOOLEAN, UUID)
TO service_role;

COMMIT;
