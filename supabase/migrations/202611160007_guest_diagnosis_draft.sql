BEGIN;

-- Service persistence is the trust boundary for resolver signatures. Check the
-- signed envelope against the persisted projection and authoritative catalogue.
-- No signing secret or client-supplied taxon enters this SQL path.
CREATE FUNCTION public._bound_guest_diagnosis_taxon(p_job_id UUID)
RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
    v_projection JSONB;
    v_taxon UUID;
    v_signed JSONB;
BEGIN
    SELECT r.projection, s.taxon_id INTO v_projection, v_taxon
    FROM public.analysis_jobs j
    JOIN public.diagnosis_job_runtime r ON r.job_id=j.id
    JOIN public.profiles p ON p.id=j.owner_id AND p.anonymous
      AND p.account_state='active' AND p.starter_diagnosis_consumed
    JOIN public.installation_access i ON i.id=j.quota_installation_id
      AND j.owner_id=ANY(i.linked_owner_ids) AND i.starter_diagnosis_consumed
    JOIN public.operation_receipts o ON o.owner_id=j.owner_id AND o.operation_id=j.operation_id
    JOIN public.photo_assets a ON j.photo_ids=ARRAY[a.id] AND a.owner_id=j.owner_id
    JOIN public.diagnosis_upload_tickets t ON t.photo_asset_id=a.id
    JOIN public.catalogue_release_species s ON s.release_id=r.catalogue_release_id
      AND s.plant_id=r.projection->>'plant_id'
      AND s.status='published' AND s.rank IN ('species','hybrid')
    JOIN public.catalogue_releases c ON c.id=s.release_id AND c.state IN ('published','retired')
    JOIN public.kb_releases k ON k.id=j.kb_release_id AND k.state IN ('published','retired')
    WHERE j.id=p_job_id AND j.mode='diagnosis' AND j.state='succeeded'
      AND EXISTS (SELECT 1 FROM public.catalogue_release_species current_species
        JOIN public.catalogue_releases current_release ON current_release.id=current_species.release_id
          AND current_release.state='published'
        WHERE current_species.taxon_id=s.taxon_id AND current_species.plant_id=s.plant_id
          AND current_species.status='published' AND current_species.rank IN ('species','hybrid'))
      AND j.quota_kind='starter_diagnosis' AND j.quota_state='consumed'
      AND j.quota_owner_id=j.owner_id AND j.monthly_quota_id IS NULL
      AND j.plant_id IS NULL AND j.provider_started_at IS NOT NULL AND j.lease_token IS NOT NULL
      AND a.state='ready' AND a.uploaded_at IS NOT NULL AND a.deleted_at IS NULL
      AND a.plant_id IS NULL AND a.draft_id IS NOT DISTINCT FROM j.draft_id
      AND a.original_key=j.owner_id::text || '/' || a.id::text
      AND a.analysis_key=a.original_key
      AND NOT public.plant_photo_access_revoked(j.owner_id,a.id)
      AND r.initial_context IS NOT NULL AND r.repeat_context IS NULL
      AND o.command_name='analysis.job.create' AND o.payload_hash=j.payload_hash
      AND o.response_payload->>'job_id'=j.id::text
      AND j.payload_hash IN (
        encode(sha256(convert_to(jsonb_build_array(
          'bound_guest_initial_diagnosis_v1',j.owner_id,i.id,j.mode,a.id,
          j.flow_id,j.locale,r.initial_context)::text,'UTF8')),'hex'),
        CASE WHEN j.flow_id=j.operation_id THEN
          encode(sha256(convert_to(jsonb_build_array(
            'bound_guest_initial_diagnosis_v1',j.owner_id,i.id,j.mode,a.id,
            NULL,j.locale,r.initial_context)::text,'UTF8')),'hex') END)
      AND r.projection->>'job_id'=j.id::text
      AND r.projection->>'mode'='diagnosis'
      AND r.projection->>'kb_release_id'=j.kb_release_id::text
      AND r.projection->>'locale'=j.locale
      AND r.projection->>'identification_status'='identified'
      AND r.projection->>'diagnosis_status' IN (
        'problem_detected','healthy','insufficient_data','out_of_scope')
      AND r.projection->>'analysis_id' ~
        '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      AND r.projection->>'analysis_receipt' ~ '^[A-Za-z0-9+/=[:space:]]+[.][0-9a-f]{64}$';
    IF NOT FOUND THEN RETURN NULL; END IF;
    BEGIN
        v_signed := convert_from(decode(split_part(v_projection->>'analysis_receipt','.',1),'base64'),'UTF8')::jsonb;
    EXCEPTION WHEN invalid_parameter_value OR invalid_text_representation OR character_not_in_repertoire THEN
        RETURN NULL;
    END;
    IF jsonb_typeof(v_signed) IS DISTINCT FROM 'object'
       OR v_signed->>'analysis_id' IS DISTINCT FROM v_projection->>'analysis_id'
       OR v_signed->>'kb_release_id' IS DISTINCT FROM v_projection->>'kb_release_id'
       OR v_signed->>'mode' IS DISTINCT FROM 'diagnosis'
       OR v_signed->>'plant_id' IS DISTINCT FROM v_projection->>'plant_id'
       OR NOT (v_signed ? 'selected_condition_id')
       OR v_signed->'selected_condition_id' IS DISTINCT FROM v_projection->'selected_condition_id'
       OR v_signed->'decision_revision' IS DISTINCT FROM '1'::jsonb
       OR nullif(v_signed->>'issued_at','') IS NULL THEN
        RETURN NULL;
    END IF;
    RETURN v_taxon;
