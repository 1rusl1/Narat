BEGIN;

-- Provisional photo-only results are independent of a saved plant or guest draft.
CREATE TABLE public.diagnosis_job_runtime (
    job_id UUID PRIMARY KEY REFERENCES public.analysis_jobs(id) ON DELETE CASCADE,
    catalogue_release_id UUID NOT NULL REFERENCES public.catalogue_releases(id),
    projection JSONB
);
ALTER TABLE public.diagnosis_job_runtime ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.diagnosis_job_runtime FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION public.diagnosis_job_payload(p_job_id UUID)
RETURNS JSONB LANGUAGE sql STABLE SET search_path = '' AS $$
    SELECT jsonb_build_object(
        'job_id', j.id, 'mode', j.mode,
        'status', CASE WHEN j.state = 'timed_out' THEN 'expired' ELSE j.state END,
        'quota_kind', j.quota_kind, 'quota_state', j.quota_state,
        'result', r.projection, 'error_code', j.error_code,
        'error_message', CASE WHEN j.error_code IS NOT NULL THEN
            CASE WHEN j.locale = 'pl' THEN 'Nie udało się ukończyć analizy.'
                 ELSE 'The analysis could not be completed.' END END
    )
    FROM public.analysis_jobs j JOIN public.diagnosis_job_runtime r ON r.job_id = j.id
    WHERE j.id = p_job_id
$$;

