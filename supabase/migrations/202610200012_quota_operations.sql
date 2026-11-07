-- 202610200012_quota_operations.sql
-- T030: Atomic quota admission, reservation, exactly-once terminal settlement, and installation-to-owner binding.

CREATE OR REPLACE FUNCTION public.compute_paid_quota_window(
  p_anchor_at TIMESTAMPTZ,
  p_now TIMESTAMPTZ DEFAULT now()
)
RETURNS TABLE (period_start TIMESTAMPTZ, period_end TIMESTAMPTZ)
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_anchor TIMESTAMPTZ := COALESCE(p_anchor_at, p_now);
  v_months INT := 0;
  v_start TIMESTAMPTZ;
  v_end TIMESTAMPTZ;
BEGIN
  IF p_now <= v_anchor THEN
    period_start := v_anchor;
    period_end := v_anchor + INTERVAL '1 month';
    RETURN NEXT;
    RETURN;
  END IF;

  v_months := GREATEST(
    0,
    (EXTRACT(YEAR FROM age(p_now, v_anchor))::INT * 12) +
    EXTRACT(MONTH FROM age(p_now, v_anchor))::INT
  );

  v_start := v_anchor + make_interval(months => v_months);
  WHILE v_start > p_now LOOP
    v_months := v_months - 1;
    v_start := v_anchor + make_interval(months => v_months);
  END LOOP;

  v_end := v_anchor + make_interval(months => v_months + 1);
  WHILE v_end <= p_now LOOP
    v_months := v_months + 1;
    v_start := v_anchor + make_interval(months => v_months);
    v_end := v_anchor + make_interval(months => v_months + 1);
  END LOOP;

  period_start := v_start;
  period_end := v_end;
  RETURN NEXT;
END;
$$;

