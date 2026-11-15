BEGIN;

-- Identification pins the catalogue independently of diagnosis/care KB data.
ALTER TABLE public.analysis_jobs ALTER COLUMN kb_release_id DROP NOT NULL;
ALTER TABLE public.analysis_jobs ADD CONSTRAINT analysis_jobs_kb_required
    CHECK (kb_release_id IS NOT NULL OR mode = 'identification');

CREATE FUNCTION public.create_photo_analysis_job(
    p_owner_id UUID, p_operation_id UUID, p_photo_asset_id UUID, p_flow_id UUID,
    p_locale TEXT, p_can_dispatch BOOLEAN, p_mode TEXT
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
    IF p_operation_id IS NULL OR p_photo_asset_id IS NULL OR p_locale IS NULL OR p_locale NOT IN ('en', 'pl')
       OR p_mode IS NULL OR p_mode NOT IN ('identification', 'diagnosis') THEN
        RAISE EXCEPTION 'INVALID_JOB_INPUT' USING ERRCODE = '22023';
    END IF;
    v_hash := encode(sha256(convert_to(jsonb_build_array(
        p_mode, p_photo_asset_id, p_flow_id, p_locale)::text, 'UTF8')), 'hex');
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
    v_quota := public.admit_analysis_quota(p_mode, p_owner_id, NULL, v_job, clock_timestamp());
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

-- Preserve diagnosis callers and the original mode-specific receipt hash.
CREATE OR REPLACE FUNCTION public.create_diagnosis_job(
    p_owner_id UUID, p_operation_id UUID, p_photo_asset_id UUID, p_flow_id UUID,
    p_locale TEXT, p_can_dispatch BOOLEAN
) RETURNS JSONB LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $$
    SELECT public.create_photo_analysis_job(
        p_owner_id, p_operation_id, p_photo_asset_id, p_flow_id, p_locale, p_can_dispatch, 'diagnosis')
$$;

CREATE OR REPLACE FUNCTION public.lease_diagnosis_job(p_job_id UUID)
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
    WHERE j.id = p_job_id AND j.owner_id = v_owner AND j.mode IN ('identification', 'diagnosis')
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

CREATE FUNCTION public.read_identification_catalog(p_job_id UUID, p_lease_token UUID)
RETURNS JSONB LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $$
    SELECT jsonb_build_object('catalogue_release_id', r.catalogue_release_id,
        'plants', coalesce((SELECT jsonb_agg(jsonb_build_object(
            'plant_id', s.taxon_id, 'scientific_name', s.accepted_scientific_name,
            'display_name', coalesce(nullif(s.common_names->j.locale->0->>'name',''),s.accepted_scientific_name)
        ) ORDER BY s.taxon_id) FROM public.catalogue_release_species s
            WHERE s.release_id = r.catalogue_release_id AND s.status = 'published'
              AND s.rank IN ('species', 'hybrid')), '[]'::jsonb))
    FROM public.analysis_jobs j JOIN public.diagnosis_job_runtime r ON r.job_id = j.id
    WHERE j.id = p_job_id AND j.mode = 'identification' AND j.lease_token = p_lease_token
      AND j.state = 'running' AND j.deadline_at > clock_timestamp()
$$;

CREATE OR REPLACE FUNCTION public.finish_diagnosis_job(
    p_job_id UUID, p_lease_token UUID, p_result JSONB, p_non_billable BOOLEAN, p_error_code TEXT
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
    v_owner UUID;
    v_job public.analysis_jobs%ROWTYPE;
    v_outcome TEXT;
    v_projection JSONB;
    v_now TIMESTAMPTZ;
    v_catalogue UUID;
    v_species UUID;
    v_name TEXT;
    v_identification_status TEXT;
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
           v_job.mode NOT IN ('identification', 'diagnosis') OR
           p_result->>'job_id' IS DISTINCT FROM v_job.id::text OR
           p_result->>'mode' IS DISTINCT FROM v_job.mode THEN
            RAISE EXCEPTION 'INVALID_DIAGNOSIS_RESULT' USING ERRCODE = '22023';
        END IF;
        IF v_job.mode = 'identification' THEN
            SELECT catalogue_release_id INTO STRICT v_catalogue
            FROM public.diagnosis_job_runtime WHERE job_id = p_job_id;
            v_identification_status := p_result->>'identification_status';
            IF v_identification_status = 'identified' THEN
                SELECT s.taxon_id, coalesce(nullif(s.common_names->v_job.locale->0->>'name',''),
                       s.accepted_scientific_name)
                INTO v_species, v_name FROM public.catalogue_release_species s
                WHERE s.release_id = v_catalogue AND s.status = 'published'
                  AND s.rank IN ('species', 'hybrid') AND s.taxon_id::text = p_result->>'plant_id';
                IF NOT FOUND OR p_non_billable THEN
                    RAISE EXCEPTION 'INVALID_IDENTIFICATION_RESULT' USING ERRCODE = '22023';
                END IF;
            ELSIF v_identification_status IS DISTINCT FROM 'unknown' THEN
                RAISE EXCEPTION 'INVALID_IDENTIFICATION_RESULT' USING ERRCODE = '22023';
            END IF;
            IF p_result IS DISTINCT FROM jsonb_build_object(
                'schema_version', '1.0', 'job_id', v_job.id, 'mode', v_job.mode,
                'catalogue_release_id', v_catalogue, 'identification_status', v_identification_status,
                'plant_id', v_species, 'plant_display_name', v_name
            ) THEN
                RAISE EXCEPTION 'INVALID_IDENTIFICATION_RESULT' USING ERRCODE = '22023';
            END IF;
        ELSIF p_result->>'kb_release_id' IS DISTINCT FROM v_job.kb_release_id::text THEN
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

REVOKE ALL ON FUNCTION public.create_photo_analysis_job(UUID,UUID,UUID,UUID,TEXT,BOOLEAN,TEXT),
    public.read_identification_catalog(UUID,UUID) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.create_photo_analysis_job(UUID,UUID,UUID,UUID,TEXT,BOOLEAN,TEXT),
    public.read_identification_catalog(UUID,UUID) TO service_role;

COMMIT;
