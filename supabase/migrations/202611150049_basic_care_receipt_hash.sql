BEGIN;

-- Preserve legacy receipt hashes on both local PostgreSQL and Supabase,
-- where pgcrypto is installed in the extensions schema.
CREATE OR REPLACE FUNCTION public.execute_basic_care_command(
  p_owner_id UUID,
  p_operation_id UUID,
  p_command_type TEXT,
  p_payload JSONB
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  -- Preserve the exact legacy hash, including its handling of SQL NULL.
  v_payload_hash TEXT := encode(sha256(convert_to(coalesce(p_payload::text, '{}'), 'UTF8')), 'hex');
  v_state TEXT;
  v_cached JSONB;
  v_plant_id UUID;
  v_reconciled JSONB;
  v_response JSONB;
  v_ts TIMESTAMPTZ;
BEGIN
  -- Serialize before receipt lookup, including concurrent retries.
  SELECT account_state INTO v_state
  FROM public.profiles WHERE id = p_owner_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'owner_profile_not_found' USING ERRCODE = 'P0002';
  END IF;
  IF v_state <> 'active' THEN
    RAISE EXCEPTION 'account_not_active' USING ERRCODE = '42501';
  END IF;

  IF p_command_type IS NULL OR p_command_type NOT IN (
    'basic_care.enable', 'basic_care.disable', 'free_care.select'
  ) THEN
    RAISE EXCEPTION 'unsupported_basic_care_command' USING ERRCODE = '22023';
  END IF;

  v_cached := public.lookup_operation_receipt(
    p_owner_id, p_operation_id, p_command_type, v_payload_hash
  );
  IF v_cached IS NOT NULL THEN
    RETURN v_cached;
  END IF;

  IF p_command_type = 'free_care.select' THEN
    RAISE EXCEPTION 'FREE_SELECTION_RETIRED' USING ERRCODE = '22023';
  END IF;

  v_plant_id := (p_payload->>'plant_id')::uuid;
  IF NOT EXISTS (
    SELECT 1 FROM public.plants
    WHERE id = v_plant_id AND owner_id = p_owner_id AND deleted_at IS NULL
  ) THEN
    RAISE EXCEPTION 'plant_not_found' USING ERRCODE = 'P0002';
  END IF;

  IF p_command_type = 'basic_care.enable' THEN
    INSERT INTO public.basic_care_memberships (
      owner_id, plant_id, enabled_at, enabled
    ) VALUES (
      p_owner_id, v_plant_id, clock_timestamp(), true
    )
    ON CONFLICT (owner_id, plant_id) DO UPDATE
    SET enabled = true,
        deleted_at = NULL,
        updated_at = clock_timestamp();
  ELSE
    -- The legacy slot_requires_enabled constraint requires this one explicit
    -- clear on disable. Reconcile/upgrade never clears historical slots.
    UPDATE public.basic_care_memberships
    SET enabled = false,
        free_slot = NULL,
        updated_at = clock_timestamp()
    WHERE owner_id = p_owner_id AND plant_id = v_plant_id
      AND deleted_at IS NULL
      AND (enabled OR free_slot IS NOT NULL);
  END IF;

  v_reconciled := public.reconcile_owner_basic_care(p_owner_id);
  v_ts := public.advance_owner_watermark(p_owner_id);
  v_response := jsonb_build_object(
    'status', 'committed',
    'command_type', p_command_type,
    'state', v_reconciled
  );

  RETURN public.save_operation_receipt(
    p_owner_id, p_operation_id, p_command_type, v_payload_hash, v_response, v_ts
  );
END;
$$;

COMMIT;