END;
$$;

CREATE FUNCTION public._retain_bound_guest_diagnosis_source()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
    IF NEW.projection IS NOT NULL AND NEW.projection IS DISTINCT FROM OLD.projection
       AND public._bound_guest_diagnosis_taxon(NEW.job_id) IS NOT NULL THEN
        INSERT INTO public.guest_identification_sources(photo_id,succeeded_at,expires_at)
        SELECT j.photo_ids[1],j.updated_at,j.updated_at+interval '7 days'
        FROM public.analysis_jobs j WHERE j.id=NEW.job_id
        ON CONFLICT(photo_id) DO NOTHING;
    END IF;
    RETURN NEW;
END;
$$;

-- The finalizer settles quota before publishing projection. A trigger keeps
-- retention in that same transaction and leaves exact settlement replay intact.
CREATE TRIGGER retain_bound_guest_diagnosis_source
AFTER UPDATE OF projection ON public.diagnosis_job_runtime
FOR EACH ROW EXECUTE FUNCTION public._retain_bound_guest_diagnosis_source();

-- Upgrade eligible completed jobs without restarting their seven-day lifetime.
INSERT INTO public.guest_identification_sources(photo_id,succeeded_at,expires_at)
SELECT j.photo_ids[1],j.updated_at,j.updated_at+interval '7 days'
FROM public.analysis_jobs j JOIN public.diagnosis_job_runtime r ON r.job_id=j.id
WHERE j.mode='diagnosis' AND j.state='succeeded' AND r.initial_context IS NOT NULL
  AND public._bound_guest_diagnosis_taxon(j.id) IS NOT NULL
ON CONFLICT(photo_id) DO NOTHING;

