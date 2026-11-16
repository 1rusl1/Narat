BEGIN;

-- Shared canonical admission; only the new wrapper supplies guest diagnosis context.
CREATE FUNCTION public._create_bound_photo_analysis_job(
    p_owner_id UUID, p_operation_id UUID, p_photo_asset_id UUID, p_flow_id UUID,
    p_locale TEXT, p_can_dispatch BOOLEAN, p_mode TEXT, p_credential_hash TEXT, p_initial_context JSONB
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
    v_receipt public.operation_receipts%ROWTYPE;
    v_release public.kb_releases%ROWTYPE;
    v_catalogue UUID;
    v_job UUID := gen_random_uuid();
    v_hash TEXT;
    v_quota JSONB;
    v_result JSONB;
    v_expired UUID;
    v_guest BOOLEAN;
    v_installation UUID;
BEGIN
    SELECT anonymous INTO v_guest FROM public.profiles
    WHERE id = p_owner_id AND account_state = 'active' FOR UPDATE;
    IF NOT FOUND OR (v_guest AND (p_credential_hash IS NULL OR (p_mode IS DISTINCT FROM 'identification'
        AND NOT (p_mode = 'diagnosis' AND p_initial_context IS NOT NULL)))) THEN
        RAISE EXCEPTION 'ACTIVE_PERMANENT_OWNER_REQUIRED' USING ERRCODE = '42501';
    END IF;
    IF p_operation_id IS NULL OR p_photo_asset_id IS NULL OR p_locale IS NULL OR p_locale NOT IN ('en', 'pl')
       OR p_mode IS NULL OR p_mode NOT IN ('identification', 'diagnosis') THEN
        RAISE EXCEPTION 'INVALID_JOB_INPUT' USING ERRCODE = '22023';
    END IF;
    IF v_guest THEN
        SELECT i.id INTO v_installation FROM public.installation_access i
        WHERE i.credential_hash=p_credential_hash AND p_owner_id=ANY(i.linked_owner_ids)
        FOR UPDATE;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'INSTALLATION_CREDENTIAL_MISMATCH' USING ERRCODE = '42501';
        END IF;
    END IF;
    IF p_initial_context IS NOT NULL THEN
        IF NOT v_guest OR p_mode IS DISTINCT FROM 'diagnosis' THEN
            RAISE EXCEPTION 'ACTIVE_ANONYMOUS_OWNER_REQUIRED' USING ERRCODE = '42501';
        END IF;
        IF jsonb_typeof(p_initial_context) IS DISTINCT FROM 'object' OR NOT coalesce(
            p_initial_context ?& ARRAY['light', 'watering_frequency', 'drainage']
            AND p_initial_context - ARRAY['light', 'watering_frequency', 'drainage'] = '{}'::jsonb
            AND p_initial_context->>'light' IN ('low', 'medium', 'bright_indirect', 'direct_sun', 'unknown')
            AND p_initial_context->>'watering_frequency' IN ('frequent', 'moderate', 'sparse', 'unknown')
            AND p_initial_context->>'drainage' IN ('yes', 'no', 'unknown'), false) THEN
            RAISE EXCEPTION 'INVALID_INITIAL_CONTEXT' USING ERRCODE = '22023';
        END IF;
        -- Also revalidate and lock the source before returning a stored receipt.
        PERFORM 1 FROM public.photo_assets a
        JOIN public.diagnosis_upload_tickets t ON t.photo_asset_id = a.id
        WHERE a.id = p_photo_asset_id AND a.owner_id = p_owner_id
          AND a.deleted_at IS NULL AND a.state = 'ready' AND a.uploaded_at IS NOT NULL
          AND a.plant_id IS NULL AND a.draft_id IS NULL
          AND NOT public.plant_photo_access_revoked(p_owner_id, a.id)
        FOR UPDATE OF a;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'PHOTO_NOT_READY' USING ERRCODE = 'P0002';
        END IF;
    END IF;
    v_hash := encode(sha256(convert_to(jsonb_build_array(
        p_mode, p_photo_asset_id, p_flow_id, p_locale)::text, 'UTF8')), 'hex');
    IF p_initial_context IS NOT NULL THEN
        v_hash := encode(sha256(convert_to(jsonb_build_array(
            'bound_guest_initial_diagnosis_v1', p_owner_id, v_installation,
            p_mode, p_photo_asset_id, p_flow_id, p_locale, p_initial_context)::text, 'UTF8')), 'hex');
    END IF;
    SELECT * INTO v_receipt FROM public.operation_receipts
    WHERE owner_id = p_owner_id AND operation_id = p_operation_id;
    IF FOUND THEN
        IF v_receipt.command_name <> 'analysis.job.create' OR v_receipt.payload_hash <> v_hash THEN
            RAISE EXCEPTION 'IDEMPOTENCY_CONFLICT' USING ERRCODE = '23505';
        END IF;
        IF v_guest AND NOT EXISTS (
            SELECT 1 FROM public.analysis_jobs j
            WHERE j.id=(v_receipt.response_payload->>'job_id')::uuid
              AND j.quota_installation_id=v_installation
        ) THEN
            RAISE EXCEPTION 'INSTALLATION_CREDENTIAL_MISMATCH' USING ERRCODE = '42501';
        END IF;
        IF p_initial_context IS NOT NULL AND NOT EXISTS (
            SELECT 1 FROM public.analysis_jobs j
            JOIN public.diagnosis_job_runtime r ON r.job_id = j.id
            WHERE j.id = (v_receipt.response_payload->>'job_id')::uuid
              AND j.owner_id = p_owner_id AND j.operation_id = p_operation_id
              AND j.payload_hash = v_hash AND j.mode = 'diagnosis'
              AND j.quota_kind = 'starter_diagnosis' AND j.quota_owner_id = p_owner_id
              AND j.quota_installation_id = v_installation AND j.plant_id IS NULL
              AND j.photo_ids = ARRAY[p_photo_asset_id]
              AND r.initial_context = p_initial_context AND r.repeat_context IS NULL
        ) THEN
            RAISE EXCEPTION 'IDEMPOTENCY_CONFLICT' USING ERRCODE = '23505';
        END IF;
        IF public.plant_photo_access_revoked(p_owner_id,p_photo_asset_id) THEN
            RAISE EXCEPTION 'PHOTO_NOT_READY' USING ERRCODE = 'P0002';
        END IF;
        RETURN jsonb_build_object('replayed', true, 'job', v_receipt.response_payload);
    END IF;
    IF EXISTS (SELECT 1 FROM public.analysis_jobs WHERE owner_id = p_owner_id AND operation_id = p_operation_id) THEN
        RAISE EXCEPTION 'IDEMPOTENCY_CONFLICT' USING ERRCODE = '23505';
    END IF;
    PERFORM 1 FROM public.photo_assets a
    JOIN public.diagnosis_upload_tickets t ON t.photo_asset_id = a.id
    WHERE a.id = p_photo_asset_id AND a.owner_id = p_owner_id
      AND a.deleted_at IS NULL AND a.state = 'ready' AND a.uploaded_at IS NOT NULL
      AND NOT public.plant_photo_access_revoked(p_owner_id,a.id)
      AND (NOT v_guest OR (a.draft_id IS NULL AND NOT EXISTS (
        SELECT 1 FROM public.guest_identification_sources gs
        WHERE gs.photo_id=a.id AND gs.expires_at<=clock_timestamp()
      )))
    FOR UPDATE OF a;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PHOTO_NOT_READY' USING ERRCODE = 'P0002';
    END IF;
    IF p_can_dispatch IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'PROVIDER_UNAVAILABLE';
    END IF;
    IF p_mode = 'diagnosis' THEN
        SELECT * INTO v_release FROM public.kb_releases WHERE state = 'published';
    END IF;
    SELECT id INTO v_catalogue FROM public.catalogue_releases WHERE state = 'published';
    IF (p_mode = 'diagnosis' AND v_release.id IS NULL) OR v_catalogue IS NULL OR NOT EXISTS (
        SELECT 1 FROM public.catalogue_release_species
        WHERE release_id = v_catalogue AND status = 'published'
          AND (p_mode = 'diagnosis' OR rank IN ('species', 'hybrid'))
    ) THEN
        RAISE EXCEPTION 'PUBLISHED_RELEASE_UNAVAILABLE';
    END IF;
    -- Recover abandoned jobs for this owner even when the client stopped polling.
    FOR v_expired IN
        SELECT j.id FROM public.analysis_jobs j JOIN public.diagnosis_job_runtime r ON r.job_id = j.id
        WHERE j.owner_id = p_owner_id AND j.state IN ('queued','running')
          AND (NOT v_guest OR j.quota_installation_id=v_installation)
          AND j.deadline_at <= clock_timestamp()
        ORDER BY j.id
    LOOP
        PERFORM public.finalize_analysis_quota(v_expired, 'timed_out', true, clock_timestamp());
        UPDATE public.analysis_jobs SET error_code = 'ANALYSIS_TIMEOUT' WHERE id = v_expired;
    END LOOP;
    INSERT INTO public.analysis_jobs(id, owner_id, flow_id, intent, add_method, mode, kb_release_id,
        prompt_version, operation_id, payload_hash, locale, photo_ids, quota_kind, quota_state)
    VALUES(v_job, p_owner_id, coalesce(p_flow_id, p_operation_id), CASE WHEN p_mode = 'identification' THEN 'care' ELSE 'problem' END, 'scan', p_mode, v_release.id,
        coalesce(v_release.prompt_version, 'identification-v1'), p_operation_id, v_hash, p_locale, ARRAY[p_photo_asset_id], 'none', 'not_applicable');
    v_quota := public.admit_analysis_quota(p_mode, p_owner_id, v_installation, v_job, clock_timestamp());
    IF v_quota->>'admitted' IS DISTINCT FROM 'true' THEN
        RAISE EXCEPTION 'QUOTA_DENIED' USING DETAIL = coalesce(v_quota->>'reason', 'quota_unavailable');
    END IF;
    INSERT INTO public.diagnosis_job_runtime(job_id, catalogue_release_id, initial_context)
    VALUES(v_job, v_catalogue, p_initial_context);
    v_result := public.diagnosis_job_payload(v_job);
    INSERT INTO public.operation_receipts(owner_id, operation_id, command_name, payload_hash, response_payload)
    VALUES(p_owner_id, p_operation_id, 'analysis.job.create', v_hash, v_result);
    RETURN jsonb_build_object('replayed', false, 'job', v_result);
END;
$$;

REVOKE ALL ON FUNCTION public._create_bound_photo_analysis_job(UUID,UUID,UUID,UUID,TEXT,BOOLEAN,TEXT,TEXT,JSONB)
FROM PUBLIC, anon, authenticated, service_role;

-- Existing callers retain their signatures and the original admission policy.
CREATE OR REPLACE FUNCTION public.create_bound_photo_analysis_job(
    p_owner_id UUID, p_operation_id UUID, p_photo_asset_id UUID, p_flow_id UUID,
    p_locale TEXT, p_can_dispatch BOOLEAN, p_mode TEXT, p_credential_hash TEXT
) RETURNS JSONB LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $$
    SELECT public._create_bound_photo_analysis_job(
        p_owner_id, p_operation_id, p_photo_asset_id, p_flow_id,
        p_locale, p_can_dispatch, p_mode, p_credential_hash, NULL)
$$;

CREATE FUNCTION public.create_bound_guest_initial_diagnosis_job(
    p_owner_id UUID, p_operation_id UUID, p_photo_asset_id UUID, p_flow_id UUID,
    p_locale TEXT, p_can_dispatch BOOLEAN, p_initial_context JSONB, p_credential_hash TEXT
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
    PERFORM 1 FROM public.profiles
    WHERE id = p_owner_id AND account_state = 'active' AND anonymous FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'ACTIVE_ANONYMOUS_OWNER_REQUIRED' USING ERRCODE = '42501';
    END IF;
    IF p_initial_context IS NULL THEN
        RAISE EXCEPTION 'INVALID_INITIAL_CONTEXT' USING ERRCODE = '22023';
    END IF;
    RETURN public._create_bound_photo_analysis_job(
        p_owner_id, p_operation_id, p_photo_asset_id, p_flow_id,
        p_locale, p_can_dispatch, 'diagnosis', p_credential_hash, p_initial_context);
END;
$$;

CREATE FUNCTION public.read_bound_guest_initial_diagnosis_job(
    p_owner_id UUID, p_job_id UUID, p_credential_hash TEXT
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
    v_installation UUID;
    v_job public.analysis_jobs%ROWTYPE;
    v_photo UUID;
BEGIN
    PERFORM 1 FROM public.profiles
    WHERE id = p_owner_id AND account_state = 'active' AND anonymous FOR UPDATE;
    IF NOT FOUND THEN RETURN NULL; END IF;
    SELECT id INTO v_installation FROM public.installation_access
    WHERE credential_hash = p_credential_hash AND p_owner_id = ANY(linked_owner_ids)
    FOR UPDATE;
    IF NOT FOUND THEN RETURN NULL; END IF;
    SELECT j.photo_ids[1] INTO v_photo
    FROM public.analysis_jobs j
    JOIN public.diagnosis_job_runtime r ON r.job_id = j.id
    JOIN public.operation_receipts o ON o.owner_id = j.owner_id AND o.operation_id = j.operation_id
    WHERE j.id = p_job_id AND j.owner_id = p_owner_id
      AND j.mode = 'diagnosis' AND j.plant_id IS NULL AND j.draft_id IS NULL
      AND cardinality(j.photo_ids) = 1 AND j.quota_kind = 'starter_diagnosis'
      AND j.quota_owner_id = p_owner_id AND j.quota_installation_id = v_installation
      AND r.initial_context IS NOT NULL AND r.repeat_context IS NULL
      AND o.command_name = 'analysis.job.create' AND o.payload_hash = j.payload_hash
      AND o.response_payload->>'job_id' = j.id::text;
    IF NOT FOUND THEN RETURN NULL; END IF;
    -- Match admission's profile -> installation -> photo order before settlement.
    PERFORM 1 FROM public.photo_assets a
    JOIN public.diagnosis_upload_tickets t ON t.photo_asset_id = a.id
    WHERE a.id = v_photo AND a.owner_id = p_owner_id
      AND a.state = 'ready' AND a.uploaded_at IS NOT NULL AND a.deleted_at IS NULL
      AND a.plant_id IS NULL AND a.draft_id IS NULL
      AND NOT public.plant_photo_access_revoked(p_owner_id, a.id)
    FOR UPDATE OF a;
    IF NOT FOUND THEN RETURN NULL; END IF;
    SELECT * INTO v_job FROM public.analysis_jobs WHERE id = p_job_id FOR UPDATE;
    IF v_job.state IN ('queued', 'running') AND v_job.deadline_at <= clock_timestamp() THEN
        PERFORM public.finalize_analysis_quota(v_job.id, 'timed_out', true, clock_timestamp());
        UPDATE public.analysis_jobs SET error_code = 'ANALYSIS_TIMEOUT' WHERE id = v_job.id;
    END IF;
    RETURN public.diagnosis_job_payload(v_job.id);
END;
$$;

REVOKE ALL ON FUNCTION public.create_bound_guest_initial_diagnosis_job(UUID,UUID,UUID,UUID,TEXT,BOOLEAN,JSONB,TEXT),
    public.read_bound_guest_initial_diagnosis_job(UUID,UUID,TEXT)
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.create_bound_guest_initial_diagnosis_job(UUID,UUID,UUID,UUID,TEXT,BOOLEAN,JSONB,TEXT),
    public.read_bound_guest_initial_diagnosis_job(UUID,UUID,TEXT)
TO service_role;

COMMIT;