CREATE FUNCTION public.create_diagnosis_job(
    p_owner_id UUID, p_operation_id UUID, p_photo_asset_id UUID, p_flow_id UUID,
    p_locale TEXT, p_can_dispatch BOOLEAN
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
BEGIN
    PERFORM 1 FROM public.profiles
    WHERE id = p_owner_id AND account_state = 'active' AND NOT anonymous FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'ACTIVE_PERMANENT_OWNER_REQUIRED' USING ERRCODE = '42501';
    END IF;
    IF p_operation_id IS NULL OR p_photo_asset_id IS NULL OR p_locale IS NULL OR p_locale NOT IN ('en', 'pl') THEN
        RAISE EXCEPTION 'INVALID_JOB_INPUT' USING ERRCODE = '22023';
    END IF;
    v_hash := encode(sha256(convert_to(jsonb_build_array(
        'diagnosis', p_photo_asset_id, p_flow_id, p_locale)::text, 'UTF8')), 'hex');
    SELECT * INTO v_receipt FROM public.operation_receipts
    WHERE owner_id = p_owner_id AND operation_id = p_operation_id;
    IF FOUND THEN
        IF v_receipt.command_name <> 'analysis.job.create' OR v_receipt.payload_hash <> v_hash THEN
            RAISE EXCEPTION 'IDEMPOTENCY_CONFLICT' USING ERRCODE = '23505';
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
    FOR UPDATE OF a;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PHOTO_NOT_READY' USING ERRCODE = 'P0002';
    END IF;
    IF p_can_dispatch IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'PROVIDER_UNAVAILABLE';
    END IF;
    SELECT * INTO v_release FROM public.kb_releases WHERE state = 'published';
    SELECT id INTO v_catalogue FROM public.catalogue_releases WHERE state = 'published';
    IF v_release.id IS NULL OR v_catalogue IS NULL OR NOT EXISTS (
        SELECT 1 FROM public.catalogue_release_species WHERE release_id = v_catalogue AND status = 'published'
    ) THEN
        RAISE EXCEPTION 'PUBLISHED_RELEASE_UNAVAILABLE';
    END IF;
    -- Recover abandoned jobs for this owner even when the client stopped polling.
    FOR v_expired IN
        SELECT j.id FROM public.analysis_jobs j JOIN public.diagnosis_job_runtime r ON r.job_id = j.id
        WHERE j.owner_id = p_owner_id AND j.state IN ('queued','running')
          AND j.deadline_at <= clock_timestamp()
        ORDER BY j.id
    LOOP
        PERFORM public.finalize_analysis_quota(v_expired, 'timed_out', true, clock_timestamp());
        UPDATE public.analysis_jobs SET error_code = 'ANALYSIS_TIMEOUT' WHERE id = v_expired;
    END LOOP;
    INSERT INTO public.analysis_jobs(id, owner_id, flow_id, intent, add_method, mode, kb_release_id,
        prompt_version, operation_id, payload_hash, locale, photo_ids, quota_kind, quota_state)
    VALUES(v_job, p_owner_id, coalesce(p_flow_id, p_operation_id), 'problem', 'scan', 'diagnosis', v_release.id,
        v_release.prompt_version, p_operation_id, v_hash, p_locale, ARRAY[p_photo_asset_id], 'none', 'not_applicable');
    v_quota := public.admit_analysis_quota('diagnosis', p_owner_id, NULL, v_job, clock_timestamp());
    IF v_quota->>'admitted' IS DISTINCT FROM 'true' THEN
        RAISE EXCEPTION 'QUOTA_DENIED' USING DETAIL = coalesce(v_quota->>'reason', 'quota_unavailable');
    END IF;
    INSERT INTO public.diagnosis_job_runtime(job_id, catalogue_release_id) VALUES(v_job, v_catalogue);
    v_result := public.diagnosis_job_payload(v_job);
    INSERT INTO public.operation_receipts(owner_id, operation_id, command_name, payload_hash, response_payload)
    VALUES(p_owner_id, p_operation_id, 'analysis.job.create', v_hash, v_result);
    RETURN jsonb_build_object('replayed', false, 'job', v_result);
END;
$$;

CREATE FUNCTION public.read_diagnosis_job(p_owner_id UUID, p_job_id UUID)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_job public.analysis_jobs%ROWTYPE;
BEGIN
    PERFORM 1 FROM public.profiles WHERE id = p_owner_id AND account_state = 'active' AND NOT anonymous FOR UPDATE;
    IF NOT FOUND THEN RETURN NULL; END IF;
    SELECT j.* INTO v_job FROM public.analysis_jobs j
    JOIN public.diagnosis_job_runtime r ON r.job_id = j.id
    WHERE j.owner_id = p_owner_id AND j.id = p_job_id FOR UPDATE OF j;
    IF NOT FOUND THEN RETURN NULL; END IF;
    IF v_job.state IN ('queued','running') AND v_job.deadline_at <= clock_timestamp() THEN
        PERFORM public.finalize_analysis_quota(v_job.id, 'timed_out', true, clock_timestamp());
        UPDATE public.analysis_jobs SET error_code = 'ANALYSIS_TIMEOUT' WHERE id = v_job.id;
    END IF;
    RETURN public.diagnosis_job_payload(v_job.id);
END;
$$;

CREATE FUNCTION public.lease_diagnosis_job(p_job_id UUID)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
    v_owner UUID;
    v_job public.analysis_jobs%ROWTYPE;
    v_upload JSONB;
BEGIN
    SELECT owner_id INTO v_owner FROM public.analysis_jobs WHERE id = p_job_id;
    PERFORM 1 FROM public.profiles WHERE id = v_owner AND account_state = 'active' AND NOT anonymous FOR UPDATE;
    IF NOT FOUND THEN RETURN NULL; END IF;
    UPDATE public.analysis_jobs j SET state = 'running', lease_token = gen_random_uuid(), updated_at = clock_timestamp()
    WHERE j.id = p_job_id AND j.owner_id = v_owner AND j.mode = 'diagnosis'
      AND j.state = 'queued' AND j.quota_state = 'reserved' AND j.lease_token IS NULL
      AND j.provider_started_at IS NULL AND j.deadline_at > clock_timestamp()
      AND EXISTS (SELECT 1 FROM public.diagnosis_job_runtime r WHERE r.job_id = j.id)
    RETURNING j.* INTO v_job;
    IF NOT FOUND THEN RETURN NULL; END IF;
    v_upload := public.read_diagnosis_upload(v_job.owner_id, v_job.photo_ids[1]);
    RETURN jsonb_build_object('job_id', v_job.id, 'owner_id', v_job.owner_id, 'lease_token', v_job.lease_token,
        'mode', v_job.mode, 'locale', v_job.locale, 'kb_release_id', v_job.kb_release_id,
        'quota_kind', v_job.quota_kind, 'deadline_at', v_job.deadline_at, 'upload', v_upload);
END;
$$;

CREATE FUNCTION public.read_diagnosis_catalog(p_job_id UUID, p_lease_token UUID)
RETURNS JSONB LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $$
    SELECT jsonb_build_object('kb_release_id', j.kb_release_id,
        'plants', coalesce((SELECT jsonb_agg(jsonb_build_object(
            'plant_id', s.plant_id, 'genus', s.genus, 'scientific_name', s.accepted_scientific_name,
            'display_name', coalesce(nullif(s.common_names->j.locale->0->>'name',''),s.accepted_scientific_name)
        ) ORDER BY s.plant_id) FROM public.catalogue_release_species s
            WHERE s.release_id = r.catalogue_release_id AND s.status = 'published'), '[]'::jsonb),
        'conditions', coalesce((SELECT jsonb_agg(c.protocol ORDER BY c.condition_id)
            FROM public.condition_profiles c WHERE c.kb_release_id = j.kb_release_id AND c.state = 'published'), '[]'::jsonb))
    FROM public.analysis_jobs j JOIN public.diagnosis_job_runtime r ON r.job_id = j.id
    WHERE j.id = p_job_id AND j.lease_token = p_lease_token AND j.state = 'running'
      AND j.deadline_at > clock_timestamp()
$$;

-- Charge one conservative $0.05 reservation at start. An ambiguous provider outcome
-- still consumes the call allowance. The existing count cap can be configured lower.
CREATE FUNCTION public.start_diagnosis_provider(p_job_id UUID, p_lease_token UUID)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
    v_day DATE := (clock_timestamp() AT TIME ZONE 'UTC')::date;
    v_owner UUID;
    v_job public.analysis_jobs%ROWTYPE;
    v_count INTEGER;
BEGIN
    SELECT owner_id INTO v_owner FROM public.analysis_jobs WHERE id = p_job_id;
    PERFORM 1 FROM public.profiles WHERE id = v_owner AND account_state = 'active' AND NOT anonymous FOR UPDATE;
    IF NOT FOUND THEN RETURN jsonb_build_object('allowed', false); END IF;
    SELECT * INTO v_job FROM public.analysis_jobs WHERE id = p_job_id AND owner_id = v_owner FOR UPDATE;
    IF NOT FOUND OR p_lease_token IS NULL OR v_job.lease_token IS DISTINCT FROM p_lease_token
       OR v_job.state <> 'running' OR v_job.quota_state <> 'reserved'
       OR v_job.deadline_at <= clock_timestamp() OR v_job.provider_started_at IS NOT NULL
       OR NOT EXISTS (SELECT 1 FROM public.diagnosis_job_runtime WHERE job_id = p_job_id) THEN
        RETURN jsonb_build_object('allowed', false);
    END IF;
    INSERT INTO public.provider_daily_budget(utc_date) VALUES(v_day) ON CONFLICT DO NOTHING;
    UPDATE public.provider_daily_budget SET started_calls = started_calls + 1, updated_at = clock_timestamp()
    WHERE utc_date = v_day AND started_calls < least(max_calls, 200) RETURNING started_calls INTO v_count;
    IF NOT FOUND THEN RETURN jsonb_build_object('allowed', false); END IF;
    UPDATE public.analysis_jobs SET provider_started_at = clock_timestamp() WHERE id = p_job_id;
    RETURN jsonb_build_object('allowed', true, 'budget_date', v_day, 'started_calls', v_count);
END;
$$;

CREATE FUNCTION public.finish_diagnosis_job(
    p_job_id UUID, p_lease_token UUID, p_result JSONB, p_non_billable BOOLEAN, p_error_code TEXT
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
    v_owner UUID;
    v_job public.analysis_jobs%ROWTYPE;
    v_outcome TEXT;
    v_projection JSONB;
    v_now TIMESTAMPTZ;
BEGIN
    SELECT owner_id INTO v_owner FROM public.analysis_jobs WHERE id = p_job_id;
    PERFORM 1 FROM public.profiles WHERE id = v_owner FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'JOB_NOT_FOUND' USING ERRCODE = 'P0002'; END IF;
    SELECT j.* INTO v_job FROM public.analysis_jobs j
    JOIN public.diagnosis_job_runtime r ON r.job_id = j.id
    WHERE j.id = p_job_id AND j.owner_id = v_owner FOR UPDATE OF j;
    IF NOT FOUND OR p_lease_token IS NULL OR v_job.lease_token IS DISTINCT FROM p_lease_token THEN
        RAISE EXCEPTION 'STALE_LEASE' USING ERRCODE = '42501';
    END IF;
    IF v_job.state IN ('succeeded','failed','timed_out') THEN
        RETURN jsonb_build_object('already_finalized', true, 'quota_state', v_job.quota_state, 'outcome', v_job.state);
    END IF;
    v_now := clock_timestamp();
    v_outcome := CASE WHEN v_job.deadline_at <= v_now THEN 'timed_out'
                      WHEN p_result IS NULL THEN 'failed' ELSE 'succeeded' END;
    IF v_outcome = 'succeeded' THEN
        IF v_job.provider_started_at IS NULL OR p_non_billable IS NULL OR
           p_result->>'job_id' IS DISTINCT FROM v_job.id::text OR
           p_result->>'mode' IS DISTINCT FROM 'diagnosis' OR
           p_result->>'kb_release_id' IS DISTINCT FROM v_job.kb_release_id::text THEN
            RAISE EXCEPTION 'INVALID_DIAGNOSIS_RESULT' USING ERRCODE = '22023';
        END IF;
        v_projection := p_result;
    END IF;
    PERFORM public.finalize_analysis_quota(p_job_id, v_outcome, coalesce(p_non_billable,true), v_now);
    UPDATE public.diagnosis_job_runtime SET projection = v_projection WHERE job_id = p_job_id;
    UPDATE public.analysis_jobs SET error_code =
        CASE v_outcome WHEN 'timed_out' THEN 'ANALYSIS_TIMEOUT'
            WHEN 'failed' THEN coalesce(p_error_code, 'ANALYSIS_FAILED') ELSE NULL END
    WHERE id = p_job_id;
    RETURN jsonb_build_object('already_finalized', false, 'quota_state',
        (SELECT quota_state FROM public.analysis_jobs WHERE id = p_job_id), 'outcome', v_outcome);
END;
$$;

REVOKE ALL ON FUNCTION public.diagnosis_job_payload(UUID) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.create_diagnosis_job(UUID,UUID,UUID,UUID,TEXT,BOOLEAN),
    public.read_diagnosis_job(UUID,UUID), public.lease_diagnosis_job(UUID),
    public.read_diagnosis_catalog(UUID,UUID), public.start_diagnosis_provider(UUID,UUID),
    public.finish_diagnosis_job(UUID,UUID,JSONB,BOOLEAN,TEXT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.create_diagnosis_job(UUID,UUID,UUID,UUID,TEXT,BOOLEAN),
    public.read_diagnosis_job(UUID,UUID), public.lease_diagnosis_job(UUID),
    public.read_diagnosis_catalog(UUID,UUID), public.start_diagnosis_provider(UUID,UUID),
    public.finish_diagnosis_job(UUID,UUID,JSONB,BOOLEAN,TEXT) TO service_role;

COMMIT;
