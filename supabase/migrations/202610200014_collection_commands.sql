-- 202610200014_collection_commands.sql
-- T044: plant.create (including catalogue without photo and >24h local fallback save)
-- and room.create / room.rename / room.delete preserving plants.

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
  v_room_id UUID := NULL;
  v_new_room_name TEXT;
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

  IF v_overrides ? 'room_id' AND v_overrides->>'room_id' IS NOT NULL THEN
    v_room_id := (v_overrides->>'room_id')::UUID;
  ELSIF p_payload ? 'room_id' AND p_payload->>'room_id' IS NOT NULL THEN
    v_room_id := (p_payload->>'room_id')::UUID;
  ELSIF v_overrides ? 'new_room_name' AND length(trim(COALESCE(v_overrides->>'new_room_name', ''))) > 0 THEN
    v_new_room_name := trim(v_overrides->>'new_room_name');
    INSERT INTO public.rooms (owner_id, name, created_at, updated_at)
    VALUES (p_owner_id, v_new_room_name, v_ts, v_ts)
    ON CONFLICT (owner_id, lower(name)) WHERE deleted_at IS NULL
    DO UPDATE SET updated_at = v_ts
    RETURNING id INTO v_room_id;
  END IF;

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
    owner_id, room_id, taxon_id, plant_id, personal_name, display_name,
    main_photo_id, origin_draft_id, origin_flow_id, creation_source, creation_intent, add_method,
    care_revision, created_at, updated_at
  ) VALUES (
    p_owner_id, v_room_id, v_final_taxon_id, v_final_plant_id, v_final_display_name, v_final_display_name,
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
    'room_id', v_room_id,
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
  v_ts TIMESTAMPTZ;
  v_payload_hash TEXT;
  v_cached JSONB;
  v_room_id UUID;
  v_name TEXT;
  v_response JSONB;
BEGIN
  v_ts := public.advance_owner_watermark(p_owner_id);

  v_payload_hash := encode(
    digest(p_command_name || ':' || COALESCE(p_payload::TEXT, '{}'), 'sha256'),
    'hex'
  );

  SELECT r.response_payload INTO v_cached
  FROM public.operation_receipts r
  WHERE r.owner_id = p_owner_id
    AND r.operation_id = p_operation_id
    AND r.command_name = p_command_name
    AND r.payload_hash = v_payload_hash;

  IF v_cached IS NOT NULL THEN
    RETURN v_cached;
  END IF;

  IF p_command_name = 'room.create' THEN
    v_name := trim(COALESCE(p_payload->>'name', ''));
    IF length(v_name) = 0 THEN
      RAISE EXCEPTION 'ROOM_NAME_REQUIRED';
    END IF;

    INSERT INTO public.rooms (owner_id, name, created_at, updated_at)
    VALUES (p_owner_id, v_name, v_ts, v_ts)
    RETURNING id INTO v_room_id;

    v_response := jsonb_build_object(
      'room_id', v_room_id,
      'name', v_name,
      'watermark', v_ts
    );

  ELSIF p_command_name = 'room.rename' THEN
    v_room_id := (p_payload->>'room_id')::UUID;
    v_name := trim(COALESCE(p_payload->>'name', ''));
    IF length(v_name) = 0 THEN
      RAISE EXCEPTION 'ROOM_NAME_REQUIRED';
    END IF;

    UPDATE public.rooms
    SET name = v_name,
        updated_at = v_ts
    WHERE id = v_room_id
      AND owner_id = p_owner_id
      AND deleted_at IS NULL;

    v_response := jsonb_build_object(
      'room_id', v_room_id,
      'name', v_name,
      'watermark', v_ts
    );

  ELSIF p_command_name = 'room.delete' THEN
    v_room_id := (p_payload->>'room_id')::UUID;

    -- Deleting a room preserves all plants in that room by setting room_id = NULL (FR-012)
    UPDATE public.plants
    SET room_id = NULL,
        updated_at = v_ts
    WHERE owner_id = p_owner_id
      AND room_id = v_room_id
      AND deleted_at IS NULL;

    UPDATE public.rooms
    SET deleted_at = v_ts,
        updated_at = v_ts
    WHERE id = v_room_id
      AND owner_id = p_owner_id
      AND deleted_at IS NULL;

    v_response := jsonb_build_object(
      'room_id', v_room_id,
      'deleted', TRUE,
      'watermark', v_ts
    );
  ELSE
    RAISE EXCEPTION 'UNKNOWN_ROOM_COMMAND';
  END IF;

  INSERT INTO public.operation_receipts (
    owner_id, operation_id, command_name, payload_hash, response_payload, committed_at
  ) VALUES (
    p_owner_id, p_operation_id, p_command_name, v_payload_hash, v_response, v_ts
  );

  RETURN v_response;
END;
$$;
