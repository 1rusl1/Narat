BEGIN;

ALTER TABLE public.diagnosis_job_runtime ADD COLUMN initial_context JSONB;
ALTER TABLE public.diagnosis_job_runtime ADD CONSTRAINT diagnosis_initial_context_closed CHECK (
    initial_context IS NULL OR CASE WHEN jsonb_typeof(initial_context) = 'object' THEN coalesce(
        initial_context ?& ARRAY['light', 'watering_frequency', 'drainage']
        AND initial_context - ARRAY['light', 'watering_frequency', 'drainage'] = '{}'::jsonb
        AND initial_context->>'light' IN ('low', 'medium', 'bright_indirect', 'direct_sun', 'unknown')
        AND initial_context->>'watering_frequency' IN ('frequent', 'moderate', 'sparse', 'unknown')
        AND initial_context->>'drainage' IN ('yes', 'no', 'unknown')
        AND repeat_context IS NULL, false) ELSE false END
);

CREATE FUNCTION public.preserve_initial_diagnosis_context()
RETURNS trigger LANGUAGE plpgsql SET search_path = '' AS $$
BEGIN
    IF OLD.initial_context IS NOT NULL AND NEW.initial_context IS DISTINCT FROM OLD.initial_context THEN
        RAISE EXCEPTION 'IMMUTABLE_INITIAL_CONTEXT' USING ERRCODE = '22023';
    END IF;
    RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.preserve_initial_diagnosis_context() FROM PUBLIC, anon, authenticated, service_role;
CREATE TRIGGER preserve_initial_diagnosis_context
BEFORE UPDATE OF initial_context ON public.diagnosis_job_runtime
FOR EACH ROW EXECUTE FUNCTION public.preserve_initial_diagnosis_context();

CREATE FUNCTION public.create_initial_diagnosis_job(
    p_owner_id UUID, p_operation_id UUID, p_photo_asset_id UUID, p_flow_id UUID,
    p_locale TEXT, p_can_dispatch BOOLEAN, p_initial_context JSONB
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
    v_receipt public.operation_receipts%ROWTYPE;
    v_hash TEXT;
    v_legacy_hash TEXT;
    v_job UUID;
    v_result JSONB;
BEGIN
    PERFORM 1 FROM public.profiles
    WHERE id = p_owner_id AND account_state = 'active' AND NOT anonymous FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'ACTIVE_PERMANENT_OWNER_REQUIRED' USING ERRCODE = '42501';
    END IF;
    IF p_operation_id IS NULL OR p_photo_asset_id IS NULL
       OR p_locale IS NULL OR p_locale NOT IN ('en', 'pl') THEN
        RAISE EXCEPTION 'INVALID_JOB_INPUT' USING ERRCODE = '22023';
    END IF;
    IF jsonb_typeof(p_initial_context) IS DISTINCT FROM 'object' THEN
        RAISE EXCEPTION 'INVALID_INITIAL_CONTEXT' USING ERRCODE = '22023';
    END IF;
    IF NOT coalesce(
        p_initial_context ?& ARRAY['light', 'watering_frequency', 'drainage']
        AND p_initial_context - ARRAY['light', 'watering_frequency', 'drainage'] = '{}'::jsonb
        AND p_initial_context->>'light' IN ('low', 'medium', 'bright_indirect', 'direct_sun', 'unknown')
        AND p_initial_context->>'watering_frequency' IN ('frequent', 'moderate', 'sparse', 'unknown')
        AND p_initial_context->>'drainage' IN ('yes', 'no', 'unknown'), false) THEN
        RAISE EXCEPTION 'INVALID_INITIAL_CONTEXT' USING ERRCODE = '22023';
    END IF;
    v_hash := encode(sha256(convert_to(jsonb_build_array(
        'initial_diagnosis_context_v1', p_owner_id, 'diagnosis', p_photo_asset_id,
        p_flow_id, p_locale, p_initial_context)::text, 'UTF8')), 'hex');
    SELECT * INTO v_receipt FROM public.operation_receipts
    WHERE owner_id = p_owner_id AND operation_id = p_operation_id;
    IF FOUND THEN
        IF v_receipt.command_name <> 'analysis.job.create' OR v_receipt.payload_hash <> v_hash THEN
            RAISE EXCEPTION 'IDEMPOTENCY_CONFLICT' USING ERRCODE = '23505';
        END IF;
        IF public.plant_photo_access_revoked(p_owner_id, p_photo_asset_id) THEN
            RAISE EXCEPTION 'PHOTO_NOT_READY' USING ERRCODE = 'P0002';
        END IF;
        RETURN jsonb_build_object('replayed', true, 'job', v_receipt.response_payload);
    END IF;

    -- The profile lock serializes legacy admission and this receipt replacement.
    v_result := public.create_diagnosis_job(
        p_owner_id, p_operation_id, p_photo_asset_id, p_flow_id, p_locale, p_can_dispatch);
    IF v_result->>'replayed' IS DISTINCT FROM 'false' THEN
        RAISE EXCEPTION 'IDEMPOTENCY_CONFLICT' USING ERRCODE = '23505';
    END IF;
    v_job := (v_result->'job'->>'job_id')::uuid;
    v_legacy_hash := encode(sha256(convert_to(jsonb_build_array(
        'diagnosis', p_photo_asset_id, p_flow_id, p_locale)::text, 'UTF8')), 'hex');
    UPDATE public.analysis_jobs SET payload_hash = v_hash
    WHERE id = v_job AND owner_id = p_owner_id AND operation_id = p_operation_id
      AND mode = 'diagnosis' AND plant_id IS NULL AND payload_hash = v_legacy_hash;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'IDEMPOTENCY_CONFLICT' USING ERRCODE = '23505';
    END IF;
    UPDATE public.diagnosis_job_runtime SET initial_context = p_initial_context
    WHERE job_id = v_job AND initial_context IS NULL AND repeat_context IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'IDEMPOTENCY_CONFLICT' USING ERRCODE = '23505';
    END IF;
    UPDATE public.operation_receipts SET payload_hash = v_hash
    WHERE owner_id = p_owner_id AND operation_id = p_operation_id
      AND command_name = 'analysis.job.create' AND payload_hash = v_legacy_hash
      AND response_payload = v_result->'job';
    IF NOT FOUND THEN
        RAISE EXCEPTION 'IDEMPOTENCY_CONFLICT' USING ERRCODE = '23505';
    END IF;
    RETURN v_result;
END;
$$;
REVOKE ALL ON FUNCTION public.create_initial_diagnosis_job(UUID,UUID,UUID,UUID,TEXT,BOOLEAN,JSONB)
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.create_initial_diagnosis_job(UUID,UUID,UUID,UUID,TEXT,BOOLEAN,JSONB)
TO service_role;

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
      AND NOT public.plant_job_access_revoked(v_owner,j.plant_id,j.photo_ids)
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
                           FROM public.diagnosis_job_runtime WHERE job_id = v_job.id))
        || (SELECT CASE WHEN initial_context IS NOT NULL
                        THEN jsonb_build_object('initial_context', initial_context)
                        ELSE '{}'::jsonb END
            FROM public.diagnosis_job_runtime WHERE job_id = v_job.id);
END;
$$;

COMMIT;
