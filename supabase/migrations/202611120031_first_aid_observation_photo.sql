BEGIN;

-- Separate ticket membership keeps care photos outside diagnosis and guest claim.
CREATE TABLE public.first_aid_photo_upload_tickets (
    photo_asset_id UUID PRIMARY KEY REFERENCES public.photo_assets(id) ON DELETE CASCADE,
    control_id UUID NOT NULL REFERENCES public.first_aid_followups(id) ON DELETE CASCADE,
    mime_type TEXT NOT NULL CHECK (mime_type IN ('image/jpeg', 'image/png', 'image/webp')),
    byte_size INTEGER NOT NULL CHECK (byte_size BETWEEN 1 AND 10485760),
    expires_at TIMESTAMPTZ NOT NULL
);
ALTER TABLE public.first_aid_photo_upload_tickets ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.first_aid_photo_upload_tickets FROM PUBLIC, anon, authenticated, service_role;
CREATE INDEX first_aid_photo_tickets_by_control ON public.first_aid_photo_upload_tickets(control_id);
CREATE UNIQUE INDEX care_observations_one_control_per_photo ON public.care_observations(photo_id)
    WHERE first_aid_control_id IS NOT NULL AND photo_id IS NOT NULL;

CREATE FUNCTION public.read_first_aid_photo_upload(p_owner_id UUID, p_photo_asset_id UUID)
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
    WHERE a.id = p_photo_asset_id AND a.owner_id = p_owner_id
        AND p.account_state = 'active' AND NOT p.anonymous
        AND a.purpose = 'diary' AND a.analysis_key IS NULL AND a.draft_id IS NULL
        AND a.deleted_at IS NULL AND a.state IN ('initialized', 'ready')
$$;