-- Existing cleanup finalizers mark the same photo deleted before marking
-- retention/draft cleanup complete. Clear only its initial diagnosis projection.
CREATE FUNCTION public._clean_bound_guest_diagnosis_projection()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
    IF OLD.storage_cleaned_at IS NULL AND NEW.storage_cleaned_at IS NOT NULL THEN
        UPDATE public.diagnosis_job_runtime r SET projection=NULL
        FROM public.analysis_jobs j JOIN public.photo_assets a ON j.photo_ids=ARRAY[a.id]
        WHERE r.job_id=j.id AND a.id=NEW.photo_id AND a.owner_id=j.owner_id
          AND a.state='deleted' AND a.deleted_at IS NOT NULL
          AND a.plant_id IS NULL AND j.plant_id IS NULL AND j.mode='diagnosis'
          AND r.initial_context IS NOT NULL AND r.repeat_context IS NULL;
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER clean_bound_guest_diagnosis_source
AFTER UPDATE OF storage_cleaned_at ON public.guest_identification_sources
FOR EACH ROW EXECUTE FUNCTION public._clean_bound_guest_diagnosis_projection();
CREATE TRIGGER clean_bound_guest_diagnosis_draft
AFTER UPDATE OF storage_cleaned_at ON public.guest_drafts
FOR EACH ROW EXECUTE FUNCTION public._clean_bound_guest_diagnosis_projection();

