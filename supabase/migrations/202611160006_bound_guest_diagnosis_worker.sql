BEGIN;

-- Private worker admission for the exact guest initial path introduced by 005.
-- Callers already hold the profile; keep profile -> installation -> photo -> job.
CREATE FUNCTION public._lock_bound_guest_diagnosis_worker(p_owner_id UUID, p_job_id UUID)
RETURNS BOOLEAN LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
    v_installation UUID;
    v_photo UUID;
BEGIN
    PERFORM 1 FROM public.profiles
    WHERE id = p_owner_id AND anonymous AND account_state = 'active'
      AND starter_diagnosis_job_id = p_job_id AND NOT starter_diagnosis_consumed
    FOR UPDATE;
    IF NOT FOUND THEN RETURN false; END IF;

    SELECT i.id INTO v_installation
    FROM public.installation_access i JOIN public.analysis_jobs j ON j.quota_installation_id = i.id
    WHERE j.id = p_job_id AND j.owner_id = p_owner_id
      AND p_owner_id = ANY(i.linked_owner_ids)
      AND i.starter_diagnosis_job_id = p_job_id AND NOT i.starter_diagnosis_consumed
    FOR UPDATE OF i;
    IF NOT FOUND THEN RETURN false; END IF;

    SELECT a.id INTO v_photo
    FROM public.photo_assets a
    JOIN public.diagnosis_upload_tickets t ON t.photo_asset_id = a.id
    JOIN public.analysis_jobs j ON j.photo_ids = ARRAY[a.id]
    WHERE j.id = p_job_id AND j.owner_id = p_owner_id AND a.owner_id = p_owner_id
      AND a.state = 'ready' AND a.uploaded_at IS NOT NULL AND a.deleted_at IS NULL
      AND a.plant_id IS NULL AND a.draft_id IS NULL
      AND NOT public.plant_photo_access_revoked(p_owner_id, a.id)
    FOR UPDATE OF a;
    IF NOT FOUND THEN RETURN false; END IF;

    PERFORM 1 FROM public.analysis_jobs j
    JOIN public.diagnosis_job_runtime r ON r.job_id = j.id
    JOIN public.operation_receipts o ON o.owner_id = j.owner_id AND o.operation_id = j.operation_id
    WHERE j.id = p_job_id AND j.owner_id = p_owner_id
      AND j.mode = 'diagnosis' AND j.plant_id IS NULL AND j.draft_id IS NULL
      AND j.photo_ids = ARRAY[v_photo] AND j.quota_kind = 'starter_diagnosis'
      AND j.quota_state = 'reserved' AND j.quota_owner_id = p_owner_id
      AND j.quota_installation_id = v_installation
      AND r.initial_context IS NOT NULL AND r.repeat_context IS NULL
      AND o.command_name = 'analysis.job.create' AND o.payload_hash = j.payload_hash
      AND o.response_payload->>'job_id' = j.id::text
      -- 005 hashes the supplied flow, then stores coalesce(flow, operation).
      AND j.payload_hash IN (
          encode(sha256(convert_to(jsonb_build_array(
              'bound_guest_initial_diagnosis_v1', p_owner_id, v_installation,
              j.mode, v_photo, j.flow_id, j.locale, r.initial_context)::text, 'UTF8')), 'hex'),
          CASE WHEN j.flow_id = j.operation_id THEN
              encode(sha256(convert_to(jsonb_build_array(
                  'bound_guest_initial_diagnosis_v1', p_owner_id, v_installation,
                  j.mode, v_photo, NULL, j.locale, r.initial_context)::text, 'UTF8')), 'hex')
          END)
    FOR UPDATE OF j;
    RETURN FOUND;
END;
$$;

REVOKE ALL ON FUNCTION public._lock_bound_guest_diagnosis_worker(UUID,UUID)
FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.lease_diagnosis_job(p_job_id UUID)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
    v_owner UUID;
    v_guest BOOLEAN;
    v_bound BOOLEAN := false;
    v_job public.analysis_jobs%ROWTYPE;
    v_upload JSONB;
BEGIN
    SELECT owner_id INTO v_owner FROM public.analysis_jobs WHERE id = p_job_id;
    SELECT anonymous INTO v_guest FROM public.profiles
    WHERE id = v_owner AND account_state = 'active' FOR UPDATE;
    IF NOT FOUND THEN RETURN NULL; END IF;
    IF v_guest AND EXISTS (SELECT 1 FROM public.analysis_jobs WHERE id = p_job_id AND mode = 'diagnosis') THEN
        v_bound := public._lock_bound_guest_diagnosis_worker(v_owner, p_job_id);
        IF NOT v_bound THEN RETURN NULL; END IF;
    END IF;
    UPDATE public.analysis_jobs j SET state = 'running', lease_token = gen_random_uuid(), updated_at = clock_timestamp()
    WHERE j.id = p_job_id AND j.owner_id = v_owner AND j.mode IN ('identification', 'diagnosis')
      AND (NOT v_guest OR (j.mode = 'identification' AND j.quota_installation_id IS NOT NULL) OR v_bound)
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

CREATE OR REPLACE FUNCTION public.start_diagnosis_provider(p_job_id UUID, p_lease_token UUID)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
    v_day DATE := (clock_timestamp() AT TIME ZONE 'UTC')::date;
    v_owner UUID;
    v_guest BOOLEAN;
    v_bound BOOLEAN := false;
    v_job public.analysis_jobs%ROWTYPE;
    v_count INTEGER;
BEGIN
    SELECT owner_id INTO v_owner FROM public.analysis_jobs WHERE id = p_job_id;
    SELECT anonymous INTO v_guest FROM public.profiles
    WHERE id = v_owner AND account_state = 'active' FOR UPDATE;
    IF NOT FOUND THEN RETURN jsonb_build_object('allowed', false); END IF;
    IF v_guest AND EXISTS (SELECT 1 FROM public.analysis_jobs WHERE id = p_job_id AND mode = 'diagnosis') THEN
        v_bound := public._lock_bound_guest_diagnosis_worker(v_owner, p_job_id);
        IF NOT v_bound THEN RETURN jsonb_build_object('allowed', false); END IF;
    END IF;
    SELECT * INTO v_job FROM public.analysis_jobs WHERE id = p_job_id AND owner_id = v_owner FOR UPDATE;
    IF NOT FOUND OR (v_guest AND NOT v_bound AND (v_job.mode <> 'identification' OR v_job.quota_installation_id IS NULL))
       OR public.plant_job_access_revoked(v_owner,v_job.plant_id,v_job.photo_ids)
       OR p_lease_token IS NULL OR v_job.lease_token IS DISTINCT FROM p_lease_token
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

-- Replacement keeps existing ACLs; explicitly retain service-only entrypoints.
REVOKE ALL ON FUNCTION public.lease_diagnosis_job(UUID), public.start_diagnosis_provider(UUID,UUID)
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.lease_diagnosis_job(UUID), public.start_diagnosis_provider(UUID,UUID)
TO service_role;

COMMIT;