CREATE FUNCTION public.create_first_aid_photo_upload(
    p_owner_id UUID, p_operation_id UUID, p_plant_id UUID, p_control_id UUID,
    p_mime_type TEXT, p_byte_size INTEGER, p_content_sha256 TEXT
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
    v_receipt public.operation_receipts%ROWTYPE;
    v_state TEXT;
    v_asset UUID;
    v_key TEXT;
    v_hash TEXT;
    v_has_entitlement BOOLEAN;
BEGIN
    IF p_operation_id IS NULL OR p_plant_id IS NULL OR p_control_id IS NULL
        OR p_mime_type IS NULL OR p_mime_type NOT IN ('image/jpeg', 'image/png', 'image/webp')
        OR p_byte_size IS NULL OR p_byte_size NOT BETWEEN 1 AND 10485760
        OR p_content_sha256 IS NULL OR p_content_sha256 !~ '^[a-f0-9]{64}$' THEN
        RAISE EXCEPTION 'INVALID_PHOTO_INPUT' USING ERRCODE = '22023';
    END IF;
    PERFORM 1 FROM public.profiles WHERE id = p_owner_id AND account_state = 'active' AND NOT anonymous FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'ACTIVE_PERMANENT_OWNER_REQUIRED' USING ERRCODE = '42501'; END IF;

    v_hash := encode(sha256(convert_to(jsonb_build_array(
        p_plant_id, p_control_id, p_mime_type, p_byte_size, p_content_sha256)::text, 'UTF8')), 'hex');
    SELECT * INTO v_receipt FROM public.operation_receipts WHERE owner_id = p_owner_id AND operation_id = p_operation_id;
    IF FOUND THEN
        IF v_receipt.command_name <> 'media.first-aid.upload-ticket' OR v_receipt.payload_hash <> v_hash THEN
            RAISE EXCEPTION 'IDEMPOTENCY_CONFLICT' USING ERRCODE = '23505';
        END IF;
        RETURN public.read_first_aid_photo_upload(p_owner_id, (v_receipt.response_payload->>'photo_asset_id')::uuid);
    END IF;

    PERFORM 1 FROM public.plants WHERE id = p_plant_id AND owner_id = p_owner_id AND deleted_at IS NULL FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'PLANT_NOT_FOUND' USING ERRCODE = 'P0002'; END IF;
    SELECT state INTO v_state FROM public.first_aid_followups
    WHERE id = p_control_id AND plant_id = p_plant_id AND owner_id = p_owner_id AND deleted_at IS NULL
    FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'FIRST_AID_CONTROL_NOT_FOUND' USING ERRCODE = 'P0002'; END IF;
    IF v_state <> 'active' THEN RAISE EXCEPTION 'FIRST_AID_CONTROL_INACTIVE' USING ERRCODE = '23505'; END IF;

    PERFORM 1 FROM public.entitlements WHERE owner_id = p_owner_id FOR SHARE;
    v_has_entitlement := FOUND;
    IF v_has_entitlement AND NOT public.has_verified_paid_access(p_owner_id, clock_timestamp()) THEN
        RAISE EXCEPTION 'FIRST_AID_CONTROL_EXPIRED' USING ERRCODE = '23505';
    END IF;

    v_asset := gen_random_uuid();
    v_key := p_owner_id::text || '/' || v_asset::text;
    INSERT INTO public.photo_assets(id, owner_id, purpose, original_key, content_hash)
    VALUES(v_asset, p_owner_id, 'diary', v_key, p_content_sha256);
    INSERT INTO public.first_aid_photo_upload_tickets(photo_asset_id, control_id, mime_type, byte_size, expires_at)
    VALUES(v_asset, p_control_id, p_mime_type, p_byte_size, clock_timestamp() + interval '60 seconds');
    INSERT INTO public.operation_receipts(owner_id, operation_id, command_name, payload_hash, response_payload)
    VALUES(p_owner_id, p_operation_id, 'media.first-aid.upload-ticket', v_hash, jsonb_build_object('photo_asset_id', v_asset));
    RETURN public.read_first_aid_photo_upload(p_owner_id, v_asset);
END;
$$;

-- The media handler verifies immutable Storage bytes before calling this function.
CREATE FUNCTION public.mark_first_aid_photo_ready(p_owner_id UUID, p_photo_asset_id UUID, p_content_sha256 TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
    PERFORM 1 FROM public.profiles WHERE id = p_owner_id AND account_state = 'active' AND NOT anonymous FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'ACTIVE_PERMANENT_OWNER_REQUIRED' USING ERRCODE = '42501'; END IF;
    UPDATE public.photo_assets a
    SET state = 'ready', uploaded_at = clock_timestamp(), updated_at = clock_timestamp()
    WHERE a.id = p_photo_asset_id AND a.owner_id = p_owner_id AND a.deleted_at IS NULL
        AND a.state = 'initialized' AND a.content_hash = p_content_sha256
        AND EXISTS (SELECT 1 FROM public.first_aid_photo_upload_tickets t WHERE t.photo_asset_id = a.id);
    IF NOT EXISTS (
        SELECT 1 FROM public.photo_assets a JOIN public.first_aid_photo_upload_tickets t ON t.photo_asset_id = a.id
        WHERE a.id = p_photo_asset_id AND a.owner_id = p_owner_id AND a.deleted_at IS NULL
            AND a.content_hash = p_content_sha256 AND a.state = 'ready'
    ) THEN RAISE EXCEPTION 'PHOTO_NOT_FOUND' USING ERRCODE = 'P0002'; END IF;
    RETURN public.read_first_aid_photo_upload(p_owner_id, p_photo_asset_id);
END;
$$;

CREATE FUNCTION public.read_owned_first_aid_observation_photo(p_owner_id UUID, p_observation_id UUID)
RETURNS JSONB LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $$
    SELECT public.read_first_aid_photo_upload(p_owner_id, a.id)
    FROM public.care_observations o
    JOIN public.plants p ON p.id = o.plant_id AND p.owner_id = o.owner_id AND p.deleted_at IS NULL
    JOIN public.first_aid_followups f ON f.id = o.first_aid_control_id AND f.owner_id = o.owner_id
        AND f.plant_id = o.plant_id AND f.state = 'completed' AND f.deleted_at IS NULL
    JOIN public.photo_assets a ON a.id = o.photo_id AND a.owner_id = o.owner_id AND a.plant_id = o.plant_id
    JOIN public.first_aid_photo_upload_tickets t ON t.photo_asset_id = a.id AND t.control_id = o.first_aid_control_id
    WHERE o.id = p_observation_id AND o.owner_id = p_owner_id AND o.deleted_at IS NULL
        AND a.state = 'ready' AND a.deleted_at IS NULL
$$;

REVOKE ALL ON FUNCTION public.read_first_aid_photo_upload(UUID, UUID),
    public.create_first_aid_photo_upload(UUID, UUID, UUID, UUID, TEXT, INTEGER, TEXT),
    public.mark_first_aid_photo_ready(UUID, UUID, TEXT),
    public.read_owned_first_aid_observation_photo(UUID, UUID) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.read_first_aid_photo_upload(UUID, UUID),
    public.create_first_aid_photo_upload(UUID, UUID, UUID, UUID, TEXT, INTEGER, TEXT),
    public.mark_first_aid_photo_ready(UUID, UUID, TEXT),
    public.read_owned_first_aid_observation_photo(UUID, UUID) TO service_role;

CREATE OR REPLACE FUNCTION public.complete_first_aid_control(
    p_owner_id UUID, p_operation_id UUID, p_plant_id UUID, p_payload JSONB
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
    v_owner public.profiles%ROWTYPE;
    v_receipt public.operation_receipts%ROWTYPE;
    v_plant public.plants%ROWTYPE;
    v_control public.first_aid_followups%ROWTYPE;
    v_hash TEXT;
    v_has_entitlement BOOLEAN;
    v_observed_at TIMESTAMPTZ;
    v_watermark TIMESTAMPTZ;
    v_observation_id UUID;
    v_photo_id UUID;
    v_photo_state TEXT;
    v_result JSONB;
BEGIN
    IF p_operation_id IS NULL OR p_plant_id IS NULL
        OR jsonb_typeof(p_payload) IS DISTINCT FROM 'object' THEN
        RAISE EXCEPTION 'INVALID_OBSERVATION_INPUT' USING ERRCODE = '22023';
    END IF;

    IF p_payload - ARRAY['control_id', 'status_code', 'photo_id'] <> '{}'::jsonb
        OR jsonb_typeof(p_payload->'control_id') IS DISTINCT FROM 'string'
        OR (p_payload ? 'photo_id' AND jsonb_typeof(p_payload->'photo_id') <> 'string')
        OR coalesce(p_payload->>'status_code', '') NOT IN ('improved', 'unchanged', 'worse', 'unknown') THEN
        RAISE EXCEPTION 'INVALID_OBSERVATION_INPUT' USING ERRCODE = '22023';
    END IF;

    -- Share the owner-first lock order and receipt namespace with care.undo.
    SELECT * INTO v_owner FROM public.profiles WHERE id = p_owner_id FOR UPDATE;
    IF NOT FOUND OR v_owner.account_state <> 'active' OR v_owner.anonymous THEN
        RAISE EXCEPTION 'ACTIVE_PERMANENT_OWNER_REQUIRED' USING ERRCODE = '42501';
    END IF;

    v_hash := encode(sha256(convert_to(
        jsonb_build_array('care.first_aid.observe', p_plant_id, p_payload)::text, 'UTF8')), 'hex');
    SELECT * INTO v_receipt FROM public.operation_receipts
    WHERE owner_id = p_owner_id AND operation_id = p_operation_id;
    IF FOUND THEN
        IF v_receipt.command_name <> 'care.first_aid.observe' OR v_receipt.payload_hash <> v_hash THEN
            RAISE EXCEPTION 'IDEMPOTENCY_CONFLICT' USING ERRCODE = '23505';
        END IF;
        RETURN v_receipt.response_payload;
    END IF;

    SELECT * INTO v_plant FROM public.plants
    WHERE id = p_plant_id AND owner_id = p_owner_id AND deleted_at IS NULL
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PLANT_NOT_FOUND' USING ERRCODE = 'P0002';
    END IF;

    SELECT * INTO v_control FROM public.first_aid_followups
    WHERE id = (p_payload->>'control_id')::uuid
        AND owner_id = p_owner_id AND plant_id = p_plant_id AND deleted_at IS NULL
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'FIRST_AID_CONTROL_NOT_FOUND' USING ERRCODE = 'P0002';
    END IF;

    IF v_control.state <> 'active' OR v_control.control_task_id IS NOT NULL
        OR v_control.context_revision <> v_plant.care_revision
        OR NOT EXISTS (
            SELECT 1
            FROM public.care_entries e
            JOIN public.analysis_jobs j ON j.id = e.first_aid_job_id
                AND j.owner_id = e.owner_id AND j.plant_id = e.plant_id
            JOIN public.kb_releases k ON k.id = j.kb_release_id AND k.state = 'published'
            WHERE e.id = v_control.action_entry_id AND e.owner_id = p_owner_id
                AND e.plant_id = p_plant_id AND e.state = 'active' AND e.deleted_at IS NULL
                AND e.action_code = 'check_soil' AND e.task_id IS NULL
                AND j.mode = 'diagnosis' AND j.state = 'succeeded'
                AND j.kb_release_id = v_control.kb_release_id
                AND j.snapshot_id IS NOT DISTINCT FROM v_plant.current_condition_snapshot_id
        ) THEN
        RAISE EXCEPTION 'FIRST_AID_CONTROL_INACTIVE' USING ERRCODE = '23505';
    END IF;

    IF p_payload ? 'photo_id' THEN
        v_photo_id := (p_payload->>'photo_id')::uuid;
        SELECT a.state INTO v_photo_state
        FROM public.photo_assets a
        JOIN public.first_aid_photo_upload_tickets t ON t.photo_asset_id = a.id
        WHERE a.id = v_photo_id AND a.owner_id = p_owner_id
            AND a.plant_id IS NULL AND a.draft_id IS NULL
            AND a.deleted_at IS NULL AND a.purpose = 'diary' AND a.analysis_key IS NULL
            AND t.control_id = v_control.id
        FOR UPDATE OF a;
        IF NOT FOUND THEN RAISE EXCEPTION 'PHOTO_NOT_FOUND' USING ERRCODE = 'P0002'; END IF;
        IF v_photo_state <> 'ready' THEN
            RAISE EXCEPTION 'PHOTO_NOT_READY' USING ERRCODE = '23505';
        END IF;
    END IF;

    -- Evaluate expiry after waiting for the owner, control and any entitlement update.
    PERFORM 1 FROM public.entitlements WHERE owner_id = p_owner_id FOR SHARE;
    v_has_entitlement := FOUND;
    v_observed_at := clock_timestamp();
    IF v_has_entitlement AND NOT public.has_verified_paid_access(p_owner_id, v_observed_at) THEN
        RAISE EXCEPTION 'FIRST_AID_CONTROL_EXPIRED' USING ERRCODE = '23505';
    END IF;

    v_watermark := public.advance_owner_watermark(p_owner_id);
    IF v_photo_id IS NOT NULL THEN
        UPDATE public.photo_assets SET plant_id = p_plant_id, updated_at = v_watermark
        WHERE id = v_photo_id;
    END IF;
    INSERT INTO public.care_observations(
        owner_id, plant_id, first_aid_control_id, photo_id, status_code, observed_at, operation_id, updated_at
    ) VALUES (
        p_owner_id, p_plant_id, v_control.id, v_photo_id, p_payload->>'status_code', v_observed_at, p_operation_id, v_watermark
    ) RETURNING id INTO v_observation_id;
    UPDATE public.first_aid_followups
    SET state = 'completed', updated_at = v_watermark WHERE id = v_control.id;

    v_result := jsonb_build_object('plant_id', p_plant_id, 'control_id', v_control.id,
        'observation_id', v_observation_id, 'state', 'completed', 'watermark', v_watermark);
    INSERT INTO public.operation_receipts(owner_id, operation_id, command_name, payload_hash, response_payload)
    VALUES (p_owner_id, p_operation_id, 'care.first_aid.observe', v_hash, v_result);
    RETURN v_result;
END;
$$;

COMMIT;
