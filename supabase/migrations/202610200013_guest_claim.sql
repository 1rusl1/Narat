-- 202610200013_guest_claim.sql
-- T042: /claims/prepare and /claims/commit SQL functions with overrides, care_revision=2 / context_state='stale'
-- when species or conditions change (room-only change keeps current), next_available_step computation,
-- diagnostic decision/answer transfer, and installation starter flag binding.

CREATE OR REPLACE FUNCTION public.compute_next_available_step(
  p_owner_id UUID,
  p_plant_id UUID,
  p_intent TEXT,
  p_has_diagnosis BOOLEAN,
  p_plan_availability TEXT,
  p_now TIMESTAMPTZ DEFAULT now()
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_has_paid BOOLEAN;
  v_free_slots_used INT;
  v_has_free_slot BOOLEAN;
  v_has_first_aid BOOLEAN;
  v_has_active_plan BOOLEAN;
  v_step TEXT;
  v_paid_action TEXT := NULL;
BEGIN
  v_has_paid := public.has_verified_paid_access(p_owner_id, p_now);

  SELECT EXISTS (
    SELECT 1 FROM public.care_plans cp
    WHERE cp.owner_id = p_owner_id
      AND cp.plant_id = p_plant_id
      AND cp.state = 'active'
      AND cp.deleted_at IS NULL
  ) INTO v_has_active_plan;

  SELECT EXISTS (
    SELECT 1 FROM public.first_aid_followups f
    WHERE f.owner_id = p_owner_id
      AND f.plant_id = p_plant_id
      AND f.state = 'active'
      AND f.deleted_at IS NULL
  ) INTO v_has_first_aid;

  SELECT COUNT(*)::INT
  INTO v_free_slots_used
  FROM public.basic_care_memberships m
  WHERE m.owner_id = p_owner_id
    AND m.enabled = TRUE
    AND m.free_slot IS NOT NULL
    AND m.deleted_at IS NULL;

  SELECT EXISTS (
    SELECT 1 FROM public.basic_care_memberships m
    WHERE m.owner_id = p_owner_id
      AND m.plant_id = p_plant_id
      AND m.enabled = TRUE
      AND m.free_slot IS NOT NULL
      AND m.deleted_at IS NULL
  ) INTO v_has_free_slot;

  IF p_intent = 'problem' AND p_has_diagnosis THEN
    IF v_has_first_aid THEN
      v_step := 'open_first_aid_control';
    ELSE
      v_step := 'record_first_aid';
    END IF;
    IF p_plan_availability = 'available' THEN
      v_paid_action := 'generate_full_recovery_plan';
    END IF;
  ELSE
    -- Care intent or identification without diagnosis
    IF p_plan_availability <> 'available' THEN
      v_step := 'view_plant';
    ELSIF v_has_active_plan AND v_has_paid THEN
      v_step := 'open_plan';
    ELSIF v_has_paid OR v_has_free_slot OR v_free_slots_used < 3 THEN
      v_step := 'enable_basic_care';
      IF NOT v_has_paid THEN
        v_paid_action := 'generate_full_routine_plan';
      END IF;
    ELSE
      v_step := 'select_free_plants';
      v_paid_action := 'unlock_unlimited_basic_care';
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'next_available_step', v_step,
    'paid_action', v_paid_action,
    'plan_availability', p_plan_availability
  );
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
  v_room_id UUID := NULL;
  v_new_room_name TEXT;
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

  -- Optional room selection or new room creation
  IF v_effective_overrides ? 'room_id' AND v_effective_overrides->>'room_id' IS NOT NULL THEN
    v_room_id := (v_effective_overrides->>'room_id')::UUID;
  ELSIF v_effective_overrides ? 'new_room_name' AND length(trim(COALESCE(v_effective_overrides->>'new_room_name', ''))) > 0 THEN
    v_new_room_name := trim(v_effective_overrides->>'new_room_name');
    INSERT INTO public.rooms (owner_id, name, created_at, updated_at)
    VALUES (p_owner_id, v_new_room_name, v_ts, v_ts)
    ON CONFLICT (owner_id, lower(name)) WHERE deleted_at IS NULL
    DO UPDATE SET updated_at = v_ts
    RETURNING id INTO v_room_id;
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
    owner_id, room_id, taxon_id, plant_id, display_name,
    origin_draft_id, origin_flow_id, creation_source, creation_intent, add_method,
    care_revision, created_at, updated_at
  ) VALUES (
    p_owner_id, v_room_id, v_final_taxon_id, v_final_plant_id, v_final_display_name,
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
    'room_id', v_room_id,
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
