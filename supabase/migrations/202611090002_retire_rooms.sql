CREATE OR REPLACE FUNCTION public.execute_plant_create_command(
  p_owner_id UUID,
  p_operation_id UUID,
  p_payload JSONB,
  p_now TIMESTAMPTZ DEFAULT now()
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_ts TIMESTAMPTZ;
  v_payload_hash TEXT;
  v_cached JSONB;
  v_creation_source TEXT;
  v_intent TEXT;
  v_add_method TEXT;
  v_origin_draft_id UUID := NULL;
  v_origin_flow_id UUID := NULL;
  v_orig_plant_id TEXT;
  v_final_plant_id TEXT;
  v_final_taxon_id UUID;
  v_final_display_name TEXT;
  v_overrides JSONB;
  v_conditions JSONB;
  v_orig_light_level TEXT;
  v_orig_light_source TEXT;
  v_orig_light_confirmed BOOLEAN;
  v_orig_watering TEXT;
  v_orig_last_watered TEXT;
  v_orig_pot_type TEXT;
  v_orig_season TEXT;
  v_final_light_level TEXT;
  v_final_light_source TEXT;
  v_final_light_confirmed BOOLEAN;
  v_final_watering TEXT;
  v_final_last_watered TEXT;
  v_final_pot_type TEXT;
  v_final_season TEXT;
  v_species_or_conditions_changed BOOLEAN := FALSE;
  v_care_revision INT := 1;
  v_context_state TEXT := 'current';
  v_new_plant_uuid UUID;
  v_snap1_id UUID;
  v_snap2_id UUID;
  v_current_snap_id UUID;
  v_analysis_receipt TEXT;
  v_kb_release_id UUID;
  v_analysis_mode TEXT;
  v_has_diagnosis BOOLEAN := FALSE;
  v_plan_availability TEXT := 'available';
  v_next_step JSONB;
  v_response JSONB;
BEGIN
  v_ts := public.advance_owner_watermark(p_owner_id);

  v_payload_hash := encode(
    digest('plant.create:' || COALESCE(p_payload::TEXT, '{}'), 'sha256'),
    'hex'
  );

  SELECT r.response_payload INTO v_cached
  FROM public.operation_receipts r
  WHERE r.owner_id = p_owner_id
    AND r.operation_id = p_operation_id
    AND r.command_name = 'plant.create'
    AND r.payload_hash = v_payload_hash;

  IF v_cached IS NOT NULL THEN
    RETURN v_cached;
  END IF;

  IF COALESCE(p_payload, '{}'::jsonb) ?| ARRAY['room_id', 'new_room_name', 'create_room_name'] THEN
    RAISE EXCEPTION 'ROOM_FIELDS_RETIRED' USING ERRCODE = '22023';
  END IF;

  IF COALESCE(p_payload->'overrides', '{}'::jsonb) ?| ARRAY['room_id', 'new_room_name', 'create_room_name'] THEN
    RAISE EXCEPTION 'ROOM_FIELDS_RETIRED' USING ERRCODE = '22023';
  END IF;

  v_creation_source := COALESCE(p_payload->>'creation_source', 'catalogue');
  v_intent := COALESCE(p_payload->>'creation_intent', 'care');
  v_add_method := COALESCE(p_payload->>'add_method', CASE WHEN v_creation_source = 'catalogue' THEN 'catalogue' ELSE 'scan' END);

  IF p_payload ? 'origin_draft_id' AND p_payload->>'origin_draft_id' IS NOT NULL THEN
    v_origin_draft_id := (p_payload->>'origin_draft_id')::UUID;
  END IF;

  IF p_payload ? 'origin_flow_id' AND p_payload->>'origin_flow_id' IS NOT NULL THEN
    v_origin_flow_id := (p_payload->>'origin_flow_id')::UUID;
  END IF;

  IF v_creation_source = 'local_fallback' THEN
    IF v_origin_draft_id IS NULL THEN
      RAISE EXCEPTION 'ORIGIN_DRAFT_ID_REQUIRED_FOR_FALLBACK';
    END IF;
    v_analysis_receipt := p_payload->>'analysis_receipt';
    IF v_analysis_receipt IS NULL OR length(trim(v_analysis_receipt)) = 0 THEN
      RAISE EXCEPTION 'SIGNED_ANALYSIS_RECEIPT_REQUIRED_FOR_FALLBACK';
    END IF;

    -- Prevent duplicate save if guest_claim already succeeded for this origin_draft_id
    IF EXISTS (
      SELECT 1 FROM public.plants
      WHERE owner_id = p_owner_id AND origin_draft_id = v_origin_draft_id
    ) THEN
      RAISE EXCEPTION 'DRAFT_ALREADY_SAVED';
    END IF;
  END IF;

  v_overrides := COALESCE(p_payload->'overrides', '{}'::jsonb);
  v_conditions := COALESCE(p_payload->'conditions', '{}'::jsonb);

  v_orig_plant_id := p_payload->>'plant_id';
  v_final_plant_id := COALESCE(v_overrides->>'plant_id', v_orig_plant_id);
  v_final_taxon_id := COALESCE((v_overrides->>'taxon_id')::UUID, (p_payload->>'taxon_id')::UUID);

  -- Resolve species from catalogue_taxa by taxon_id or plant_id slug within the active published catalogue_release
  IF v_final_taxon_id IS NOT NULL AND v_final_plant_id IS NULL THEN
    SELECT t.plant_id INTO v_final_plant_id
    FROM public.catalogue_taxa t
    JOIN public.catalogue_releases cr ON cr.id = t.release_id
    WHERE t.id = v_final_taxon_id
      AND t.status = 'published'
      AND cr.state = 'published';
  ELSIF v_final_plant_id IS NOT NULL AND v_final_taxon_id IS NULL THEN
    SELECT t.id INTO v_final_taxon_id
    FROM public.catalogue_taxa t
    JOIN public.catalogue_releases cr ON cr.id = t.release_id
    WHERE t.plant_id = v_final_plant_id
      AND t.status = 'published'
      AND cr.state = 'published';
  END IF;

  IF v_creation_source = 'catalogue' THEN
    IF v_final_taxon_id IS NULL OR NOT EXISTS (
      SELECT 1 FROM public.catalogue_taxa t
      JOIN public.catalogue_releases cr ON cr.id = t.release_id
      WHERE t.id = v_final_taxon_id
        AND t.status = 'published'
        AND cr.state = 'published'
    ) THEN
      RAISE EXCEPTION 'taxon_not_published' USING ERRCODE = 'P0002';
    END IF;
  END IF;

  v_final_display_name := COALESCE(
    NULLIF(trim(COALESCE(v_overrides->>'personal_name', '')), ''),
    NULLIF(trim(COALESCE(v_overrides->>'display_name', '')), ''),
    NULLIF(trim(COALESCE(p_payload->>'personal_name', '')), ''),
    NULLIF(trim(COALESCE(p_payload->>'display_name', '')), ''),
    (
      SELECT COALESCE(
        t.common_names->(SELECT COALESCE(pr.preferred_locale, 'en') FROM public.profiles pr WHERE pr.id = p_owner_id)->0->>'name',
        t.accepted_scientific_name
      )
      FROM public.catalogue_taxa t
      WHERE t.id = v_final_taxon_id
    ),
    v_final_plant_id,
    'Plant'
  );

  v_orig_light_level := COALESCE(v_conditions->>'light_level', v_conditions->>'light_code', 'unknown');
  v_orig_light_source := COALESCE(v_conditions->>'light_source', 'unknown');
  v_orig_light_confirmed := COALESCE((v_conditions->>'light_confirmed')::BOOLEAN, FALSE);
  IF v_orig_light_level = 'unknown' THEN
    v_orig_light_source := 'unknown';
    v_orig_light_confirmed := FALSE;
  END IF;
  v_orig_watering := COALESCE(v_conditions->>'watering_habit', v_conditions->>'watering_code', 'unknown');
  v_orig_last_watered := COALESCE(v_conditions->>'last_watered', v_conditions->>'drainage_code', 'unknown');
  v_orig_pot_type := COALESCE(v_conditions->>'pot_type', 'unknown');
  v_orig_season := COALESCE(v_conditions->>'season_override', 'auto');

  v_final_light_level := COALESCE(v_overrides->>'light_level', v_overrides->>'light_code', v_orig_light_level);
  v_final_light_source := COALESCE(v_overrides->>'light_source', v_orig_light_source);
  v_final_light_confirmed := COALESCE((v_overrides->>'light_confirmed')::BOOLEAN, v_orig_light_confirmed);
  IF v_final_light_level = 'unknown' THEN
    v_final_light_source := 'unknown';
    v_final_light_confirmed := FALSE;
  ELSIF v_final_light_source = 'unknown' THEN
    v_final_light_source := 'manual';
    v_final_light_confirmed := TRUE;
  END IF;
  v_final_watering := COALESCE(v_overrides->>'watering_habit', v_overrides->>'watering_code', v_orig_watering);
  v_final_last_watered := COALESCE(v_overrides->>'last_watered', v_overrides->>'drainage_code', v_orig_last_watered);
  v_final_pot_type := COALESCE(v_overrides->>'pot_type', v_orig_pot_type);
  v_final_season := COALESCE(v_overrides->>'season_override', v_orig_season);

  IF v_creation_source = 'local_fallback' THEN
    v_species_or_conditions_changed := (
      v_final_plant_id IS DISTINCT FROM v_orig_plant_id
      OR v_final_light_level IS DISTINCT FROM v_orig_light_level
      OR v_final_light_source IS DISTINCT FROM v_orig_light_source
      OR v_final_light_confirmed IS DISTINCT FROM v_orig_light_confirmed
      OR v_final_watering IS DISTINCT FROM v_orig_watering
      OR v_final_last_watered IS DISTINCT FROM v_orig_last_watered
      OR v_final_pot_type IS DISTINCT FROM v_orig_pot_type
      OR v_final_season IS DISTINCT FROM v_orig_season
    );
    IF v_species_or_conditions_changed THEN
      v_care_revision := 2;
      v_context_state := 'stale';
    END IF;
  END IF;

  INSERT INTO public.plants (
    owner_id, taxon_id, plant_id, personal_name, display_name,
    main_photo_id, origin_draft_id, origin_flow_id, creation_source, creation_intent, add_method,
    care_revision, created_at, updated_at
  ) VALUES (
    p_owner_id, v_final_taxon_id, v_final_plant_id, v_final_display_name, v_final_display_name,
    CASE WHEN p_payload ? 'photo_id' AND p_payload->>'photo_id' IS NOT NULL THEN (p_payload->>'photo_id')::UUID ELSE NULL END,
    v_origin_draft_id, v_origin_flow_id, v_creation_source, v_intent, v_add_method,
    v_care_revision, v_ts, v_ts
  )
  RETURNING id INTO v_new_plant_uuid;

  IF p_payload ? 'photo_id' AND p_payload->>'photo_id' IS NOT NULL THEN
    UPDATE public.photo_assets
    SET plant_id = v_new_plant_uuid,
        updated_at = v_ts
    WHERE id = (p_payload->>'photo_id')::UUID
      AND owner_id = p_owner_id;
  END IF;

  -- In basic catalogue save without care questions, condition_snapshots is optional (NULL)
  IF v_creation_source <> 'catalogue' OR (p_payload ? 'conditions' AND p_payload->'conditions' <> '{}'::jsonb) THEN
    INSERT INTO public.condition_snapshots (
      owner_id, plant_id, revision, light_level, light_source, light_confirmed,
      watering_habit, last_watered, pot_type, season_override, created_at, updated_at
    ) VALUES (
      p_owner_id, v_new_plant_uuid, 1, v_orig_light_level, v_orig_light_source, v_orig_light_confirmed,
      v_orig_watering, v_orig_last_watered, v_orig_pot_type, v_orig_season, v_ts, v_ts
    )
    RETURNING id INTO v_snap1_id;

    v_current_snap_id := v_snap1_id;

    IF v_species_or_conditions_changed THEN
      INSERT INTO public.condition_snapshots (
        owner_id, plant_id, revision, light_level, light_source, light_confirmed,
        watering_habit, last_watered, pot_type, season_override, created_at, updated_at
      ) VALUES (
        p_owner_id, v_new_plant_uuid, 2, v_final_light_level, v_final_light_source, v_final_light_confirmed,
        v_final_watering, v_final_last_watered, v_final_pot_type, v_final_season, v_ts, v_ts
      )
      RETURNING id INTO v_snap2_id;
      v_current_snap_id := v_snap2_id;
    END IF;

    UPDATE public.plants
    SET current_snapshot_id = v_current_snap_id,
        current_condition_snapshot_id = v_current_snap_id
    WHERE id = v_new_plant_uuid;
  END IF;

  IF v_creation_source = 'local_fallback' THEN
    v_kb_release_id := COALESCE(
      (p_payload->>'kb_release_id')::UUID,
      (SELECT id FROM public.kb_releases WHERE state = 'published' ORDER BY published_at DESC LIMIT 1)
    );
    v_analysis_mode := COALESCE(p_payload->>'analysis_mode', CASE WHEN v_intent = 'problem' THEN 'diagnosis' ELSE 'identification' END);
    v_has_diagnosis := (v_analysis_mode = 'diagnosis');
  END IF;

  IF p_payload ? 'plan_availability' AND p_payload->>'plan_availability' IS NOT NULL THEN
    v_plan_availability := p_payload->>'plan_availability';
  ELSIF v_creation_source = 'catalogue' THEN
    IF EXISTS (
      SELECT 1 FROM public.catalogue_taxa t
      WHERE t.id = v_final_taxon_id
        AND (
          t.care_profile_available = TRUE
          OR EXISTS (
            SELECT 1 FROM public.care_profiles cp
            JOIN public.kb_releases kr ON kr.id = cp.kb_release_id
            WHERE cp.taxon_id = t.id
              AND cp.state = 'published'
              AND kr.state = 'published'
          )
        )
    ) THEN
      v_plan_availability := 'available';
    ELSE
      v_plan_availability := 'care_profile_unavailable';
    END IF;
  ELSE
    v_plan_availability := 'available';
  END IF;

  v_next_step := public.compute_next_available_step(
    p_owner_id,
    v_new_plant_uuid,
    v_intent,
    v_has_diagnosis,
    v_plan_availability,
    p_now
  );

  v_response := jsonb_build_object(
    'plant_id', v_new_plant_uuid,
    'care_revision', v_care_revision,
    'context_state', v_context_state,
    'next_available_step', v_next_step->>'next_available_step',
    'paid_action', v_next_step->'paid_action',
    'plan_availability', v_next_step->>'plan_availability',
    'watermark', v_ts
  );

  INSERT INTO public.operation_receipts (
    owner_id, operation_id, command_name, payload_hash, response_payload, committed_at
  ) VALUES (
    p_owner_id, p_operation_id, 'plant.create', v_payload_hash, v_response, v_ts
  );

  RETURN v_response;
END;
$$;

CREATE OR REPLACE FUNCTION public.prepare_guest_claim(
  p_owner_id UUID,
  p_operation_id UUID,
  p_draft_id UUID,
  p_claim_secret_hash TEXT,
  p_overrides JSONB DEFAULT NULL,
  p_now TIMESTAMPTZ DEFAULT now()
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_ts TIMESTAMPTZ;
  v_draft RECORD;
  v_claim_id UUID;
BEGIN
  IF COALESCE(p_overrides, '{}'::jsonb) ?| ARRAY['room_id', 'new_room_name', 'create_room_name'] THEN
    RAISE EXCEPTION 'ROOM_FIELDS_RETIRED' USING ERRCODE = '22023';
  END IF;

  v_ts := public.advance_owner_watermark(p_owner_id);

  SELECT * INTO v_draft
  FROM public.guest_drafts gd
  WHERE gd.id = p_draft_id
    AND gd.deleted_at IS NULL
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'DRAFT_NOT_FOUND';
  END IF;

  IF v_draft.expires_at <= p_now OR v_draft.state = 'expired' THEN
    RAISE EXCEPTION 'DRAFT_EXPIRED';
  END IF;

  IF v_draft.claim_secret_hash <> p_claim_secret_hash THEN
    RAISE EXCEPTION 'INVALID_CLAIM_PROOF';
  END IF;

  INSERT INTO public.draft_claims (
    draft_id, owner_id, operation_id, state, overrides,
    proof_expires_at, created_at, updated_at
  ) VALUES (
    p_draft_id, p_owner_id, p_operation_id, 'prepared', p_overrides,
    p_now + INTERVAL '15 minutes', v_ts, v_ts
  )
  ON CONFLICT (owner_id, operation_id) DO UPDATE
  SET overrides = EXCLUDED.overrides,
      updated_at = v_ts
  RETURNING id INTO v_claim_id;

  UPDATE public.guest_drafts
  SET state = 'claiming',
      updated_at = v_ts
  WHERE id = p_draft_id;

  RETURN jsonb_build_object(
    'claim_id', v_claim_id,
    'draft_id', p_draft_id,
    'state', 'prepared',
    'proof_expires_at', p_now + INTERVAL '15 minutes'
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.commit_guest_claim(
  p_owner_id UUID,
  p_operation_id UUID,
  p_draft_id UUID,
  p_overrides JSONB DEFAULT NULL,
  p_now TIMESTAMPTZ DEFAULT now()
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_ts TIMESTAMPTZ;
  v_payload_hash TEXT;
  v_cached JSONB;
  v_draft RECORD;
  v_effective_overrides JSONB;
  v_orig_plant_id TEXT;
  v_final_plant_id TEXT;
  v_final_taxon_id UUID;
  v_final_display_name TEXT;
  v_orig_light_level TEXT;
  v_orig_light_source TEXT;
  v_orig_light_confirmed BOOLEAN;
  v_orig_watering TEXT;
  v_orig_last_watered TEXT;
  v_orig_pot_type TEXT;
  v_orig_season TEXT;
  v_final_light_level TEXT;
  v_final_light_source TEXT;
  v_final_light_confirmed BOOLEAN;
  v_final_watering TEXT;
  v_final_last_watered TEXT;
  v_final_pot_type TEXT;
  v_final_season TEXT;
  v_species_or_conditions_changed BOOLEAN := FALSE;
  v_care_revision INT := 1;
  v_context_state TEXT := 'current';
  v_new_plant_uuid UUID;
  v_snap1_id UUID;
  v_snap2_id UUID;
  v_current_snap_id UUID;
  v_has_diagnosis BOOLEAN := FALSE;
  v_plan_availability TEXT := 'available';
  v_next_step JSONB;
  v_response JSONB;
BEGIN
  v_ts := public.advance_owner_watermark(p_owner_id);

  v_payload_hash := encode(
    digest('claim.commit:' || p_draft_id::TEXT || ':' || COALESCE(p_overrides::TEXT, '{}'), 'sha256'),
    'hex'
  );

  SELECT r.response_payload INTO v_cached
  FROM public.operation_receipts r
  WHERE r.owner_id = p_owner_id
    AND r.operation_id = p_operation_id
    AND r.command_name = 'claim.commit'
    AND r.payload_hash = v_payload_hash;

  IF v_cached IS NOT NULL THEN
    RETURN v_cached;
  END IF;

  IF COALESCE(p_overrides, '{}'::jsonb) ?| ARRAY['room_id', 'new_room_name', 'create_room_name'] THEN
    RAISE EXCEPTION 'ROOM_FIELDS_RETIRED' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_draft
  FROM public.guest_drafts gd
  WHERE gd.id = p_draft_id
    AND gd.deleted_at IS NULL
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'DRAFT_NOT_FOUND';
  END IF;

  IF v_draft.expires_at <= p_now OR v_draft.state = 'expired' THEN
    RAISE EXCEPTION 'DRAFT_EXPIRED';
  END IF;

  -- Check if already claimed by this owner (race between claim and fallback)
  SELECT id INTO v_new_plant_uuid
  FROM public.plants
  WHERE owner_id = p_owner_id
    AND origin_draft_id = p_draft_id;

  IF FOUND THEN
    RAISE EXCEPTION 'DRAFT_ALREADY_SAVED';
  END IF;

  v_effective_overrides := COALESCE(
    p_overrides,
    (SELECT dc.overrides FROM public.draft_claims dc WHERE dc.draft_id = p_draft_id AND dc.owner_id = p_owner_id ORDER BY dc.updated_at DESC LIMIT 1),
    '{}'::jsonb
  );

  IF v_effective_overrides ?| ARRAY['room_id', 'new_room_name', 'create_room_name'] THEN
    RAISE EXCEPTION 'ROOM_FIELDS_RETIRED' USING ERRCODE = '22023';
  END IF;

  v_orig_plant_id := v_draft.confirmed_plant_id;
  v_final_plant_id := COALESCE(v_effective_overrides->>'plant_id', v_orig_plant_id);
  v_final_taxon_id := COALESCE((v_effective_overrides->>'taxon_id')::UUID, v_draft.confirmed_taxon_id);
  v_final_display_name := COALESCE(
    NULLIF(trim(COALESCE(v_effective_overrides->>'display_name', '')), ''),
    v_final_plant_id,
    'Plant'
  );

  v_orig_light_level := COALESCE(v_draft.conditions_payload->>'light_level', 'unknown');
  v_orig_light_source := COALESCE(v_draft.conditions_payload->>'light_source', 'unknown');
  v_orig_light_confirmed := COALESCE((v_draft.conditions_payload->>'light_confirmed')::BOOLEAN, FALSE);
  IF v_orig_light_level = 'unknown' THEN
    v_orig_light_source := 'unknown';
    v_orig_light_confirmed := FALSE;
  END IF;
  v_orig_watering := COALESCE(v_draft.conditions_payload->>'watering_habit', 'unknown');
  v_orig_last_watered := COALESCE(v_draft.conditions_payload->>'last_watered', 'unknown');
  v_orig_pot_type := COALESCE(v_draft.conditions_payload->>'pot_type', 'unknown');
  v_orig_season := COALESCE(v_draft.conditions_payload->>'season_override', 'auto');

  v_final_light_level := COALESCE(v_effective_overrides->>'light_level', v_orig_light_level);
  v_final_light_source := COALESCE(v_effective_overrides->>'light_source', v_orig_light_source);
  v_final_light_confirmed := COALESCE((v_effective_overrides->>'light_confirmed')::BOOLEAN, v_orig_light_confirmed);
  IF v_final_light_level = 'unknown' THEN
    v_final_light_source := 'unknown';
    v_final_light_confirmed := FALSE;
  ELSIF v_final_light_source = 'unknown' THEN
    v_final_light_source := 'manual';
    v_final_light_confirmed := TRUE;
  END IF;
  v_final_watering := COALESCE(v_effective_overrides->>'watering_habit', v_orig_watering);
  v_final_last_watered := COALESCE(v_effective_overrides->>'last_watered', v_orig_last_watered);
  v_final_pot_type := COALESCE(v_effective_overrides->>'pot_type', v_orig_pot_type);
  v_final_season := COALESCE(v_effective_overrides->>'season_override', v_orig_season);

  v_species_or_conditions_changed := (
    v_final_plant_id IS DISTINCT FROM v_orig_plant_id
    OR v_final_light_level IS DISTINCT FROM v_orig_light_level
    OR v_final_light_source IS DISTINCT FROM v_orig_light_source
    OR v_final_light_confirmed IS DISTINCT FROM v_orig_light_confirmed
    OR v_final_watering IS DISTINCT FROM v_orig_watering
    OR v_final_last_watered IS DISTINCT FROM v_orig_last_watered
    OR v_final_pot_type IS DISTINCT FROM v_orig_pot_type
    OR v_final_season IS DISTINCT FROM v_orig_season
  );

  IF v_species_or_conditions_changed THEN
    v_care_revision := 2;
    v_context_state := 'stale';
  ELSE
    v_care_revision := 1;
    v_context_state := 'current';
  END IF;

  INSERT INTO public.plants (
    owner_id, taxon_id, plant_id, display_name,
    origin_draft_id, origin_flow_id, creation_source, creation_intent, add_method,
    care_revision, created_at, updated_at
  ) VALUES (
    p_owner_id, v_final_taxon_id, v_final_plant_id, v_final_display_name,
    p_draft_id, v_draft.flow_id,
    CASE WHEN v_draft.intent = 'care' THEN 'identification' ELSE 'guest_claim' END,
    v_draft.intent, v_draft.add_method,
    v_care_revision, v_ts, v_ts
  )
  RETURNING id INTO v_new_plant_uuid;

  -- Always preserve initial snapshot (revision = 1)
  INSERT INTO public.condition_snapshots (
    owner_id, plant_id, revision, light_level, light_source, light_confirmed,
    watering_habit, last_watered, pot_type, season_override, created_at, updated_at
  ) VALUES (
    p_owner_id, v_new_plant_uuid, 1, v_orig_light_level, v_orig_light_source, v_orig_light_confirmed,
    v_orig_watering, v_orig_last_watered, v_orig_pot_type, v_orig_season, v_ts, v_ts
  )
  RETURNING id INTO v_snap1_id;

  v_current_snap_id := v_snap1_id;

  IF v_species_or_conditions_changed THEN
    INSERT INTO public.condition_snapshots (
      owner_id, plant_id, revision, light_level, light_source, light_confirmed,
      watering_habit, last_watered, pot_type, season_override, created_at, updated_at
    ) VALUES (
      p_owner_id, v_new_plant_uuid, 2, v_final_light_level, v_final_light_source, v_final_light_confirmed,
      v_final_watering, v_final_last_watered, v_final_pot_type, v_final_season, v_ts, v_ts
    )
    RETURNING id INTO v_snap2_id;
    v_current_snap_id := v_snap2_id;
  END IF;

  UPDATE public.plants
  SET current_snapshot_id = v_current_snap_id
  WHERE id = v_new_plant_uuid;

  -- Transfer photo_assets, analysis_jobs, analysis_results, diagnostic_decisions, and diagnostic_answers
  UPDATE public.photo_assets
  SET owner_id = p_owner_id,
      plant_id = v_new_plant_uuid,
      updated_at = v_ts
  WHERE draft_id = p_draft_id;

  UPDATE public.analysis_jobs
  SET owner_id = p_owner_id,
      plant_id = v_new_plant_uuid,
      updated_at = v_ts
  WHERE draft_id = p_draft_id;

  UPDATE public.analysis_results
  SET owner_id = p_owner_id,
      plant_id = v_new_plant_uuid,
      source_snapshot_id = v_snap1_id,
      context_state = v_context_state,
      updated_at = v_ts
  WHERE draft_id = p_draft_id;

  UPDATE public.diagnostic_decisions
  SET owner_id = p_owner_id,
      updated_at = v_ts
  WHERE analysis_id IN (SELECT id FROM public.analysis_results WHERE draft_id = p_draft_id);

  UPDATE public.diagnostic_answers
  SET owner_id = p_owner_id,
      updated_at = v_ts
  WHERE analysis_id IN (SELECT id FROM public.analysis_results WHERE draft_id = p_draft_id);

  -- Bind installation starter flags via OR and earliest success if installation_id is present
  IF v_draft.installation_id IS NOT NULL THEN
    PERFORM public.bind_installation_to_owner(v_draft.installation_id, p_owner_id, p_now);
  END IF;

  UPDATE public.guest_drafts
  SET state = 'claimed',
      claimed_by_owner_id = p_owner_id,
      claimed_at = v_ts,
      updated_at = v_ts
  WHERE id = p_draft_id;

  UPDATE public.draft_claims
  SET state = 'committed',
      committed_at = v_ts,
      updated_at = v_ts
  WHERE draft_id = p_draft_id
    AND owner_id = p_owner_id;

  SELECT EXISTS (
    SELECT 1 FROM public.analysis_results ar
    WHERE ar.draft_id = p_draft_id AND ar.mode = 'diagnosis'
  ) INTO v_has_diagnosis;

  v_next_step := public.compute_next_available_step(
    p_owner_id,
    v_new_plant_uuid,
    v_draft.intent,
    v_has_diagnosis,
    v_plan_availability,
    p_now
  );

  v_response := jsonb_build_object(
    'plant_id', v_new_plant_uuid,
    'care_revision', v_care_revision,
    'context_state', v_context_state,
    'next_available_step', v_next_step->>'next_available_step',
    'paid_action', v_next_step->'paid_action',
    'plan_availability', v_next_step->>'plan_availability',
    'watermark', v_ts
  );

  INSERT INTO public.operation_receipts (
    owner_id, operation_id, command_name, payload_hash, response_payload, committed_at
  ) VALUES (
    p_owner_id, p_operation_id, 'claim.commit', v_payload_hash, v_response, v_ts
  );

  RETURN v_response;
END;
$$;

CREATE OR REPLACE FUNCTION public.execute_room_command(
  p_owner_id UUID,
  p_operation_id UUID,
  p_command_name TEXT,
  p_payload JSONB
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_cached JSONB;
BEGIN
  IF p_command_name IS NULL OR p_command_name NOT IN ('room.create', 'room.rename', 'room.delete') THEN
    RAISE EXCEPTION 'ROOM_COMMAND_RETIRED' USING ERRCODE = '22023';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = p_owner_id AND account_state = 'active') THEN
    RAISE EXCEPTION 'account_not_active' USING ERRCODE = '42501';
  END IF;
  v_cached := public.lookup_operation_receipt(
    p_owner_id, p_operation_id, p_command_name,
    encode(digest(p_command_name || ':' || COALESCE(p_payload::TEXT, '{}'), 'sha256'), 'hex')
  );
  IF v_cached IS NOT NULL THEN
    RETURN v_cached;
  END IF;
  RAISE EXCEPTION 'ROOM_COMMAND_RETIRED' USING ERRCODE = '22023';
END;
$$;

CREATE OR REPLACE VIEW public.owner_sync_entries AS
    -- Plants (historical rooms are no longer synchronized)

    SELECT
        p.owner_id,
        'plants'::text AS entity_type,
        p.id,
        p.updated_at,
        p.deleted_at,
        CASE WHEN p.deleted_at IS NOT NULL THEN NULL ELSE jsonb_build_object(
            'id', p.id,
            'origin_flow_id', p.origin_flow_id,
            'creation_intent', p.creation_intent,
            'add_method', p.add_method,
            'personal_name', p.personal_name,
            'display_name', p.personal_name,
            'taxon_id', p.taxon_id,
            'plant_id', p.plant_id,
            'cultivar_label', p.cultivar_label,
            'main_photo_id', p.main_photo_id,
            'current_condition_snapshot_id', p.current_condition_snapshot_id,
            'origin_draft_id', p.origin_draft_id,
            'creation_source', p.creation_source,
            'revision', p.revision,
            'care_revision', p.care_revision,
            'created_at', p.created_at
        ) END AS data
    FROM public.plants p
    UNION ALL
    -- 3. condition_snapshots
    SELECT
        cs.owner_id,
        'condition_snapshots'::text AS entity_type,
        cs.id,
        cs.updated_at,
        cs.deleted_at,
        CASE WHEN cs.deleted_at IS NOT NULL THEN NULL ELSE jsonb_build_object(
            'id', cs.id,
            'plant_id', cs.plant_id,
            'version', cs.version,
            'light_code', cs.light_code,
            'light_source', cs.light_source,
            'light_confirmed', cs.light_confirmed,
            'watering_code', cs.watering_code,
            'drainage_code', cs.drainage_code,
            'pot_type', cs.pot_type,
            'season_override', cs.season_override,
            'created_at', cs.created_at
        ) END AS data
    FROM public.condition_snapshots cs
    WHERE cs.plant_id IS NOT NULL
    UNION ALL
    -- 4. photo_assets (safe metadata only; no storage keys or signed URLs)
    SELECT
        pa.owner_id,
        'photo_assets'::text AS entity_type,
        pa.id,
        pa.updated_at,
        pa.deleted_at,
        CASE WHEN pa.deleted_at IS NOT NULL THEN NULL ELSE jsonb_build_object(
            'id', pa.id,
            'plant_id', pa.plant_id,
            'purpose', pa.purpose,
            'content_hash', pa.content_hash,
            'capture_at', pa.capture_at,
            'uploaded_at', pa.uploaded_at,
            'state', pa.state
        ) END AS data
    FROM public.photo_assets pa
    WHERE pa.plant_id IS NOT NULL
    UNION ALL
    -- 5. analysis_summaries (free projection without raw internal objects)
    SELECT
        ar.owner_id,
        'analysis_summaries'::text AS entity_type,
        ar.id,
        ar.updated_at,
        ar.deleted_at,
        CASE WHEN ar.deleted_at IS NOT NULL THEN NULL ELSE jsonb_build_object(
            'id', ar.id,
            'origin_analysis_id', ar.origin_analysis_id,
            'mode', ar.mode,
            'plant_id', ar.plant_id,
            'source_photo_id', ar.source_photo_id,
            'source_snapshot_id', ar.source_snapshot_id,
            'source_care_revision', ar.source_care_revision,
            'locale', ar.locale,
            'kb_release_id', ar.kb_release_id,
            'protocol_id', ar.protocol_id,
            'identification', ar.identification,
            'diagnosis_status', ar.diagnosis_status,
            'probable_cause', ar.probable_cause,
            'evidence_basis', ar.evidence_basis,
            'limitations', ar.limitations,
            'first_action', ar.first_action,
            'context_state', ar.context_state,
            'created_at', ar.created_at
        ) END AS data
    FROM public.analysis_results ar
    WHERE ar.plant_id IS NOT NULL
    UNION ALL
    -- 6. care_plan_summaries (excludes full_body)
    SELECT
        cp.owner_id,
        'care_plan_summaries'::text AS entity_type,
        cp.id,
        cp.updated_at,
        cp.deleted_at,
        CASE WHEN cp.deleted_at IS NOT NULL THEN NULL ELSE jsonb_build_object(
            'id', cp.id,
            'plant_id', cp.plant_id,
            'locale', cp.locale,
            'plan_kind', cp.plan_kind,
            'access_tier', cp.access_tier,
            'source_kind', cp.source_kind,
            'source_analysis_id', cp.source_analysis_id,
            'snapshot_id', cp.snapshot_id,
            'kb_release_id', cp.kb_release_id,
            'context_revision', cp.context_revision,
            'version', cp.version,
            'next_check_date', cp.next_check_date,
            'comparison_traits', cp.comparison_traits,
            'photo_angle_hint', cp.photo_angle_hint,
            'state', cp.state,
            'created_at', cp.created_at
        ) END AS data
    FROM public.care_plans cp
    UNION ALL
    -- 7. care_tasks
    SELECT
        ct.owner_id,
        'care_tasks'::text AS entity_type,
        ct.id,
        ct.updated_at,
        ct.deleted_at,
        CASE WHEN ct.deleted_at IS NOT NULL THEN NULL ELSE jsonb_build_object(
            'id', ct.id,
            'plant_id', ct.plant_id,
            'rule_id', ct.rule_id,
            'occurrence_key', ct.occurrence_key,
            'action_code', ct.action_code,
            'due_local_date', ct.due_local_date,
            'timezone', ct.timezone,
            'condition_code', ct.condition_code,
            'reminder_eligible', ct.reminder_eligible,
            'inactive_reason', ct.inactive_reason,
            'localized_reason_snapshot', ct.localized_reason_snapshot,
            'comparison_traits', ct.comparison_traits,
            'photo_angle_hint', ct.photo_angle_hint,
            'state', ct.state,
            'revision', ct.revision,
            'completed_entry_id', ct.completed_entry_id
        ) END AS data
    FROM public.care_tasks ct
    UNION ALL
    -- 8. care_entries
    SELECT
        ce.owner_id,
        'care_entries'::text AS entity_type,
        ce.id,
        ce.updated_at,
        ce.deleted_at,
        CASE WHEN ce.deleted_at IS NOT NULL THEN NULL ELSE jsonb_build_object(
            'id', ce.id,
            'plant_id', ce.plant_id,
            'task_id', ce.task_id,
            'action_code', ce.action_code,
            'occurred_at', ce.occurred_at,
            'occurred_local_date', ce.occurred_local_date,
            'timezone', ce.timezone,
            'recorded_at', ce.recorded_at,
            'state', ce.state,
            'operation_id', ce.operation_id
        ) END AS data
    FROM public.care_entries ce
    UNION ALL
    -- 9. care_reversals
    SELECT
        cr.owner_id,
        'care_reversals'::text AS entity_type,
        cr.id,
        cr.updated_at,
        cr.deleted_at,
        CASE WHEN cr.deleted_at IS NOT NULL THEN NULL ELSE jsonb_build_object(
            'id', cr.id,
            'entry_id', cr.entry_id,
            'operation_id', cr.operation_id,
            'recorded_at', cr.recorded_at
        ) END AS data
    FROM public.care_reversals cr
    UNION ALL
    -- 10. schedule_changes
    SELECT
        sc.owner_id,
        'schedule_changes'::text AS entity_type,
        sc.id,
        sc.updated_at,
        sc.deleted_at,
        CASE WHEN sc.deleted_at IS NOT NULL THEN NULL ELSE jsonb_build_object(
            'id', sc.id,
            'plant_id', sc.plant_id,
            'from_date', sc.from_date,
            'to_date', sc.to_date,
            'cause_code', sc.cause_code,
            'source_event_id', sc.source_event_id,
            'explanation_code', sc.explanation_code,
            'created_at', sc.created_at
        ) END AS data
    FROM public.schedule_changes sc
    UNION ALL
    -- 11. basic_care_memberships
    SELECT
        bcm.owner_id,
        'basic_care_memberships'::text AS entity_type,
        bcm.id,
        bcm.updated_at,
        bcm.deleted_at,
        CASE WHEN bcm.deleted_at IS NOT NULL THEN NULL ELSE jsonb_build_object(
            'id', bcm.id,
            'plant_id', bcm.plant_id,
            'enabled_at', bcm.enabled_at,
            'enabled', bcm.enabled,
            'free_slot', bcm.free_slot
        ) END AS data
    FROM public.basic_care_memberships bcm
    UNION ALL
    -- 12. first_aid_followups
    SELECT
        faf.owner_id,
        'first_aid_followups'::text AS entity_type,
        faf.id,
        faf.updated_at,
        faf.deleted_at,
        CASE WHEN faf.deleted_at IS NOT NULL THEN NULL ELSE jsonb_build_object(
            'id', faf.id,
            'plant_id', faf.plant_id,
            'origin_analysis_id', faf.origin_analysis_id,
            'decision_revision', faf.decision_revision,
            'kb_release_id', faf.kb_release_id,
            'protocol_id', faf.protocol_id,
            'action_code', faf.action_code,
            'first_action_snapshot', faf.first_action_snapshot,
            'check_policy_snapshot', faf.check_policy_snapshot,
            'action_entry_id', faf.action_entry_id,
            'control_task_id', faf.control_task_id,
            'context_revision', faf.context_revision,
            'state', faf.state
        ) END AS data
    FROM public.first_aid_followups faf
    UNION ALL
    -- 13. care_observations
    SELECT
        co.owner_id,
        'care_observations'::text AS entity_type,
        co.id,
        co.updated_at,
        co.deleted_at,
        CASE WHEN co.deleted_at IS NOT NULL THEN NULL ELSE jsonb_build_object(
            'id', co.id,
            'plant_id', co.plant_id,
            'task_id', co.task_id,
            'status_code', co.status_code,
            'note', co.note,
            'photo_id', co.photo_id,
            'observed_at', co.observed_at,
            'operation_id', co.operation_id
        ) END AS data
    FROM public.care_observations co
    UNION ALL
    -- 14. recovery_transitions
    SELECT
        rt.owner_id,
        'recovery_transitions'::text AS entity_type,
        rt.id,
        rt.updated_at,
        rt.deleted_at,
        CASE WHEN rt.deleted_at IS NOT NULL THEN NULL ELSE jsonb_build_object(
            'id', rt.id,
            'plant_id', rt.plant_id,
            'recovery_plan_id', rt.recovery_plan_id,
            'observation_id', rt.observation_id,
            'expected_care_revision', rt.expected_care_revision,
            'state', rt.state,
            'routine_plan_id', rt.routine_plan_id,
            'created_at', rt.created_at
        ) END AS data
    FROM public.recovery_transitions rt
    UNION ALL
    -- 15. notification_claim_summaries
    SELECT
        nc.owner_id,
        'notification_claim_summaries'::text AS entity_type,
        nc.id,
        nc.updated_at,
        nc.deleted_at,
        CASE WHEN nc.deleted_at IS NOT NULL THEN NULL ELSE jsonb_build_object(
            'id', nc.id,
            'kind', nc.kind,
            'period_key', nc.period_key,
            'installation_id', nc.installation_id,
            'scheduled_at', nc.scheduled_at,
            'state', nc.state
        ) END AS data
    FROM public.notification_claims nc;
