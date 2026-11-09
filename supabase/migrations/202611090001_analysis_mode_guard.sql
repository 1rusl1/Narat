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
  IF p_mode IS NULL OR p_mode NOT IN ('identification', 'diagnosis') THEN
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