CREATE OR REPLACE FUNCTION public.bind_installation_to_owner(
  p_installation_id UUID,
  p_owner_id UUID,
  p_now TIMESTAMPTZ DEFAULT now()
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_ts TIMESTAMPTZ;
  v_inst RECORD;
  v_prof RECORD;
  v_id_consumed BOOLEAN;
  v_diag_consumed BOOLEAN;
  v_id_job UUID;
  v_diag_job UUID;
  v_earliest_success TIMESTAMPTZ;
BEGIN
  v_ts := public.advance_owner_watermark(p_owner_id);

  SELECT * INTO v_prof
  FROM public.profiles
  WHERE id = p_owner_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'OWNER_NOT_FOUND';
  END IF;

  SELECT * INTO v_inst
  FROM public.installation_access
  WHERE id = p_installation_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'INSTALLATION_NOT_FOUND';
  END IF;

  v_id_consumed := v_inst.starter_identification_consumed OR v_prof.starter_identification_consumed;
  v_diag_consumed := v_inst.starter_diagnosis_consumed OR v_prof.starter_diagnosis_consumed;
  v_id_job := COALESCE(v_prof.starter_identification_job_id, v_inst.starter_identification_job_id);
  v_diag_job := COALESCE(v_prof.starter_diagnosis_job_id, v_inst.starter_diagnosis_job_id);

  IF v_inst.first_starter_success_at IS NOT NULL AND v_prof.first_starter_success_at IS NOT NULL THEN
    v_earliest_success := LEAST(v_inst.first_starter_success_at, v_prof.first_starter_success_at);
  ELSE
    v_earliest_success := COALESCE(v_inst.first_starter_success_at, v_prof.first_starter_success_at);
  END IF;

  UPDATE public.installation_access
  SET bound_owner_id = p_owner_id,
      starter_identification_consumed = v_id_consumed,
      starter_diagnosis_consumed = v_diag_consumed,
      starter_identification_job_id = v_id_job,
      starter_diagnosis_job_id = v_diag_job,
      first_starter_success_at = v_earliest_success,
      updated_at = v_ts
  WHERE id = p_installation_id;

  UPDATE public.profiles
  SET starter_identification_consumed = v_id_consumed,
      starter_diagnosis_consumed = v_diag_consumed,
      starter_identification_job_id = v_id_job,
      starter_diagnosis_job_id = v_diag_job,
      first_starter_success_at = v_earliest_success,
      updated_at = v_ts
  WHERE id = p_owner_id;

  RETURN jsonb_build_object(
    'installation_id', p_installation_id,
    'owner_id', p_owner_id,
    'starter_identification_consumed', v_id_consumed,
    'starter_diagnosis_consumed', v_diag_consumed,
    'starter_identification_job_id', v_id_job,
    'starter_diagnosis_job_id', v_diag_job,
    'first_starter_success_at', v_earliest_success
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.admit_analysis_quota(
  p_mode TEXT,
  p_owner_id UUID,
  p_installation_id UUID,
  p_job_id UUID,
  p_now TIMESTAMPTZ DEFAULT now()
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_prof RECORD;
  v_inst RECORD;
  v_has_paid BOOLEAN := FALSE;
  v_window RECORD;
  v_quota RECORD;
  v_id_consumed BOOLEAN := FALSE;
  v_diag_consumed BOOLEAN := FALSE;
  v_id_job UUID := NULL;
  v_diag_job UUID := NULL;
  v_first_success TIMESTAMPTZ := NULL;
  v_utc_month_start TIMESTAMPTZ;
  v_first_success_month_start TIMESTAMPTZ;
BEGIN
  IF p_mode NOT IN ('identification', 'diagnosis', 'follow_up') THEN
    RAISE EXCEPTION 'INVALID_ANALYSIS_MODE';
  END IF;

  IF p_owner_id IS NOT NULL THEN
    SELECT * INTO v_prof
    FROM public.profiles
    WHERE id = p_owner_id
    FOR UPDATE;

    IF NOT FOUND OR v_prof.account_state <> 'active' THEN
      RETURN jsonb_build_object('admitted', FALSE, 'reason', 'account_inactive');
    END IF;
  END IF;

  IF p_installation_id IS NOT NULL THEN
    SELECT * INTO v_inst
    FROM public.installation_access
    WHERE id = p_installation_id
    FOR UPDATE;
  END IF;

  -- Merge effective starter state across installation and profile
  v_id_consumed := COALESCE(v_prof.starter_identification_consumed, FALSE)
                   OR COALESCE(v_inst.starter_identification_consumed, FALSE);
  v_diag_consumed := COALESCE(v_prof.starter_diagnosis_consumed, FALSE)
                     OR COALESCE(v_inst.starter_diagnosis_consumed, FALSE);
  v_id_job := COALESCE(v_prof.starter_identification_job_id, v_inst.starter_identification_job_id);
  v_diag_job := COALESCE(v_prof.starter_diagnosis_job_id, v_inst.starter_diagnosis_job_id);
  v_first_success := LEAST(
    COALESCE(v_prof.first_starter_success_at, v_inst.first_starter_success_at),
    COALESCE(v_inst.first_starter_success_at, v_prof.first_starter_success_at)
  );

  -- 1. Check if owner is non-anonymous with verified paid access
  IF p_owner_id IS NOT NULL AND NOT v_prof.anonymous THEN
    v_has_paid := public.has_verified_paid_access(p_owner_id, p_now);
  END IF;

  IF p_mode = 'follow_up' AND NOT v_has_paid THEN
    RETURN jsonb_build_object(
      'admitted', FALSE,
      'reason', 'paid_subscription_required_for_follow_up'
    );
  END IF;

  IF v_has_paid THEN
    -- Ensure quota_anchor_at is set on profile
    IF v_prof.quota_anchor_at IS NULL THEN
      UPDATE public.profiles
      SET quota_anchor_at = COALESCE(
            (SELECT verified_at FROM public.entitlements WHERE owner_id = p_owner_id),
            p_now
          ),
          updated_at = GREATEST(now(), v_prof.updated_at + INTERVAL '1 microsecond')
      WHERE id = p_owner_id
      RETURNING * INTO v_prof;
    END IF;

    SELECT * INTO v_window
    FROM public.compute_paid_quota_window(v_prof.quota_anchor_at, p_now);

    INSERT INTO public.monthly_quotas (
      owner_id, quota_kind, period_start, period_end, limit_count, consumed_count, reserved_count
    ) VALUES (
      p_owner_id, 'paid_monthly', v_window.period_start, v_window.period_end, 100, 0, 0
    )
    ON CONFLICT (owner_id, quota_kind, period_start) DO NOTHING;

    SELECT * INTO v_quota
    FROM public.monthly_quotas
    WHERE owner_id = p_owner_id
      AND quota_kind = 'paid_monthly'
      AND period_start = v_window.period_start
    FOR UPDATE;

    IF v_quota.consumed_count + v_quota.reserved_count >= v_quota.limit_count THEN
      -- Paid monthly exhausted: NEVER fall back to free_monthly or starter!
      RETURN jsonb_build_object(
        'admitted', FALSE,
        'quota_kind', 'paid_monthly',
        'reason', 'paid_monthly_exhausted',
        'period_start', v_quota.period_start,
        'period_end', v_quota.period_end,
        'remaining', 0
      );
    END IF;

    UPDATE public.monthly_quotas
    SET reserved_count = reserved_count + 1,
        updated_at = now()
    WHERE id = v_quota.id;

    RETURN jsonb_build_object(
      'admitted', TRUE,
      'quota_kind', 'paid_monthly',
      'monthly_quota_id', v_quota.id,
      'period_start', v_quota.period_start,
      'period_end', v_quota.period_end,
      'remaining_after_reserve', v_quota.limit_count - (v_quota.consumed_count + v_quota.reserved_count + 1)
    );
  END IF;

  -- 2. Guest or Free user path (identification / diagnosis only)
  IF p_mode = 'identification' THEN
    IF v_id_job IS NOT NULL AND v_id_job <> p_job_id THEN
      RETURN jsonb_build_object(
        'admitted', FALSE,
        'quota_kind', 'starter_identification',
        'reason', 'starter_in_progress',
        'in_progress_job_id', v_id_job
      );
    END IF;

    IF NOT v_id_consumed THEN
      IF p_installation_id IS NULL AND (p_owner_id IS NULL OR v_prof.anonymous) THEN
        RETURN jsonb_build_object('admitted', FALSE, 'reason', 'installation_required');
      END IF;

      IF p_installation_id IS NOT NULL THEN
        UPDATE public.installation_access
        SET starter_identification_job_id = p_job_id,
            updated_at = now()
        WHERE id = p_installation_id;
      END IF;

      IF p_owner_id IS NOT NULL THEN
        UPDATE public.profiles
        SET starter_identification_job_id = p_job_id,
            updated_at = GREATEST(now(), v_prof.updated_at + INTERVAL '1 microsecond')
        WHERE id = p_owner_id;
      END IF;

      RETURN jsonb_build_object(
        'admitted', TRUE,
        'quota_kind', 'starter_identification',
        'installation_id', p_installation_id,
        'remaining_after_reserve', 0
      );
    END IF;

  ELSIF p_mode = 'diagnosis' THEN
    IF v_diag_job IS NOT NULL AND v_diag_job <> p_job_id THEN
      RETURN jsonb_build_object(
        'admitted', FALSE,
        'quota_kind', 'starter_diagnosis',
        'reason', 'starter_in_progress',
        'in_progress_job_id', v_diag_job
      );
    END IF;

    IF NOT v_diag_consumed THEN
      IF p_installation_id IS NULL AND (p_owner_id IS NULL OR v_prof.anonymous) THEN
        RETURN jsonb_build_object('admitted', FALSE, 'reason', 'installation_required');
      END IF;

      IF p_installation_id IS NOT NULL THEN
        UPDATE public.installation_access
        SET starter_diagnosis_job_id = p_job_id,
            updated_at = now()
        WHERE id = p_installation_id;
      END IF;

      IF p_owner_id IS NOT NULL THEN
        UPDATE public.profiles
        SET starter_diagnosis_job_id = p_job_id,
            updated_at = GREATEST(now(), v_prof.updated_at + INTERVAL '1 microsecond')
        WHERE id = p_owner_id;
      END IF;

      RETURN jsonb_build_object(
        'admitted', TRUE,
        'quota_kind', 'starter_diagnosis',
        'installation_id', p_installation_id,
        'remaining_after_reserve', 0
      );
    END IF;
  END IF;

  -- 3. Starter for this mode is already consumed. Guest/anonymous cannot use free_monthly.
  IF p_owner_id IS NULL OR v_prof.anonymous THEN
    RETURN jsonb_build_object(
      'admitted', FALSE,
      'quota_kind', CASE WHEN p_mode = 'identification' THEN 'starter_identification' ELSE 'starter_diagnosis' END,
      'reason', 'starter_exhausted'
    );
  END IF;

  -- 4. Authenticated Free user: check free_monthly = 1 per UTC month starting AFTER first_starter_success_at month
  IF v_first_success IS NULL THEN
    RETURN jsonb_build_object(
      'admitted', FALSE,
      'quota_kind', 'free_monthly',
      'reason', 'starter_exhausted'
    );
  END IF;

  v_utc_month_start := (date_trunc('month', p_now AT TIME ZONE 'UTC') AT TIME ZONE 'UTC');
  v_first_success_month_start := (date_trunc('month', v_first_success AT TIME ZONE 'UTC') AT TIME ZONE 'UTC');

  IF v_utc_month_start <= v_first_success_month_start THEN
    RETURN jsonb_build_object(
      'admitted', FALSE,
      'quota_kind', 'free_monthly',
      'reason', 'free_monthly_starts_next_utc_month',
      'next_available_at', v_first_success_month_start + INTERVAL '1 month'
    );
  END IF;

  INSERT INTO public.monthly_quotas (
    owner_id, quota_kind, period_start, period_end, limit_count, consumed_count, reserved_count
  ) VALUES (
    p_owner_id, 'free_monthly', v_utc_month_start, v_utc_month_start + INTERVAL '1 month', 1, 0, 0
  )
  ON CONFLICT (owner_id, quota_kind, period_start) DO NOTHING;

  SELECT * INTO v_quota
  FROM public.monthly_quotas
  WHERE owner_id = p_owner_id
    AND quota_kind = 'free_monthly'
    AND period_start = v_utc_month_start
  FOR UPDATE;

  IF v_quota.consumed_count + v_quota.reserved_count >= v_quota.limit_count THEN
    RETURN jsonb_build_object(
      'admitted', FALSE,
      'quota_kind', 'free_monthly',
      'reason', 'free_monthly_exhausted',
      'period_start', v_quota.period_start,
      'period_end', v_quota.period_end,
      'remaining', 0
    );
  END IF;

  UPDATE public.monthly_quotas
  SET reserved_count = reserved_count + 1,
      updated_at = now()
  WHERE id = v_quota.id;

  RETURN jsonb_build_object(
    'admitted', TRUE,
    'quota_kind', 'free_monthly',
    'monthly_quota_id', v_quota.id,
    'period_start', v_quota.period_start,
    'period_end', v_quota.period_end,
    'remaining_after_reserve', 0
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.finalize_analysis_quota(
  p_job_id UUID,
  p_outcome TEXT,
  p_is_non_billable_result BOOLEAN DEFAULT FALSE,
  p_now TIMESTAMPTZ DEFAULT now()
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_job RECORD;
  v_should_consume BOOLEAN;
BEGIN
  SELECT * INTO v_job
  FROM public.analysis_jobs
  WHERE id = p_job_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'JOB_NOT_FOUND';
  END IF;

  IF v_job.quota_state IN ('consumed', 'released') THEN
    RETURN jsonb_build_object(
      'job_id', p_job_id,
      'already_finalized', TRUE,
      'quota_state', v_job.quota_state,
      'quota_kind', v_job.quota_kind
    );
  END IF;

  v_should_consume := (p_outcome = 'succeeded' AND NOT p_is_non_billable_result);

  IF v_job.quota_kind = 'starter_identification' THEN
    IF v_should_consume THEN
      IF v_job.installation_id IS NOT NULL THEN
        UPDATE public.installation_access
        SET starter_identification_consumed = TRUE,
            starter_identification_job_id = CASE WHEN starter_identification_job_id = p_job_id THEN NULL ELSE starter_identification_job_id END,
            first_starter_success_at = LEAST(COALESCE(first_starter_success_at, p_now), p_now),
            updated_at = p_now
        WHERE id = v_job.installation_id;
      END IF;
      IF v_job.owner_id IS NOT NULL THEN
        UPDATE public.profiles
        SET starter_identification_consumed = TRUE,
            starter_identification_job_id = CASE WHEN starter_identification_job_id = p_job_id THEN NULL ELSE starter_identification_job_id END,
            first_starter_success_at = LEAST(COALESCE(first_starter_success_at, p_now), p_now),
            updated_at = GREATEST(p_now, updated_at + INTERVAL '1 microsecond')
        WHERE id = v_job.owner_id;
      END IF;
    ELSE
      IF v_job.installation_id IS NOT NULL THEN
        UPDATE public.installation_access
        SET starter_identification_job_id = CASE WHEN starter_identification_job_id = p_job_id THEN NULL ELSE starter_identification_job_id END,
            updated_at = p_now
        WHERE id = v_job.installation_id;
      END IF;
      IF v_job.owner_id IS NOT NULL THEN
        UPDATE public.profiles
        SET starter_identification_job_id = CASE WHEN starter_identification_job_id = p_job_id THEN NULL ELSE starter_identification_job_id END,
            updated_at = GREATEST(p_now, updated_at + INTERVAL '1 microsecond')
        WHERE id = v_job.owner_id;
      END IF;
    END IF;

  ELSIF v_job.quota_kind = 'starter_diagnosis' THEN
    IF v_should_consume THEN
      IF v_job.installation_id IS NOT NULL THEN
        UPDATE public.installation_access
        SET starter_diagnosis_consumed = TRUE,
            starter_diagnosis_job_id = CASE WHEN starter_diagnosis_job_id = p_job_id THEN NULL ELSE starter_diagnosis_job_id END,
            first_starter_success_at = LEAST(COALESCE(first_starter_success_at, p_now), p_now),
            updated_at = p_now
        WHERE id = v_job.installation_id;
      END IF;
      IF v_job.owner_id IS NOT NULL THEN
        UPDATE public.profiles
        SET starter_diagnosis_consumed = TRUE,
            starter_diagnosis_job_id = CASE WHEN starter_diagnosis_job_id = p_job_id THEN NULL ELSE starter_diagnosis_job_id END,
            first_starter_success_at = LEAST(COALESCE(first_starter_success_at, p_now), p_now),
            updated_at = GREATEST(p_now, updated_at + INTERVAL '1 microsecond')
        WHERE id = v_job.owner_id;
      END IF;
    ELSE
      IF v_job.installation_id IS NOT NULL THEN
        UPDATE public.installation_access
        SET starter_diagnosis_job_id = CASE WHEN starter_diagnosis_job_id = p_job_id THEN NULL ELSE starter_diagnosis_job_id END,
            updated_at = p_now
        WHERE id = v_job.installation_id;
      END IF;
      IF v_job.owner_id IS NOT NULL THEN
        UPDATE public.profiles
        SET starter_diagnosis_job_id = CASE WHEN starter_diagnosis_job_id = p_job_id THEN NULL ELSE starter_diagnosis_job_id END,
            updated_at = GREATEST(p_now, updated_at + INTERVAL '1 microsecond')
        WHERE id = v_job.owner_id;
      END IF;
    END IF;

  ELSIF v_job.quota_kind IN ('free_monthly', 'paid_monthly') AND v_job.monthly_quota_id IS NOT NULL THEN
    -- Settle against the original reserved monthly_quotas row even if month/subscription changed
    IF v_should_consume THEN
      UPDATE public.monthly_quotas
      SET reserved_count = GREATEST(0, reserved_count - 1),
          consumed_count = consumed_count + 1,
          updated_at = p_now
      WHERE id = v_job.monthly_quota_id;
    ELSE
      UPDATE public.monthly_quotas
      SET reserved_count = GREATEST(0, reserved_count - 1),
          updated_at = p_now
      WHERE id = v_job.monthly_quota_id;
    END IF;
  END IF;

  UPDATE public.analysis_jobs
  SET quota_state = CASE WHEN v_should_consume THEN 'consumed' ELSE 'released' END,
      status = CASE WHEN p_outcome = 'succeeded' THEN 'succeeded' ELSE 'failed' END,
      completed_at = p_now,
      updated_at = p_now
  WHERE id = p_job_id;

  RETURN jsonb_build_object(
    'job_id', p_job_id,
    'already_finalized', FALSE,
    'quota_state', CASE WHEN v_should_consume THEN 'consumed' ELSE 'released' END,
    'quota_kind', v_job.quota_kind
  );
END;
$$;
