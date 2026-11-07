-- 202611010001_notification_claims.sql
-- T128: Server-deduplicated notification claims (trial_ending_24h and monthly_report).
-- Opt-ins are false by default; (owner_id, kind, period_key) is unique; report key has no timezone;
-- a cancelled claim for a period never grants a second send to another device.

CREATE OR REPLACE FUNCTION public.claim_notification_slot(
  p_owner_id UUID,
  p_operation_id UUID,
  p_kind TEXT,
  p_period_key TEXT,
  p_device_installation_id TEXT,
  p_now TIMESTAMPTZ DEFAULT now()
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_ts TIMESTAMPTZ;
  v_profile RECORD;
  v_entitlement RECORD;
  v_existing RECORD;
  v_claim_id UUID;
  v_scheduled_for TIMESTAMPTZ;
  v_payload_hash TEXT;
  v_cached JSONB;
  v_response JSONB;
BEGIN
  v_ts := public.advance_owner_watermark(p_owner_id);

  v_payload_hash := encode(
    digest(
      coalesce(p_kind, '') || ':' || coalesce(p_period_key, '') || ':' || coalesce(p_device_installation_id, ''),
      'sha256'
    ),
    'hex'
  );

  SELECT r.response_payload
  INTO v_cached
  FROM public.operation_receipts r
  WHERE r.owner_id = p_owner_id
    AND r.operation_id = p_operation_id
    AND r.command_name = 'notification.claim'
    AND r.payload_hash = v_payload_hash;

  IF v_cached IS NOT NULL THEN
    RETURN v_cached;
  END IF;

  SELECT *
  INTO v_profile
  FROM public.profiles
  WHERE id = p_owner_id
    AND account_state = 'active';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'ACTIVE_OWNER_REQUIRED';
  END IF;

  IF p_kind NOT IN ('trial_ending_24h', 'monthly_report') THEN
    RAISE EXCEPTION 'INVALID_NOTIFICATION_KIND';
  END IF;

  IF p_device_installation_id IS NULL OR length(trim(p_device_installation_id)) = 0 THEN
    RAISE EXCEPTION 'INVALID_DEVICE_INSTALLATION_ID';
  END IF;

  IF p_kind = 'monthly_report' THEN
    IF p_period_key !~ '^\d{4}-(0[1-9]|1[0-2])$' THEN
      RAISE EXCEPTION 'INVALID_REPORT_PERIOD_KEY';
    END IF;

    IF NOT v_profile.monthly_report_opt_in THEN
      v_response := jsonb_build_object(
        'granted', FALSE,
        'kind', p_kind,
        'period_key', p_period_key,
        'reason', 'opt_in_disabled'
      );
      INSERT INTO public.operation_receipts (owner_id, operation_id, command_name, payload_hash, response_payload, committed_at)
      VALUES (p_owner_id, p_operation_id, 'notification.claim', v_payload_hash, v_response, v_ts);
      RETURN v_response;
    END IF;

    v_scheduled_for := p_now;

  ELSIF p_kind = 'trial_ending_24h' THEN
    IF NOT v_profile.trial_reminder_opt_in THEN
      v_response := jsonb_build_object(
        'granted', FALSE,
        'kind', p_kind,
        'period_key', p_period_key,
        'reason', 'opt_in_disabled'
      );
      INSERT INTO public.operation_receipts (owner_id, operation_id, command_name, payload_hash, response_payload, committed_at)
      VALUES (p_owner_id, p_operation_id, 'notification.claim', v_payload_hash, v_response, v_ts);
      RETURN v_response;
    END IF;

    SELECT *
    INTO v_entitlement
    FROM public.entitlements e
    WHERE e.owner_id = p_owner_id
      AND e.state IN ('active', 'grace')
      AND e.offer_kind = 'trial'
      AND e.verified_at IS NOT NULL
      AND e.trial_end_at IS NOT NULL
      AND e.trial_end_at > p_now;

    IF NOT FOUND THEN
      v_response := jsonb_build_object(
        'granted', FALSE,
        'kind', p_kind,
        'period_key', p_period_key,
        'reason', 'no_verified_active_trial'
      );
      INSERT INTO public.operation_receipts (owner_id, operation_id, command_name, payload_hash, response_payload, committed_at)
      VALUES (p_owner_id, p_operation_id, 'notification.claim', v_payload_hash, v_response, v_ts);
      RETURN v_response;
    END IF;

    v_scheduled_for := v_entitlement.trial_end_at - INTERVAL '24 hours';
  END IF;

  -- Check existing claim for (owner_id, kind, period_key)
  SELECT *
  INTO v_existing
  FROM public.notification_claims nc
  WHERE nc.owner_id = p_owner_id
    AND nc.kind = p_kind
    AND nc.period_key = p_period_key
  FOR UPDATE;

  IF FOUND THEN
    -- A cancelled claim for a period NEVER issues a second send to another device
    IF v_existing.state = 'cancelled' OR v_existing.deleted_at IS NOT NULL THEN
      v_response := jsonb_build_object(
        'granted', FALSE,
        'claim_id', v_existing.id,
        'kind', p_kind,
        'period_key', p_period_key,
        'state', 'cancelled',
        'reason', 'already_cancelled_for_period'
      );
    ELSIF v_existing.device_installation_id = p_device_installation_id THEN
      v_response := jsonb_build_object(
        'granted', TRUE,
        'claim_id', v_existing.id,
        'kind', p_kind,
        'period_key', p_period_key,
        'state', v_existing.state,
        'scheduled_for', v_existing.scheduled_for
      );
    ELSE
      v_response := jsonb_build_object(
        'granted', FALSE,
        'claim_id', v_existing.id,
        'kind', p_kind,
        'period_key', p_period_key,
        'state', v_existing.state,
        'reason', 'already_claimed_by_other_device'
      );
    END IF;

    INSERT INTO public.operation_receipts (owner_id, operation_id, command_name, payload_hash, response_payload, committed_at)
    VALUES (p_owner_id, p_operation_id, 'notification.claim', v_payload_hash, v_response, v_ts);
    RETURN v_response;
  END IF;

  INSERT INTO public.notification_claims (
    owner_id, kind, period_key, state, device_installation_id,
    scheduled_for, claimed_at, created_at, updated_at
  ) VALUES (
    p_owner_id, p_kind, p_period_key, 'claimed', p_device_installation_id,
    v_scheduled_for, v_ts, v_ts, v_ts
  )
  RETURNING id INTO v_claim_id;

  v_response := jsonb_build_object(
    'granted', TRUE,
    'claim_id', v_claim_id,
    'kind', p_kind,
    'period_key', p_period_key,
    'state', 'claimed',
    'scheduled_for', v_scheduled_for
  );

  INSERT INTO public.operation_receipts (owner_id, operation_id, command_name, payload_hash, response_payload, committed_at)
  VALUES (p_owner_id, p_operation_id, 'notification.claim', v_payload_hash, v_response, v_ts);

  RETURN v_response;
END;
$$;

CREATE OR REPLACE FUNCTION public.cancel_notification_claim(
  p_owner_id UUID,
  p_kind TEXT,
  p_period_key TEXT,
  p_now TIMESTAMPTZ DEFAULT now()
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_ts TIMESTAMPTZ;
  v_claim RECORD;
BEGIN
  v_ts := public.advance_owner_watermark(p_owner_id);

  UPDATE public.notification_claims
  SET state = 'cancelled',
      cancelled_at = v_ts,
      updated_at = v_ts
  WHERE owner_id = p_owner_id
    AND kind = p_kind
    AND period_key = p_period_key
    AND state <> 'cancelled'
  RETURNING * INTO v_claim;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'cancelled', FALSE,
      'kind', p_kind,
      'period_key', p_period_key
    );
  END IF;

  RETURN jsonb_build_object(
    'cancelled', TRUE,
    'claim_id', v_claim.id,
    'kind', p_kind,
    'period_key', p_period_key,
    'state', 'cancelled'
  );
END;
$$;
