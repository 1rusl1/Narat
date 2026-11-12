BEGIN;

-- The first successful analysis fixes the lifetime of an unclaimed guest photo.
CREATE TABLE public.guest_identification_sources (
    photo_id UUID PRIMARY KEY REFERENCES public.photo_assets(id) ON DELETE CASCADE,
    succeeded_at TIMESTAMPTZ NOT NULL,
    expires_at TIMESTAMPTZ NOT NULL,
    storage_cleaned_at TIMESTAMPTZ
);
ALTER TABLE public.guest_identification_sources ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.guest_identification_sources FROM PUBLIC, anon, authenticated, service_role;

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
$$;

CREATE OR REPLACE FUNCTION public.create_bound_photo_upload(
    p_owner_id UUID, p_operation_id UUID, p_mime_type TEXT, p_byte_size INTEGER, p_content_sha256 TEXT, p_credential_hash TEXT
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
    v_profile public.profiles%ROWTYPE;
    v_receipt public.operation_receipts%ROWTYPE;
    v_asset UUID;
    v_key TEXT;
    v_hash TEXT;
BEGIN
    IF p_operation_id IS NULL OR p_mime_type IS NULL
       OR p_mime_type NOT IN ('image/jpeg', 'image/png', 'image/webp')
       OR p_byte_size IS NULL OR p_byte_size NOT BETWEEN 1 AND 10485760
       OR p_content_sha256 IS NULL OR p_content_sha256 !~ '^[a-f0-9]{64}$' THEN
        RAISE EXCEPTION 'INVALID_PHOTO_INPUT' USING ERRCODE = '22023';
    END IF;
    SELECT * INTO v_profile FROM public.profiles WHERE id = p_owner_id FOR UPDATE;
    IF NOT FOUND OR v_profile.account_state <> 'active' OR (v_profile.anonymous AND p_credential_hash IS NULL) THEN
        RAISE EXCEPTION 'ACTIVE_PERMANENT_OWNER_REQUIRED' USING ERRCODE = '42501';
    END IF;
    IF v_profile.anonymous AND NOT EXISTS (
        SELECT 1 FROM public.installation_access i
        WHERE i.credential_hash=p_credential_hash AND p_owner_id=ANY(i.linked_owner_ids)
    ) THEN
        RAISE EXCEPTION 'INSTALLATION_CREDENTIAL_MISMATCH' USING ERRCODE = '42501';
    END IF;
    v_hash := encode(sha256(convert_to(jsonb_build_array(p_mime_type, p_byte_size, p_content_sha256)::text, 'UTF8')), 'hex');
    SELECT * INTO v_receipt FROM public.operation_receipts
    WHERE owner_id = p_owner_id AND operation_id = p_operation_id;
    IF FOUND THEN
        IF v_receipt.command_name <> 'media.upload-ticket' OR v_receipt.payload_hash <> v_hash THEN
            RAISE EXCEPTION 'IDEMPOTENCY_CONFLICT' USING ERRCODE = '23505';
        END IF;
        RETURN public.read_diagnosis_upload(p_owner_id, (v_receipt.response_payload->>'photo_asset_id')::uuid);
    END IF;
    v_asset := gen_random_uuid();
    v_key := p_owner_id::text || '/' || v_asset::text;
    INSERT INTO public.photo_assets(id, owner_id, purpose, original_key, analysis_key, content_hash)
    VALUES(v_asset, p_owner_id, 'initial', v_key, v_key, p_content_sha256);
    INSERT INTO public.diagnosis_upload_tickets VALUES(v_asset, p_mime_type, p_byte_size, clock_timestamp() + interval '60 seconds');
    INSERT INTO public.operation_receipts(owner_id, operation_id, command_name, payload_hash, response_payload)
    VALUES(p_owner_id, p_operation_id, 'media.upload-ticket', v_hash, jsonb_build_object('photo_asset_id', v_asset));
    RETURN public.read_diagnosis_upload(p_owner_id, v_asset);
END;
$$;

CREATE OR REPLACE FUNCTION public.create_diagnosis_upload(
    p_owner_id UUID, p_operation_id UUID, p_mime_type TEXT, p_byte_size INTEGER, p_content_sha256 TEXT
) RETURNS JSONB LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $$
    SELECT public.create_bound_photo_upload(
        p_owner_id, p_operation_id, p_mime_type, p_byte_size, p_content_sha256, NULL)
$$;

CREATE OR REPLACE FUNCTION public.mark_diagnosis_upload_ready(p_owner_id UUID, p_photo_asset_id UUID, p_content_sha256 TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
    PERFORM 1 FROM public.profiles
    WHERE id = p_owner_id AND account_state = 'active' FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'ACTIVE_PERMANENT_OWNER_REQUIRED' USING ERRCODE = '42501';
    END IF;
    UPDATE public.photo_assets a
    SET state = 'ready', uploaded_at = clock_timestamp(), updated_at = clock_timestamp()
    WHERE a.id = p_photo_asset_id AND a.owner_id = p_owner_id AND a.deleted_at IS NULL
      AND a.state = 'initialized' AND a.content_hash = p_content_sha256
      AND EXISTS (SELECT 1 FROM public.diagnosis_upload_tickets t WHERE t.photo_asset_id = a.id);
    IF NOT EXISTS (SELECT 1 FROM public.photo_assets a
        WHERE a.id = p_photo_asset_id AND a.owner_id = p_owner_id AND a.deleted_at IS NULL
          AND a.content_hash = p_content_sha256 AND a.state = 'ready') THEN
        RAISE EXCEPTION 'PHOTO_NOT_FOUND' USING ERRCODE = 'P0002';
    END IF;
    RETURN public.read_diagnosis_upload(p_owner_id, p_photo_asset_id);
END;
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
        RETURN jsonb_build_object('replayed', true, 'job', v_receipt.response_payload);
    END IF;
    IF EXISTS (SELECT 1 FROM public.analysis_jobs WHERE owner_id = p_owner_id AND operation_id = p_operation_id) THEN
        RAISE EXCEPTION 'IDEMPOTENCY_CONFLICT' USING ERRCODE = '23505';
    END IF;
    PERFORM 1 FROM public.photo_assets a
    JOIN public.diagnosis_upload_tickets t ON t.photo_asset_id = a.id
    WHERE a.id = p_photo_asset_id AND a.owner_id = p_owner_id
      AND a.deleted_at IS NULL AND a.state = 'ready' AND a.uploaded_at IS NOT NULL
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

CREATE OR REPLACE FUNCTION public.create_photo_analysis_job(
    p_owner_id UUID, p_operation_id UUID, p_photo_asset_id UUID, p_flow_id UUID,
    p_locale TEXT, p_can_dispatch BOOLEAN, p_mode TEXT
) RETURNS JSONB LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $$
    SELECT public.create_bound_photo_analysis_job(
        p_owner_id, p_operation_id, p_photo_asset_id, p_flow_id, p_locale, p_can_dispatch, p_mode, NULL)
$$;

CREATE OR REPLACE FUNCTION public.read_diagnosis_job(p_owner_id UUID, p_job_id UUID)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
    v_job public.analysis_jobs%ROWTYPE;
    v_guest BOOLEAN;
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
    IF NOT FOUND THEN RETURN NULL; END IF;
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
    RETURN public.diagnosis_job_payload(v_job.id);
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

REVOKE ALL ON FUNCTION public.create_bound_photo_upload(UUID,UUID,TEXT,INTEGER,TEXT,TEXT),
    public.create_bound_photo_analysis_job(UUID,UUID,UUID,UUID,TEXT,BOOLEAN,TEXT,TEXT)
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.create_bound_photo_upload(UUID,UUID,TEXT,INTEGER,TEXT,TEXT),
    public.create_bound_photo_analysis_job(UUID,UUID,UUID,UUID,TEXT,BOOLEAN,TEXT,TEXT) TO service_role;

CREATE OR REPLACE FUNCTION public.finish_diagnosis_job(
    p_job_id UUID, p_lease_token UUID, p_result JSONB, p_non_billable BOOLEAN, p_error_code TEXT
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
    v_owner UUID;
    v_guest BOOLEAN;
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
    SELECT anonymous INTO v_guest FROM public.profiles WHERE id = v_owner FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'JOB_NOT_FOUND' USING ERRCODE = 'P0002'; END IF;
    -- Binding can hold an installation before reading the guest job.
    PERFORM i.id FROM public.installation_access i JOIN public.analysis_jobs j
      ON j.quota_installation_id=i.id
    WHERE j.id=p_job_id AND j.owner_id=v_owner FOR UPDATE OF i;
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
    IF v_guest AND v_outcome='succeeded' AND v_job.mode='identification' THEN
        INSERT INTO public.guest_identification_sources(photo_id,succeeded_at,expires_at)
        VALUES(v_job.photo_ids[1],v_now,v_now+interval '7 days')
        ON CONFLICT(photo_id) DO NOTHING;
    END IF;
    UPDATE public.diagnosis_job_runtime SET projection = v_projection WHERE job_id = p_job_id;
    UPDATE public.analysis_jobs SET error_code =
        CASE v_outcome WHEN 'timed_out' THEN 'ANALYSIS_TIMEOUT'
            WHEN 'failed' THEN coalesce(p_error_code, 'ANALYSIS_FAILED') ELSE NULL END
    WHERE id = p_job_id;
    RETURN jsonb_build_object('already_finalized', false, 'quota_state',
        (SELECT quota_state FROM public.analysis_jobs WHERE id = p_job_id), 'outcome', v_outcome);
END;
$$;

ALTER TABLE public.guest_drafts
    ALTER COLUMN expires_at SET DEFAULT (clock_timestamp() + interval '7 days'),
    ADD COLUMN confirmed_taxon_id UUID REFERENCES public.catalogue_taxa(id),
    ADD COLUMN installation_id UUID REFERENCES public.installation_access(id),
    ADD COLUMN source_storage_key TEXT,
    ADD COLUMN claimed_at TIMESTAMPTZ,
    ADD COLUMN storage_cleaned_at TIMESTAMPTZ;
ALTER TABLE public.draft_claims ADD COLUMN commit_operation_id UUID;

CREATE UNIQUE INDEX guest_photo_drafts_one_per_job
    ON public.guest_drafts (analysis_job_id) WHERE installation_id IS NOT NULL;

CREATE FUNCTION public.create_guest_photo_draft(
    p_owner_id UUID, p_operation_id UUID, p_job_id UUID, p_taxon_id UUID, p_credential_hash TEXT
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
    v_installation UUID;
    v_receipt public.operation_receipts%ROWTYPE;
    v_photo public.photo_assets%ROWTYPE;
    v_job public.analysis_jobs%ROWTYPE;
    v_draft public.guest_drafts%ROWTYPE;
    v_now TIMESTAMPTZ;
    v_expires_at TIMESTAMPTZ;
    v_hash TEXT;
    v_result JSONB;
BEGIN
    PERFORM 1 FROM public.profiles
    WHERE id=p_owner_id AND anonymous AND account_state='active' FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'ACTIVE_GUEST_REQUIRED' USING ERRCODE='42501'; END IF;
    SELECT i.id INTO v_installation FROM public.installation_access i
    WHERE i.credential_hash=p_credential_hash AND p_owner_id=ANY(i.linked_owner_ids) FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'INSTALLATION_CREDENTIAL_MISMATCH' USING ERRCODE='42501'; END IF;

    v_hash := encode(sha256(convert_to(jsonb_build_array(v_installation,p_job_id,p_taxon_id)::text,'UTF8')),'hex');
    SELECT * INTO v_receipt FROM public.operation_receipts
    WHERE owner_id=p_owner_id AND operation_id=p_operation_id;
    IF FOUND THEN
        IF v_receipt.command_name <> 'draft.create' OR v_receipt.payload_hash <> v_hash THEN
            RAISE EXCEPTION 'IDEMPOTENCY_CONFLICT' USING ERRCODE='23505';
        END IF;
        PERFORM 1 FROM public.guest_drafts WHERE id=(v_receipt.response_payload->>'draft_id')::uuid
          AND deleted_at IS NULL AND claimed_at IS NULL AND expires_at>clock_timestamp() FOR UPDATE;
        IF NOT FOUND THEN RAISE EXCEPTION 'DRAFT_EXPIRED' USING ERRCODE='P0002'; END IF;
        RETURN v_receipt.response_payload;
    END IF;
    SELECT j.* INTO v_job FROM public.analysis_jobs j
    JOIN public.diagnosis_job_runtime r ON r.job_id=j.id
    WHERE j.id=p_job_id AND j.owner_id=p_owner_id AND j.quota_installation_id=v_installation
      AND j.mode='identification' AND j.state='succeeded'
      AND r.projection->>'identification_status' IN ('identified','unknown')
    FOR UPDATE OF j;
    IF NOT FOUND THEN RAISE EXCEPTION 'IDENTIFICATION_SOURCE_NOT_FOUND' USING ERRCODE='P0002'; END IF;
    PERFORM 1 FROM public.catalogue_release_species s JOIN public.catalogue_releases r
      ON r.id=s.release_id AND r.state='published'
    WHERE s.taxon_id=p_taxon_id AND s.status='published' AND s.rank IN ('species','hybrid');
    IF NOT FOUND THEN RAISE EXCEPTION 'TAXON_NOT_PUBLISHED' USING ERRCODE='22023'; END IF;
    SELECT a.* INTO v_photo FROM public.photo_assets a
    JOIN public.diagnosis_upload_tickets t ON t.photo_asset_id=a.id
    WHERE a.id=v_job.photo_ids[1] AND a.owner_id=p_owner_id AND a.state='ready'
      AND a.deleted_at IS NULL AND a.plant_id IS NULL
      AND a.original_key=p_owner_id::text || '/' || a.id::text
    FOR UPDATE OF a;
    IF NOT FOUND THEN RAISE EXCEPTION 'IDENTIFICATION_SOURCE_NOT_FOUND' USING ERRCODE='P0002'; END IF;
    IF v_photo.draft_id IS NOT NULL THEN
        RAISE EXCEPTION 'DRAFT_ALREADY_EXISTS' USING ERRCODE='23505';
    END IF;
    SELECT expires_at INTO v_expires_at FROM public.guest_identification_sources
    WHERE photo_id=v_photo.id AND storage_cleaned_at IS NULL FOR UPDATE;
    v_now := clock_timestamp();
    IF NOT FOUND OR v_expires_at<=v_now THEN RAISE EXCEPTION 'DRAFT_EXPIRED' USING ERRCODE='P0002'; END IF;
    INSERT INTO public.guest_drafts(
      guest_owner_id,flow_id,intent,add_method,photo_id,analysis_job_id,expires_at,created_at,
      updated_at,confirmed_taxon_id,installation_id,source_storage_key
    ) VALUES (
      p_owner_id,v_job.flow_id,'care','scan',v_photo.id,v_job.id,v_expires_at,v_now,
      v_now,p_taxon_id,v_installation,v_photo.original_key
    ) RETURNING * INTO v_draft;
    UPDATE public.photo_assets SET draft_id=v_draft.id,updated_at=v_now WHERE id=v_photo.id;
    UPDATE public.analysis_jobs SET draft_id=v_draft.id WHERE id=v_job.id;
    v_result := jsonb_build_object('draft_id',v_draft.id,'expires_at',v_draft.expires_at);
    INSERT INTO public.operation_receipts(owner_id,operation_id,command_name,payload_hash,response_payload)
    VALUES(p_owner_id,p_operation_id,'draft.create',v_hash,v_result);
    RETURN v_result;
END;
$$;

CREATE FUNCTION public.prepare_guest_photo_claim(
    p_owner_id UUID, p_operation_id UUID, p_draft_id UUID, p_credential_hash TEXT
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
    v_installation public.installation_access%ROWTYPE;
    v_draft public.guest_drafts%ROWTYPE;
    v_claim public.draft_claims%ROWTYPE;
    v_receipt public.operation_receipts%ROWTYPE;
    v_hash TEXT;
    v_now TIMESTAMPTZ;
    v_result JSONB;
BEGIN
    PERFORM 1 FROM public.profiles
    WHERE id=p_owner_id AND NOT anonymous AND account_state='active' FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'ACTIVE_PERMANENT_OWNER_REQUIRED' USING ERRCODE='42501'; END IF;
    SELECT * INTO v_installation FROM public.installation_access
    WHERE credential_hash=p_credential_hash AND p_owner_id=ANY(linked_owner_ids) FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'INSTALLATION_CREDENTIAL_MISMATCH' USING ERRCODE='42501'; END IF;
    SELECT * INTO v_draft FROM public.guest_drafts WHERE id=p_draft_id FOR UPDATE;
    IF NOT FOUND OR v_draft.installation_id IS DISTINCT FROM v_installation.id
       OR (v_draft.guest_owner_id=ANY(v_installation.linked_owner_ids)) IS NOT TRUE THEN
        RAISE EXCEPTION 'DRAFT_EXPIRED' USING ERRCODE='P0002';
    END IF;
    v_hash := encode(sha256(convert_to(jsonb_build_array(v_installation.id,p_draft_id)::text,'UTF8')),'hex');
    SELECT * INTO v_receipt FROM public.operation_receipts
    WHERE owner_id=p_owner_id AND operation_id=p_operation_id;
    IF FOUND AND (v_receipt.command_name <> 'claim.prepare' OR v_receipt.payload_hash <> v_hash) THEN
        RAISE EXCEPTION 'IDEMPOTENCY_CONFLICT' USING ERRCODE='23505';
    END IF;
    v_now := clock_timestamp();
    IF v_draft.deleted_at IS NOT NULL OR v_draft.claimed_at IS NOT NULL OR v_draft.expires_at<=v_now THEN
        RAISE EXCEPTION 'DRAFT_EXPIRED' USING ERRCODE='P0002';
    END IF;
    SELECT * INTO v_claim FROM public.draft_claims WHERE draft_id=v_draft.id
    ORDER BY created_at,id LIMIT 1 FOR UPDATE;
    IF FOUND THEN
        IF v_claim.target_owner_id IS DISTINCT FROM p_owner_id OR v_claim.proof_hash<>p_credential_hash THEN
            RAISE EXCEPTION 'CLAIM_OWNER_CONFLICT' USING ERRCODE='23505';
        END IF;
        IF v_claim.expires_at<=v_now THEN
            UPDATE public.draft_claims SET expires_at=least(v_now+interval '15 minutes',v_draft.expires_at),
                updated_at=v_now WHERE id=v_claim.id RETURNING * INTO v_claim;
        END IF;
    ELSE
        INSERT INTO public.draft_claims(draft_id,proof_hash,expires_at,target_owner_id,operation_id)
        VALUES(v_draft.id,p_credential_hash,least(v_now+interval '15 minutes',v_draft.expires_at),
               p_owner_id,p_operation_id) RETURNING * INTO v_claim;
    END IF;
    v_result := jsonb_build_object('claim_id',v_claim.id,'draft_id',v_draft.id,'proof_expires_at',v_claim.expires_at);
    INSERT INTO public.operation_receipts(owner_id,operation_id,command_name,payload_hash,response_payload)
    VALUES(p_owner_id,p_operation_id,'claim.prepare',v_hash,v_result)
    ON CONFLICT(owner_id,operation_id) DO UPDATE SET response_payload=excluded.response_payload;
    RETURN v_result;
END;
$$;

CREATE FUNCTION public.process_guest_photo_claim(
    p_owner_id UUID, p_operation_id UUID, p_claim_id UUID, p_credential_hash TEXT,
    p_verified_copy BOOLEAN
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
    v_installation public.installation_access%ROWTYPE;
    v_draft public.guest_drafts%ROWTYPE;
    v_claim public.draft_claims%ROWTYPE;
    v_receipt public.operation_receipts%ROWTYPE;
    v_photo public.photo_assets%ROWTYPE;
    v_upload JSONB;
    v_hash TEXT;
    v_now TIMESTAMPTZ;
    v_ts TIMESTAMPTZ;
    v_destination TEXT;
    v_source_owner UUID;
    v_plant UUID;
    v_taxon public.catalogue_taxa%ROWTYPE;
    v_name TEXT;
    v_plan TEXT;
    v_next JSONB;
    v_result JSONB;
BEGIN
    IF p_verified_copy IS NULL OR p_operation_id IS NULL OR p_claim_id IS NULL THEN
        RAISE EXCEPTION 'INVALID_CLAIM_INPUT' USING ERRCODE='22023';
    END IF;
    SELECT d.guest_owner_id INTO v_source_owner
    FROM public.draft_claims c JOIN public.guest_drafts d ON d.id=c.draft_id
    WHERE c.id=p_claim_id AND c.target_owner_id=p_owner_id;
    PERFORM id FROM public.profiles WHERE id IN (p_owner_id,v_source_owner) ORDER BY id FOR UPDATE;
    PERFORM 1 FROM public.profiles
    WHERE id=p_owner_id AND NOT anonymous AND account_state='active';
    IF NOT FOUND THEN RAISE EXCEPTION 'ACTIVE_PERMANENT_OWNER_REQUIRED' USING ERRCODE='42501'; END IF;
    SELECT * INTO v_installation FROM public.installation_access
    WHERE credential_hash=p_credential_hash AND p_owner_id=ANY(linked_owner_ids) FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'INSTALLATION_CREDENTIAL_MISMATCH' USING ERRCODE='42501'; END IF;

    v_hash := encode(sha256(convert_to(jsonb_build_array(p_claim_id,v_installation.id)::text,'UTF8')),'hex');
    SELECT * INTO v_receipt FROM public.operation_receipts
    WHERE owner_id=p_owner_id AND operation_id=p_operation_id;
    IF FOUND THEN
        IF v_receipt.command_name <> 'claim.commit' OR v_receipt.payload_hash <> v_hash THEN
            RAISE EXCEPTION 'IDEMPOTENCY_CONFLICT' USING ERRCODE='23505';
        END IF;
        RETURN jsonb_build_object('receipt',v_receipt.response_payload,'cleanup_draft_id',
            (SELECT draft_id FROM public.draft_claims WHERE id=p_claim_id AND target_owner_id=p_owner_id));
    END IF;
    SELECT d.* INTO v_draft FROM public.guest_drafts d JOIN public.draft_claims c ON c.draft_id=d.id
    WHERE c.id=p_claim_id AND c.target_owner_id=p_owner_id AND c.proof_hash=p_credential_hash
      AND d.installation_id=v_installation.id
    FOR UPDATE OF d;
    IF NOT FOUND THEN RAISE EXCEPTION 'DRAFT_EXPIRED' USING ERRCODE='P0002'; END IF;
    SELECT * INTO STRICT v_claim FROM public.draft_claims WHERE id=p_claim_id FOR UPDATE;
    PERFORM 1 FROM public.profiles
    WHERE id=v_draft.guest_owner_id AND id=v_source_owner AND anonymous AND account_state='active';
    IF NOT FOUND THEN RAISE EXCEPTION 'DRAFT_EXPIRED' USING ERRCODE='P0002'; END IF;
    v_now := clock_timestamp();
    IF v_draft.deleted_at IS NOT NULL OR v_draft.claimed_at IS NOT NULL OR v_draft.expires_at<=v_now THEN
        RAISE EXCEPTION 'DRAFT_EXPIRED' USING ERRCODE='P0002';
    END IF;
    IF v_claim.expires_at<=v_now THEN
        RAISE EXCEPTION 'CLAIM_PROOF_EXPIRED' USING ERRCODE='22023';
    END IF;
    IF v_claim.commit_operation_id IS NOT NULL AND v_claim.commit_operation_id<>p_operation_id THEN
        RAISE EXCEPTION 'IDEMPOTENCY_CONFLICT' USING ERRCODE='23505';
    END IF;

    SELECT * INTO v_photo FROM public.photo_assets
    WHERE id=v_draft.photo_id AND draft_id=v_draft.id AND owner_id=v_draft.guest_owner_id
      AND plant_id IS NULL AND state='ready' AND deleted_at IS NULL
      AND original_key=v_draft.source_storage_key
    FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'DRAFT_EXPIRED' USING ERRCODE='P0002'; END IF;
    v_destination := p_owner_id::text || '/' || v_photo.id::text;
    IF NOT p_verified_copy THEN
        v_upload := public.read_diagnosis_upload(v_photo.owner_id,v_photo.id);
        IF v_upload IS NULL THEN RAISE EXCEPTION 'DRAFT_EXPIRED' USING ERRCODE='P0002'; END IF;
        UPDATE public.draft_claims SET state='copying',commit_operation_id=p_operation_id,updated_at=v_now
        WHERE id=v_claim.id;
        RETURN jsonb_build_object('upload',v_upload,'destination',v_destination);
    END IF;
    IF v_claim.state<>'copying' OR v_claim.commit_operation_id IS DISTINCT FROM p_operation_id THEN
        RAISE EXCEPTION 'COPY_NOT_PREPARED' USING ERRCODE='22023';
    END IF;

    SELECT t.* INTO v_taxon FROM public.catalogue_taxa t
    JOIN public.catalogue_releases r ON r.id=t.release_id AND r.state='published'
    JOIN public.catalogue_release_species s ON s.release_id=r.id AND s.taxon_id=t.id
      AND s.status='published' AND s.rank IN ('species','hybrid')
    WHERE t.id=v_draft.confirmed_taxon_id AND t.status='published';
    IF NOT FOUND THEN RAISE EXCEPTION 'TAXON_NOT_PUBLISHED' USING ERRCODE='22023'; END IF;
    SELECT coalesce(nullif(v_taxon.common_names->p.preferred_locale->0->>'name',''),v_taxon.accepted_scientific_name)
    INTO v_name FROM public.profiles p WHERE p.id=p_owner_id;
    v_ts := public.advance_owner_watermark(p_owner_id);
    INSERT INTO public.plants(owner_id,taxon_id,plant_id,personal_name,display_name,main_photo_id,
      origin_draft_id,origin_flow_id,creation_source,creation_intent,add_method,created_at,updated_at)
    VALUES(p_owner_id,v_taxon.id,v_taxon.plant_id,v_name,v_name,v_photo.id,
      v_draft.id,v_draft.flow_id,'guest_claim','care','scan',v_ts,v_ts) RETURNING id INTO v_plant;
    UPDATE public.photo_assets SET owner_id=p_owner_id,plant_id=v_plant,draft_id=NULL,
      original_key=v_destination,analysis_key=v_destination,updated_at=v_ts WHERE id=v_photo.id;
    UPDATE public.guest_drafts SET claimed_at=v_ts,updated_at=v_ts WHERE id=v_draft.id;
    UPDATE public.diagnosis_job_runtime r SET projection=NULL FROM public.analysis_jobs j
    WHERE r.job_id=j.id AND j.owner_id=v_draft.guest_owner_id AND j.mode='identification'
      AND j.photo_ids[1]=v_photo.id;
    UPDATE public.draft_claims SET state='published',result_plant_id=v_plant,updated_at=v_ts WHERE id=v_claim.id;

    v_plan := CASE WHEN v_taxon.care_profile_available OR EXISTS (
      SELECT 1 FROM public.care_profiles cp JOIN public.kb_releases kr
        ON kr.id=cp.kb_release_id AND kr.state='published'
      WHERE cp.taxon_id=v_taxon.id AND cp.state='published'
    ) THEN 'available' ELSE 'care_profile_unavailable' END;
    v_next := public.compute_next_available_step(p_owner_id,v_plant,'care',false,v_plan,v_now);
    v_result := jsonb_build_object('plant_id',v_plant,'photo_id',v_photo.id,'care_revision',1,
      'context_state','current','next_available_step',v_next->>'next_available_step',
      'paid_action',v_next->'paid_action','plan_availability',v_next->>'plan_availability','watermark',v_ts);
    INSERT INTO public.operation_receipts(owner_id,operation_id,command_name,payload_hash,response_payload,committed_at)
    VALUES(p_owner_id,p_operation_id,'claim.commit',v_hash,v_result,v_ts);
    RETURN jsonb_build_object('receipt',v_result,'cleanup_draft_id',v_draft.id);
END;
$$;

CREATE FUNCTION public.delete_guest_photo_draft(p_owner_id UUID, p_draft_id UUID, p_credential_hash TEXT)
RETURNS BOOLEAN LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
    UPDATE public.guest_drafts d SET deleted_at=coalesce(d.deleted_at,clock_timestamp()),updated_at=clock_timestamp()
    FROM public.profiles p, public.installation_access i
    WHERE d.id=p_draft_id AND d.guest_owner_id=p_owner_id AND d.claimed_at IS NULL
      AND p.id=p_owner_id AND p.anonymous AND p.account_state='active'
      AND i.id=d.installation_id AND i.credential_hash=p_credential_hash
      AND p_owner_id=ANY(i.linked_owner_ids);
    RETURN FOUND;
END;
$$;

CREATE FUNCTION public.read_guest_photo_cleanup(p_draft_id UUID DEFAULT NULL)
RETURNS JSONB LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $$
    SELECT coalesce(jsonb_agg(work.entry),'[]'::jsonb) FROM (
        SELECT jsonb_build_object('draft_id',g.id,'source_photo_id',NULL,'source',g.source_storage_key,
            'abandoned_target',CASE WHEN g.claimed_at IS NULL AND c.state='copying'
                THEN c.target_owner_id::text || '/' || g.photo_id::text END) AS entry,
            g.expires_at
        FROM public.guest_drafts g
        LEFT JOIN LATERAL (
            SELECT c.state,c.target_owner_id FROM public.draft_claims c WHERE c.draft_id=g.id
            ORDER BY c.created_at,c.id LIMIT 1
        ) c ON true
        WHERE g.installation_id IS NOT NULL AND g.storage_cleaned_at IS NULL
          AND (p_draft_id IS NULL OR g.id=p_draft_id)
          AND (g.claimed_at IS NOT NULL OR g.deleted_at IS NOT NULL OR g.expires_at<=clock_timestamp())
          AND NOT EXISTS (SELECT 1 FROM public.draft_claims c WHERE c.draft_id=g.id AND c.state='copying'
            AND c.updated_at+interval '15 minutes'>clock_timestamp())
        UNION ALL
        SELECT jsonb_build_object('draft_id',NULL,'source_photo_id',a.id,'source',a.original_key,
            'abandoned_target',NULL),s.expires_at
        FROM public.guest_identification_sources s JOIN public.photo_assets a ON a.id=s.photo_id
        WHERE p_draft_id IS NULL AND s.storage_cleaned_at IS NULL AND s.expires_at<=clock_timestamp()
          AND a.draft_id IS NULL AND a.plant_id IS NULL AND a.state='ready' AND a.deleted_at IS NULL
        ORDER BY expires_at LIMIT 20
    ) work
$$;

CREATE FUNCTION public.finish_guest_source_cleanup(p_photo_id UUID)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
    UPDATE public.photo_assets a SET state='deleted',deleted_at=clock_timestamp(),updated_at=clock_timestamp()
    WHERE a.id=p_photo_id AND a.draft_id IS NULL AND a.plant_id IS NULL AND a.deleted_at IS NULL
      AND EXISTS (SELECT 1 FROM public.guest_identification_sources s
        WHERE s.photo_id=a.id AND s.expires_at<=clock_timestamp());
    IF FOUND THEN
        UPDATE public.guest_identification_sources SET storage_cleaned_at=clock_timestamp() WHERE photo_id=p_photo_id;
        UPDATE public.diagnosis_job_runtime r SET projection=NULL
        FROM public.analysis_jobs j JOIN public.photo_assets a ON a.id=j.photo_ids[1] AND a.owner_id=j.owner_id
        WHERE r.job_id=j.id AND a.id=p_photo_id AND j.mode='identification';
    END IF;
END;
$$;

CREATE FUNCTION public.finish_guest_photo_cleanup(p_draft_id UUID)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_draft public.guest_drafts%ROWTYPE;
BEGIN
    SELECT * INTO v_draft FROM public.guest_drafts WHERE id=p_draft_id FOR UPDATE;
    IF NOT FOUND OR v_draft.installation_id IS NULL OR v_draft.storage_cleaned_at IS NOT NULL THEN RETURN; END IF;
    IF v_draft.claimed_at IS NULL AND v_draft.deleted_at IS NULL AND v_draft.expires_at>clock_timestamp() THEN
        RETURN;
    END IF;
    IF v_draft.claimed_at IS NULL THEN
        UPDATE public.photo_assets SET state='deleted',deleted_at=clock_timestamp(),updated_at=clock_timestamp()
        WHERE id=v_draft.photo_id AND draft_id=v_draft.id AND owner_id=v_draft.guest_owner_id AND plant_id IS NULL;
        UPDATE public.diagnosis_job_runtime r SET projection=NULL FROM public.analysis_jobs j
        WHERE r.job_id=j.id AND j.owner_id=v_draft.guest_owner_id AND j.mode='identification'
          AND j.photo_ids[1]=v_draft.photo_id;
    END IF;
    UPDATE public.guest_drafts SET storage_cleaned_at=clock_timestamp() WHERE id=v_draft.id;
END;
$$;

REVOKE ALL ON FUNCTION public.create_guest_photo_draft(UUID,UUID,UUID,UUID,TEXT),
    public.prepare_guest_photo_claim(UUID,UUID,UUID,TEXT),
    public.process_guest_photo_claim(UUID,UUID,UUID,TEXT,BOOLEAN),
    public.delete_guest_photo_draft(UUID,UUID,TEXT),public.read_guest_photo_cleanup(UUID),
    public.finish_guest_photo_cleanup(UUID),public.finish_guest_source_cleanup(UUID) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.create_guest_photo_draft(UUID,UUID,UUID,UUID,TEXT),
    public.prepare_guest_photo_claim(UUID,UUID,UUID,TEXT),
    public.process_guest_photo_claim(UUID,UUID,UUID,TEXT,BOOLEAN),
    public.delete_guest_photo_draft(UUID,UUID,TEXT),public.read_guest_photo_cleanup(UUID),
    public.finish_guest_photo_cleanup(UUID),public.finish_guest_source_cleanup(UUID) TO service_role;

CREATE FUNCTION public.read_guest_photo_claim(p_owner_id UUID, p_claim_id UUID, p_credential_hash TEXT)
RETURNS JSONB LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $$
    SELECT jsonb_build_object('claim_id',c.id,'draft_id',d.id,'state',c.state,
        'proof_expires_at',c.expires_at,'result',r.response_payload)
    FROM public.draft_claims c
    JOIN public.guest_drafts d ON d.id=c.draft_id
    JOIN public.installation_access i ON i.id=d.installation_id
    JOIN public.profiles p ON p.id=c.target_owner_id
    LEFT JOIN public.operation_receipts r ON r.owner_id=p_owner_id AND r.operation_id=c.commit_operation_id
      AND r.command_name='claim.commit'
    WHERE c.id=p_claim_id AND c.target_owner_id=p_owner_id AND p.account_state='active' AND NOT p.anonymous
      AND c.proof_hash=p_credential_hash AND i.credential_hash=p_credential_hash AND p_owner_id=ANY(i.linked_owner_ids)
      AND (r.operation_id IS NOT NULL OR (d.deleted_at IS NULL AND d.expires_at>clock_timestamp()))
$$;

REVOKE ALL ON FUNCTION public.read_guest_photo_claim(UUID,UUID,TEXT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.read_guest_photo_claim(UUID,UUID,TEXT) TO service_role;

COMMIT;
