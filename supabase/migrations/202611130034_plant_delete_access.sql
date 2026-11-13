BEGIN;

CREATE INDEX analysis_jobs_photo_ids_idx ON public.analysis_jobs USING gin(photo_ids);

-- Internal predicates also cover saved identification jobs whose plant_id is NULL.
CREATE FUNCTION public.plant_photo_access_revoked(p_owner UUID, p_photo UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE SET search_path = '' AS $$
    SELECT EXISTS (
        SELECT 1 FROM public.photo_assets a
        JOIN public.plants p ON p.id=a.plant_id AND p.owner_id=a.owner_id
        WHERE a.id=p_photo AND a.owner_id=p_owner AND p.deleted_at IS NOT NULL
    ) OR EXISTS (
        SELECT 1 FROM public.analysis_jobs j
        JOIN public.plants p ON p.id=j.plant_id AND p.owner_id=j.owner_id
        WHERE j.owner_id=p_owner AND j.photo_ids @> ARRAY[p_photo] AND p.deleted_at IS NOT NULL
    ) OR EXISTS (
        SELECT 1 FROM public.first_aid_photo_upload_tickets t
        JOIN public.first_aid_followups f ON f.id=t.control_id AND f.owner_id=p_owner
        JOIN public.plants p ON p.id=f.plant_id AND p.owner_id=f.owner_id
        WHERE t.photo_asset_id=p_photo AND p.deleted_at IS NOT NULL
    )
$$;

CREATE FUNCTION public.plant_job_access_revoked(p_owner UUID, p_plant UUID, p_photos UUID[])
RETURNS BOOLEAN LANGUAGE sql STABLE SET search_path = '' AS $$
    SELECT EXISTS (
        SELECT 1 FROM public.plants p
        WHERE p.id=p_plant AND p.owner_id=p_owner AND p.deleted_at IS NOT NULL
    ) OR EXISTS (
        SELECT 1 FROM unnest(p_photos) AS photo(id)
        WHERE public.plant_photo_access_revoked(p_owner,photo.id)
    )
$$;

REVOKE ALL ON FUNCTION public.plant_photo_access_revoked(UUID,UUID),
    public.plant_job_access_revoked(UUID,UUID,UUID[]) FROM PUBLIC, anon, authenticated, service_role;

-- SECURITY DEFINER lets the policies see parent tombstones that RLS hides.
-- Require the caller's active owner identity before inspecting private links.
CREATE FUNCTION public.can_read_owner_plant_media(p_owner UUID, p_plant UUID, p_photos UUID[])
RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
    SELECT CASE WHEN public.is_active_owner(p_owner)
        THEN NOT public.plant_job_access_revoked(p_owner,p_plant,p_photos) ELSE false END
$$;
REVOKE ALL ON FUNCTION public.can_read_owner_plant_media(UUID,UUID,UUID[]) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.can_read_owner_plant_media(UUID,UUID,UUID[]) TO anon, authenticated;

ALTER POLICY plants_select_own ON public.plants
    USING (deleted_at IS NULL AND public.is_active_owner(owner_id));
ALTER POLICY photo_assets_select_own ON public.photo_assets
    USING (deleted_at IS NULL AND public.can_read_owner_plant_media(owner_id,plant_id,ARRAY[id]));
ALTER POLICY analysis_jobs_select_own ON public.analysis_jobs
    USING (public.can_read_owner_plant_media(owner_id,plant_id,photo_ids));
ALTER POLICY analysis_results_select_own ON public.analysis_results
    USING (deleted_at IS NULL AND public.can_read_owner_plant_media(owner_id,plant_id,ARRAY[source_photo_id]));

CREATE FUNCTION public.can_read_owner_diagnostic_history(p_owner UUID, p_result UUID, p_decision UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
    SELECT CASE WHEN public.is_active_owner(p_owner) THEN NOT EXISTS (
        SELECT 1 FROM public.analysis_results r
        WHERE r.owner_id=p_owner AND (
            r.id=p_result OR EXISTS (SELECT 1 FROM public.diagnostic_decisions d
                WHERE d.id=p_decision AND d.owner_id=p_owner AND d.analysis_result_id=r.id)
        ) AND (r.deleted_at IS NOT NULL OR public.plant_job_access_revoked(p_owner,r.plant_id,ARRAY[r.source_photo_id]))
    ) ELSE false END
$$;
REVOKE ALL ON FUNCTION public.can_read_owner_diagnostic_history(UUID,UUID,UUID) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.can_read_owner_diagnostic_history(UUID,UUID,UUID) TO anon, authenticated;
ALTER POLICY diagnostic_decisions_select_own ON public.diagnostic_decisions
    USING (public.can_read_owner_diagnostic_history(owner_id,analysis_result_id,NULL));
ALTER POLICY diagnostic_answers_select_own ON public.diagnostic_answers
    USING (public.can_read_owner_diagnostic_history(owner_id,NULL,decision_id));

-- Owner sync reads the full view through fetch_sync_delta, with its own owner filter.
REVOKE ALL ON public.owner_sync_entries FROM PUBLIC, anon, authenticated;

-- These rows already receive tombstones in 033. Keep them out of the direct Data API.
ALTER POLICY condition_snapshots_select_own ON public.condition_snapshots
    USING (deleted_at IS NULL AND public.is_active_owner(owner_id));
ALTER POLICY basic_care_memberships_select_own ON public.basic_care_memberships
    USING (deleted_at IS NULL AND public.is_active_owner(owner_id));
ALTER POLICY first_aid_followups_select_own ON public.first_aid_followups
    USING (deleted_at IS NULL AND public.is_active_owner(owner_id));
ALTER POLICY task_rules_select_own ON public.task_rules
    USING (deleted_at IS NULL AND public.is_active_owner(owner_id));
ALTER POLICY care_tasks_select_own ON public.care_tasks
    USING (deleted_at IS NULL AND public.is_active_owner(owner_id));
ALTER POLICY care_entries_select_own ON public.care_entries
    USING (deleted_at IS NULL AND public.is_active_owner(owner_id));
ALTER POLICY care_reversals_select_own ON public.care_reversals
    USING (deleted_at IS NULL AND public.is_active_owner(owner_id));
ALTER POLICY schedule_changes_select_own ON public.schedule_changes
    USING (deleted_at IS NULL AND public.is_active_owner(owner_id));
ALTER POLICY care_observations_select_own ON public.care_observations
    USING (deleted_at IS NULL AND public.is_active_owner(owner_id));
ALTER POLICY recovery_transitions_select_own ON public.recovery_transitions
    USING (deleted_at IS NULL AND public.is_active_owner(owner_id));


CREATE OR REPLACE FUNCTION public.read_diagnosis_upload(p_owner_id UUID, p_photo_asset_id UUID)
RETURNS JSONB LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $$
    SELECT jsonb_build_object(
        'photo_asset_id', a.id, 'owner_id', a.owner_id, 'storage_path', a.original_key,
        'mime_type', t.mime_type, 'byte_size', t.byte_size, 'content_sha256', a.content_hash,
        'expires_in_seconds', greatest(0, ceil(extract(epoch FROM t.expires_at - clock_timestamp()))),
        'state', a.state
    )
    FROM public.photo_assets a
    JOIN public.diagnosis_upload_tickets t ON t.photo_asset_id = a.id
    JOIN public.profiles p ON p.id = a.owner_id
    WHERE a.id = p_photo_asset_id AND a.owner_id = p_owner_id
      AND p.account_state = 'active'
      AND a.deleted_at IS NULL AND a.state IN ('initialized', 'ready')
      AND NOT public.plant_photo_access_revoked(p_owner_id,a.id)
$$;

CREATE OR REPLACE FUNCTION public.read_first_aid_photo_upload(p_owner_id UUID, p_photo_asset_id UUID)
RETURNS JSONB LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $$
    SELECT jsonb_build_object(
        'photo_asset_id', a.id, 'owner_id', a.owner_id, 'storage_path', a.original_key,
        'mime_type', t.mime_type, 'byte_size', t.byte_size, 'content_sha256', a.content_hash,
        'expires_in_seconds', greatest(0, ceil(extract(epoch FROM t.expires_at - clock_timestamp()))),
        'state', a.state
    )
    FROM public.photo_assets a
    JOIN public.first_aid_photo_upload_tickets t ON t.photo_asset_id = a.id
    JOIN public.profiles p ON p.id = a.owner_id
    JOIN public.first_aid_followups f ON f.id=t.control_id AND f.owner_id=a.owner_id AND f.deleted_at IS NULL
    JOIN public.plants pl ON pl.id=f.plant_id AND pl.owner_id=a.owner_id AND pl.deleted_at IS NULL
    WHERE a.id = p_photo_asset_id AND a.owner_id = p_owner_id
        AND p.account_state = 'active' AND NOT p.anonymous
        AND a.purpose = 'diary' AND a.analysis_key IS NULL AND a.draft_id IS NULL
        AND a.deleted_at IS NULL AND a.state IN ('initialized', 'ready')
$$;

CREATE OR REPLACE FUNCTION public.create_bound_photo_analysis_job(
    p_owner_id UUID, p_operation_id UUID, p_photo_asset_id UUID, p_flow_id UUID,
    p_locale TEXT, p_can_dispatch BOOLEAN, p_mode TEXT, p_credential_hash TEXT
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
    IF NOT FOUND OR (v_guest AND (p_mode IS DISTINCT FROM 'identification' OR p_credential_hash IS NULL)) THEN
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
    v_hash := encode(sha256(convert_to(jsonb_build_array(
        p_mode, p_photo_asset_id, p_flow_id, p_locale)::text, 'UTF8')), 'hex');
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
    INSERT INTO public.diagnosis_job_runtime(job_id, catalogue_release_id) VALUES(v_job, v_catalogue);
    v_result := public.diagnosis_job_payload(v_job);
    INSERT INTO public.operation_receipts(owner_id, operation_id, command_name, payload_hash, response_payload)
    VALUES(p_owner_id, p_operation_id, 'analysis.job.create', v_hash, v_result);
    RETURN jsonb_build_object('replayed', false, 'job', v_result);
END;
$$;

CREATE OR REPLACE FUNCTION public.create_plant_diagnosis_job(
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
        IF public.plant_job_access_revoked(p_owner_id,p_target_plant_id,ARRAY[p_photo_asset_id]) THEN
            RAISE EXCEPTION 'PLANT_NOT_FOUND' USING ERRCODE = 'P0002';
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

CREATE OR REPLACE FUNCTION public.read_diagnosis_job(p_owner_id UUID, p_job_id UUID)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
    v_job public.analysis_jobs%ROWTYPE;
    v_guest BOOLEAN;
    v_payload JSONB;
    v_action JSONB;
BEGIN
    SELECT anonymous INTO v_guest FROM public.profiles
    WHERE id = p_owner_id AND account_state = 'active' FOR UPDATE;
    IF NOT FOUND THEN RETURN NULL; END IF;
    -- Settlement follows the quota service lock order even for a status poll.
    PERFORM i.id FROM public.installation_access i JOIN public.analysis_jobs j
      ON j.quota_installation_id=i.id
    WHERE j.id=p_job_id AND j.owner_id=p_owner_id FOR UPDATE OF i;
    SELECT j.* INTO v_job FROM public.analysis_jobs j
    JOIN public.diagnosis_job_runtime r ON r.job_id = j.id
    WHERE j.owner_id = p_owner_id AND j.id = p_job_id
      AND (NOT v_guest OR (j.mode = 'identification' AND j.quota_installation_id IS NOT NULL))
    FOR UPDATE OF j;
    IF NOT FOUND OR public.plant_job_access_revoked(p_owner_id,v_job.plant_id,v_job.photo_ids) THEN RETURN NULL; END IF;
    IF v_guest AND v_job.state='succeeded' AND (
        EXISTS (SELECT 1 FROM public.guest_identification_sources
          WHERE photo_id=v_job.photo_ids[1] AND expires_at<=clock_timestamp())
        OR EXISTS (SELECT 1 FROM public.guest_drafts WHERE id=v_job.draft_id
          AND (deleted_at IS NOT NULL OR claimed_at IS NOT NULL))
    ) THEN RETURN NULL; END IF;
    IF v_job.state IN ('queued','running') AND v_job.deadline_at <= clock_timestamp() THEN
        PERFORM public.finalize_analysis_quota(v_job.id, 'timed_out', true, clock_timestamp());
        UPDATE public.analysis_jobs SET error_code = 'ANALYSIS_TIMEOUT' WHERE id = v_job.id;
    END IF;
    v_payload := public.diagnosis_job_payload(v_job.id);
    IF NOT v_guest AND v_job.mode = 'diagnosis' AND v_job.state = 'succeeded'
       AND v_job.plant_id IS NOT NULL AND v_payload->>'target_plant_id' = v_job.plant_id::text THEN
        SELECT jsonb_build_object(
            'job_id', v_job.id, 'plant_id', v_job.plant_id,
            'action_id', a.action->>'action_id', 'action_code', a.action->>'action_code',
            'source', a.action->'source')
        INTO v_action
        FROM public.read_first_aid_action(p_owner_id, v_job.plant_id, v_job.id) a
        WHERE NOT EXISTS (
            SELECT 1 FROM public.care_entries e
            WHERE e.owner_id = p_owner_id AND e.first_aid_job_id = v_job.id
        ) AND NOT EXISTS (
            SELECT 1 FROM public.first_aid_followups f
            WHERE f.owner_id = p_owner_id AND f.plant_id = v_job.plant_id
                AND f.origin_analysis_id = a.analysis_id
        );
        IF v_action IS NOT NULL THEN
            v_payload := v_payload || jsonb_build_object('first_aid_action', v_action);
        END IF;
    END IF;
    RETURN v_payload;
END;
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
                           FROM public.diagnosis_job_runtime WHERE job_id = v_job.id));
END;
$$;

CREATE OR REPLACE FUNCTION public.start_diagnosis_provider(p_job_id UUID, p_lease_token UUID)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
    v_day DATE := (clock_timestamp() AT TIME ZONE 'UTC')::date;
    v_owner UUID;
    v_guest BOOLEAN;
    v_job public.analysis_jobs%ROWTYPE;
    v_count INTEGER;
BEGIN
    SELECT owner_id INTO v_owner FROM public.analysis_jobs WHERE id = p_job_id;
    SELECT anonymous INTO v_guest FROM public.profiles
    WHERE id = v_owner AND account_state = 'active' FOR UPDATE;
    IF NOT FOUND THEN RETURN jsonb_build_object('allowed', false); END IF;
    SELECT * INTO v_job FROM public.analysis_jobs WHERE id = p_job_id AND owner_id = v_owner FOR UPDATE;
    IF NOT FOUND OR (v_guest AND (v_job.mode <> 'identification' OR v_job.quota_installation_id IS NULL))
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

COMMIT;
