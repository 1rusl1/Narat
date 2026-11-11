BEGIN;

DO $$
BEGIN
    IF to_regclass('storage.buckets') IS NOT NULL THEN
        INSERT INTO storage.buckets(id, name, public, file_size_limit, allowed_mime_types)
        VALUES ('analysis-inputs', 'analysis-inputs', false, 10485760,
                ARRAY['image/jpeg', 'image/png', 'image/webp'])
        ON CONFLICT (id) DO NOTHING;
        IF EXISTS (SELECT 1 FROM storage.buckets WHERE id = 'analysis-inputs' AND public) THEN
            RAISE EXCEPTION 'ANALYSIS_BUCKET_MUST_BE_PRIVATE';
        END IF;
    END IF;
END;
$$;

CREATE TABLE public.diagnosis_upload_tickets (
    photo_asset_id UUID PRIMARY KEY REFERENCES public.photo_assets(id) ON DELETE CASCADE,
    mime_type TEXT NOT NULL CHECK (mime_type IN ('image/jpeg', 'image/png', 'image/webp')),
    byte_size INTEGER NOT NULL CHECK (byte_size BETWEEN 1 AND 10485760),
    expires_at TIMESTAMPTZ NOT NULL
);
ALTER TABLE public.diagnosis_upload_tickets ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.diagnosis_upload_tickets FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION public.read_diagnosis_upload(p_owner_id UUID, p_photo_asset_id UUID)
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
      AND p.account_state = 'active' AND NOT p.anonymous
      AND a.deleted_at IS NULL AND a.state IN ('initialized', 'ready')
$$;

CREATE FUNCTION public.create_diagnosis_upload(
    p_owner_id UUID, p_operation_id UUID, p_mime_type TEXT, p_byte_size INTEGER, p_content_sha256 TEXT
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
    IF NOT FOUND OR v_profile.account_state <> 'active' OR v_profile.anonymous THEN
        RAISE EXCEPTION 'ACTIVE_PERMANENT_OWNER_REQUIRED' USING ERRCODE = '42501';
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

-- Called by the server after verifying immutable bytes in private Storage.
CREATE FUNCTION public.mark_diagnosis_upload_ready(p_owner_id UUID, p_photo_asset_id UUID, p_content_sha256 TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
    PERFORM 1 FROM public.profiles
    WHERE id = p_owner_id AND account_state = 'active' AND NOT anonymous FOR UPDATE;
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

REVOKE ALL ON FUNCTION public.read_diagnosis_upload(UUID, UUID),
    public.create_diagnosis_upload(UUID, UUID, TEXT, INTEGER, TEXT),
    public.mark_diagnosis_upload_ready(UUID, UUID, TEXT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.read_diagnosis_upload(UUID, UUID),
    public.create_diagnosis_upload(UUID, UUID, TEXT, INTEGER, TEXT),
    public.mark_diagnosis_upload_ready(UUID, UUID, TEXT) TO service_role;

COMMIT;