CREATE FUNCTION public.create_bound_guest_diagnosis_draft(
    p_owner_id UUID, p_operation_id UUID, p_job_id UUID, p_credential_hash TEXT
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
    v_installation UUID;
    v_receipt public.operation_receipts%ROWTYPE;
    v_job public.analysis_jobs%ROWTYPE;
    v_photo public.photo_assets%ROWTYPE;
    v_draft public.guest_drafts%ROWTYPE;
    v_taxon UUID;
    v_hash TEXT;
    v_expires TIMESTAMPTZ;
    v_now TIMESTAMPTZ;
    v_result JSONB;
    v_replay BOOLEAN;
BEGIN
    IF p_operation_id IS NULL OR p_job_id IS NULL THEN
        RAISE EXCEPTION 'INVALID_DRAFT_INPUT' USING ERRCODE='22023';
    END IF;
    PERFORM 1 FROM public.profiles
    WHERE id=p_owner_id AND anonymous AND account_state='active' FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'ACTIVE_GUEST_REQUIRED' USING ERRCODE='42501'; END IF;
    SELECT id INTO v_installation FROM public.installation_access
    WHERE credential_hash=p_credential_hash AND p_owner_id=ANY(linked_owner_ids) FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'INSTALLATION_CREDENTIAL_MISMATCH' USING ERRCODE='42501'; END IF;
    v_hash := encode(sha256(convert_to(jsonb_build_array(
      'bound_guest_diagnosis_draft_v1',p_owner_id,v_installation,p_job_id)::text,'UTF8')),'hex');
    SELECT * INTO v_receipt FROM public.operation_receipts
    WHERE owner_id=p_owner_id AND operation_id=p_operation_id;
    v_replay := FOUND;
    IF v_replay AND (v_receipt.command_name <> 'draft.create' OR v_receipt.payload_hash <> v_hash) THEN
        RAISE EXCEPTION 'IDEMPOTENCY_CONFLICT' USING ERRCODE='23505';
    END IF;
    -- Replay must lock the existing draft before its photo, as cleanup does.
    -- The no-draft path retains worker admission's photo -> job order.
    IF v_replay THEN
        SELECT * INTO v_draft FROM public.guest_drafts
        WHERE id=(v_receipt.response_payload->>'draft_id')::uuid
          AND guest_owner_id=p_owner_id AND installation_id=v_installation
          AND analysis_job_id=p_job_id
        FOR UPDATE;
        -- Check the row returned after any lock wait with a fresh clock.
        IF NOT FOUND OR v_draft.expires_at<=clock_timestamp()
          OR v_draft.deleted_at IS NOT NULL OR v_draft.claimed_at IS NOT NULL
          OR v_draft.storage_cleaned_at IS NOT NULL THEN
            RAISE EXCEPTION 'DRAFT_EXPIRED' USING ERRCODE='P0002';
        END IF;
    END IF;
    SELECT a.* INTO v_photo FROM public.photo_assets a
    JOIN public.analysis_jobs j ON j.photo_ids=ARRAY[a.id]
    WHERE j.id=p_job_id AND j.owner_id=p_owner_id AND j.quota_installation_id=v_installation
      AND a.owner_id=p_owner_id FOR UPDATE OF a;
    IF NOT FOUND THEN RAISE EXCEPTION 'DIAGNOSIS_SOURCE_NOT_FOUND' USING ERRCODE='P0002'; END IF;
    SELECT * INTO v_job FROM public.analysis_jobs WHERE id=p_job_id FOR UPDATE;
    v_taxon := public._bound_guest_diagnosis_taxon(p_job_id);
    IF v_taxon IS NULL THEN RAISE EXCEPTION 'DIAGNOSIS_SOURCE_NOT_FOUND' USING ERRCODE='P0002'; END IF;
    SELECT expires_at INTO v_expires FROM public.guest_identification_sources
    WHERE photo_id=v_photo.id AND storage_cleaned_at IS NULL FOR UPDATE;
    v_now := clock_timestamp();
    IF NOT FOUND OR v_expires<=v_now THEN RAISE EXCEPTION 'DRAFT_EXPIRED' USING ERRCODE='P0002'; END IF;
    IF v_replay THEN
        -- Already locked: revalidate exact scope and TTL after all later waits.
        SELECT * INTO v_draft FROM public.guest_drafts
        WHERE id=(v_receipt.response_payload->>'draft_id')::uuid
          AND guest_owner_id=p_owner_id AND installation_id=v_installation
          AND analysis_job_id=p_job_id AND photo_id=v_photo.id
          AND confirmed_taxon_id=v_taxon AND intent='problem' AND add_method='scan'
          AND source_storage_key=v_photo.original_key
          AND id=v_photo.draft_id AND id=v_job.draft_id
          AND expires_at=v_expires AND expires_at>v_now
          AND deleted_at IS NULL AND claimed_at IS NULL AND storage_cleaned_at IS NULL;
        IF NOT FOUND THEN RAISE EXCEPTION 'DRAFT_EXPIRED' USING ERRCODE='P0002'; END IF;
        RETURN v_receipt.response_payload;
    END IF;
    IF v_photo.draft_id IS NOT NULL OR v_job.draft_id IS NOT NULL THEN
        RAISE EXCEPTION 'DRAFT_ALREADY_EXISTS' USING ERRCODE='23505';
    END IF;
    INSERT INTO public.guest_drafts(
      guest_owner_id,flow_id,intent,add_method,photo_id,analysis_job_id,expires_at,
      created_at,updated_at,confirmed_taxon_id,installation_id,source_storage_key
    ) VALUES (
      p_owner_id,v_job.flow_id,'problem','scan',v_photo.id,p_job_id,v_expires,
      v_now,v_now,v_taxon,v_installation,v_photo.original_key
    ) RETURNING * INTO v_draft;
    UPDATE public.photo_assets SET draft_id=v_draft.id,updated_at=v_now WHERE id=v_photo.id;
    UPDATE public.analysis_jobs SET draft_id=v_draft.id WHERE id=p_job_id;
    v_result := jsonb_build_object('draft_id',v_draft.id,'expires_at',v_draft.expires_at);
    INSERT INTO public.operation_receipts(owner_id,operation_id,command_name,payload_hash,response_payload)
    VALUES(p_owner_id,p_operation_id,'draft.create',v_hash,v_result);
    RETURN v_result;
END;
$$;

REVOKE ALL ON FUNCTION public._bound_guest_diagnosis_taxon(UUID),
    public._retain_bound_guest_diagnosis_source(),
    public._clean_bound_guest_diagnosis_projection()
FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.create_bound_guest_diagnosis_draft(UUID,UUID,UUID,TEXT)
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.create_bound_guest_diagnosis_draft(UUID,UUID,UUID,TEXT)
TO service_role;

COMMIT;
