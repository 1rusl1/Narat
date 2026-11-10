-- T163 reserve-only slice. Deploy with settlement 009 after separate acceptance.
-- No migration-time DML: original counters, jobs, receipts and leases are retained.
BEGIN;
CREATE OR REPLACE FUNCTION public.admit_analysis_quota(
    p_mode TEXT, p_owner_id UUID, p_installation_id UUID, p_job_id UUID,
    p_now TIMESTAMPTZ DEFAULT now()
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_profile public.profiles%ROWTYPE;
    v_installation public.installation_access%ROWTYPE;
    v_job public.analysis_jobs%ROWTYPE;
    v_usage public.account_quota_usage%ROWTYPE;
    v_anchor TIMESTAMPTZ;
    v_start TIMESTAMPTZ;
    v_end TIMESTAMPTZ;
    v_history JSONB;
    v_paid BOOLEAN;
    v_consumed BOOLEAN;
    v_profile_pointer UUID;
    v_installation_pointer UUID;
    v_kind TEXT;
    v_limit INTEGER;
    v_used BIGINT;
BEGIN
    IF p_mode IS NULL OR p_mode NOT IN ('identification', 'diagnosis') THEN
        RAISE EXCEPTION 'INVALID_ANALYSIS_MODE' USING ERRCODE = '22023';
    END IF;
    IF p_now IS NULL OR NOT isfinite(p_now) THEN
        RAISE EXCEPTION 'INVALID_QUOTA_TIME' USING ERRCODE = '22023';
    END IF;

    -- Owner -> installation -> job/ledger/legacy quota. An actual tuple update
    -- makes stale RR/SERIALIZABLE contenders abort, even without a watermark change.
    SELECT * INTO v_profile FROM public.profiles WHERE id = p_owner_id FOR UPDATE;
    IF NOT FOUND OR v_profile.account_state <> 'active' THEN
        RETURN jsonb_build_object('admitted', false, 'reason', 'account_inactive');
    END IF;
    UPDATE public.profiles SET updated_at = updated_at WHERE id = p_owner_id;

    IF p_installation_id IS NOT NULL THEN
        SELECT * INTO v_installation FROM public.installation_access
        WHERE id = p_installation_id FOR UPDATE;
        IF NOT FOUND THEN
            RETURN jsonb_build_object('admitted', false, 'reason', 'installation_not_found');
        END IF;
        IF (p_owner_id = ANY(v_installation.linked_owner_ids)) IS NOT TRUE THEN
            RETURN jsonb_build_object('admitted', false, 'reason', 'installation_owner_mismatch');
        END IF;
    ELSIF v_profile.anonymous THEN
        RETURN jsonb_build_object('admitted', false, 'reason', 'installation_required');
    END IF;

    SELECT * INTO v_job FROM public.analysis_jobs
    WHERE id = p_job_id AND owner_id = p_owner_id FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('admitted', false, 'reason', 'job_not_found');
    END IF;
    IF v_job.mode <> p_mode THEN
        RETURN jsonb_build_object('admitted', false, 'reason', 'job_mode_mismatch');
    END IF;
    IF v_job.quota_owner_id IS NOT NULL AND v_job.quota_owner_id <> p_owner_id THEN
        RETURN jsonb_build_object('admitted', false, 'reason', 'job_owner_mismatch');
    END IF;
    IF (v_job.quota_installation_id IS NOT NULL
        OR v_job.quota_state = 'reserved')
       AND v_job.quota_installation_id IS DISTINCT FROM p_installation_id THEN
        RETURN jsonb_build_object('admitted', false, 'reason', 'job_installation_mismatch');
    END IF;

    SELECT * INTO v_usage FROM public.account_quota_usage
    WHERE job_id = p_job_id FOR UPDATE;
    IF v_job.quota_state IN ('consumed', 'released')
       OR (FOUND AND v_usage.quota_state IN ('consumed', 'released')) THEN
        RETURN jsonb_build_object('admitted', false, 'reason', 'job_already_finalized',
            'quota_kind', v_job.quota_kind,
            'quota_state', CASE WHEN v_job.quota_state IN ('consumed', 'released')
                THEN v_job.quota_state ELSE v_usage.quota_state END);
    END IF;

    IF v_job.quota_state = 'reserved' THEN
        -- Replay never reserves or changes the original job/lease/pointers.
        IF v_job.quota_kind = 'starter_' || p_mode THEN
            RETURN jsonb_build_object('admitted', true, 'replayed', true,
                'quota_kind', v_job.quota_kind, 'installation_id', p_installation_id,
                'remaining_after_reserve', 0, 'period_start', NULL, 'period_end', NULL);
        END IF;
        IF v_job.quota_kind NOT IN ('free_monthly', 'paid_monthly')
           OR v_profile.anonymous THEN
            RETURN jsonb_build_object('admitted', false, 'reason', 'quota_history_unresolved');
        END IF;
        IF v_usage.job_id IS NULL THEN
            -- Import a legacy running reservation without changing its source.
            SELECT registered_at INTO v_anchor FROM public.account_quota_anchors
            WHERE owner_id = p_owner_id;
            IF v_anchor IS NULL THEN
                RETURN jsonb_build_object('admitted', false, 'reason', 'quota_registration_required');
            END IF;
            PERFORM public.reconcile_registration_quota(p_owner_id);
            SELECT * INTO v_usage FROM public.account_quota_usage
            WHERE job_id = p_job_id FOR UPDATE;
        END IF;
        IF v_usage.job_id IS NULL OR v_usage.owner_id <> p_owner_id
           OR v_usage.legacy_quota_id IS DISTINCT FROM v_job.monthly_quota_id THEN
            RETURN jsonb_build_object('admitted', false, 'reason', 'quota_history_unresolved');
        END IF;
        IF v_usage.quota_state <> 'reserved' THEN
            RETURN jsonb_build_object('admitted', false, 'reason', 'job_already_finalized',
                'quota_kind', v_job.quota_kind, 'quota_state', v_usage.quota_state);
        END IF;
        SELECT count(*) INTO v_used FROM public.account_quota_usage
        WHERE owner_id = p_owner_id AND period_start = v_usage.period_start
          AND period_end = v_usage.period_end AND quota_state IN ('consumed', 'reserved');
        RETURN jsonb_build_object('admitted', true, 'replayed', true,
            'quota_kind', v_job.quota_kind, 'monthly_quota_id', v_job.monthly_quota_id,
            'installation_id', p_installation_id, 'period_start', v_usage.period_start,
            'period_end', v_usage.period_end, 'remaining_after_reserve',
            GREATEST(0, CASE v_job.quota_kind WHEN 'paid_monthly' THEN 100 ELSE 3 END - v_used));
    END IF;

    IF v_job.state <> 'queued' OR v_job.quota_kind <> 'none'
       OR v_job.quota_state <> 'not_applicable' OR v_usage.job_id IS NOT NULL
       OR v_job.monthly_quota_id IS NOT NULL OR v_job.provider_started_at IS NOT NULL
       OR v_job.lease_token IS NOT NULL THEN
        RETURN jsonb_build_object('admitted', false, 'reason', 'job_not_reservable');
    END IF;

    v_paid := NOT v_profile.anonymous AND public.has_verified_paid_access(p_owner_id, p_now);
    IF NOT v_paid THEN
        IF p_mode = 'identification' THEN
            v_consumed := v_profile.starter_identification_consumed
                OR COALESCE(v_installation.starter_identification_consumed, false);
            v_profile_pointer := v_profile.starter_identification_job_id;
            v_installation_pointer := v_installation.starter_identification_job_id;
        ELSE
            v_consumed := v_profile.starter_diagnosis_consumed
                OR COALESCE(v_installation.starter_diagnosis_consumed, false);
            v_profile_pointer := v_profile.starter_diagnosis_job_id;
            v_installation_pointer := v_installation.starter_diagnosis_job_id;
        END IF;
        v_kind := 'starter_' || p_mode;
        IF NOT v_consumed THEN
            -- Do not COALESCE away a conflicting pointer on either side.
            IF (v_profile_pointer IS NOT NULL AND v_profile_pointer <> p_job_id)
               OR (v_installation_pointer IS NOT NULL AND v_installation_pointer <> p_job_id) THEN
                RETURN jsonb_build_object('admitted', false, 'quota_kind', v_kind,
                    'reason', 'starter_in_progress', 'in_progress_job_id',
                    CASE WHEN v_profile_pointer IS DISTINCT FROM p_job_id
                         THEN COALESCE(v_profile_pointer, v_installation_pointer)
                         ELSE v_installation_pointer END);
            END IF;
            IF p_mode = 'identification' THEN
                UPDATE public.profiles SET starter_identification_job_id = p_job_id
                WHERE id = p_owner_id;
                UPDATE public.installation_access SET starter_identification_job_id = p_job_id
                WHERE id = p_installation_id;
            ELSE
                UPDATE public.profiles SET starter_diagnosis_job_id = p_job_id
                WHERE id = p_owner_id;
                UPDATE public.installation_access SET starter_diagnosis_job_id = p_job_id
                WHERE id = p_installation_id;
            END IF;
            UPDATE public.analysis_jobs SET quota_kind = v_kind, quota_state = 'reserved',
                quota_owner_id = p_owner_id, quota_installation_id = p_installation_id
            WHERE id = p_job_id;
            RETURN jsonb_build_object('admitted', true, 'quota_kind', v_kind,
                'installation_id', p_installation_id, 'remaining_after_reserve', 0,
                'period_start', NULL, 'period_end', NULL);
        END IF;
        IF v_profile.anonymous THEN
            RETURN jsonb_build_object('admitted', false, 'quota_kind', v_kind,
                'reason', 'starter_exhausted');
        END IF;
    END IF;

    v_kind := CASE WHEN v_paid THEN 'paid_monthly' ELSE 'free_monthly' END;
    v_limit := CASE WHEN v_paid THEN 100 ELSE 3 END;
    SELECT registered_at INTO v_anchor FROM public.account_quota_anchors
    WHERE owner_id = p_owner_id;
    IF v_anchor IS NULL OR p_now < v_anchor THEN
        RETURN jsonb_build_object('admitted', false, 'quota_kind', v_kind,
            'reason', 'quota_registration_required');
    END IF;
    SELECT period_start, period_end INTO v_start, v_end
    FROM public.compute_paid_quota_window(v_anchor, p_now);
    v_history := public.reconcile_registration_quota(p_owner_id);

    IF (v_history->>'requires_review')::boolean THEN
        -- 006's result combines genuinely unmappable jobs with residuals in ANY
        -- source period. Never discard that result just because no aggregate exists.
        -- A pointerless, already recorded canonical reservation uses its reserve
        -- window; created_at can precede that window (or guest registration).
        IF EXISTS (
            SELECT 1 FROM public.analysis_jobs j
            LEFT JOIN public.monthly_quotas q ON q.id = j.monthly_quota_id
            WHERE j.owner_id = p_owner_id
              AND j.quota_kind IN ('free_monthly', 'paid_monthly')
              AND (j.mode = 'plan' OR j.quota_state NOT IN ('reserved', 'consumed', 'released')
                OR (j.quota_owner_id IS NOT NULL AND j.quota_owner_id <> p_owner_id)
                OR (j.monthly_quota_id IS NOT NULL AND
                    (q.owner_id IS DISTINCT FROM p_owner_id OR q.quota_kind IS DISTINCT FROM j.quota_kind))
                OR NOT EXISTS (
                    SELECT 1 FROM public.account_quota_usage u
                    CROSS JOIN LATERAL public.compute_paid_quota_window(v_anchor, u.period_start) w
                    WHERE u.job_id = j.id AND u.owner_id = p_owner_id
                      AND u.legacy_quota_id IS NOT DISTINCT FROM j.monthly_quota_id
                      AND u.period_start = w.period_start AND u.period_end = w.period_end
                      AND (j.monthly_quota_id IS NULL OR
                          (isfinite(j.created_at) AND j.created_at >= v_anchor
                           AND j.created_at >= u.period_start AND j.created_at < u.period_end))
                ))
        ) OR EXISTS (
            SELECT 1 FROM public.monthly_quotas q
            JOIN public.quota_legacy_reconciliation r ON r.monthly_quota_id = q.id
            CROSS JOIN LATERAL (
                SELECT count(*) FILTER (WHERE j.quota_state = 'consumed') AS consumed,
                       count(*) FILTER (WHERE j.quota_state = 'reserved') AS reserved
                FROM public.analysis_jobs j JOIN public.account_quota_usage u ON u.job_id = j.id
                WHERE j.monthly_quota_id = q.id AND u.legacy_quota_id = q.id
                  AND j.owner_id = p_owner_id AND u.owner_id = p_owner_id
                  AND (j.quota_owner_id IS NULL OR j.quota_owner_id = p_owner_id)
                  AND j.quota_kind = q.quota_kind AND j.mode <> 'plan'
                  AND j.created_at >= u.period_start AND j.created_at < u.period_end
            ) attributed
            WHERE q.owner_id = p_owner_id AND r.requires_review
              AND (NOT isfinite(q.period_start) OR NOT isfinite(q.period_end)
                OR (q.period_start < v_end AND q.period_end > v_start AND
                    (r.unallocated_consumed > 0 OR r.unallocated_reserved > 0
                     OR q.consumed_count <> attributed.consumed
                     OR q.reserved_count <> attributed.reserved
                     OR EXISTS (
                         SELECT 1 FROM public.analysis_jobs j WHERE j.monthly_quota_id = q.id
                         AND (j.owner_id <> p_owner_id
                              OR (j.quota_owner_id IS NOT NULL AND j.quota_owner_id <> p_owner_id)
                              OR j.quota_kind <> q.quota_kind
                              OR j.quota_state NOT IN ('reserved', 'consumed', 'released'))
                     ))))
        ) THEN
            RETURN jsonb_build_object('admitted', false, 'quota_kind', v_kind,
                'reason', 'quota_history_unresolved', 'period_start', v_start, 'period_end', v_end);
        END IF;
    END IF;

    SELECT count(*) INTO v_used FROM public.account_quota_usage
    WHERE owner_id = p_owner_id AND period_start = v_start AND period_end = v_end
      AND quota_state IN ('consumed', 'reserved');
    IF v_used >= v_limit THEN
        RETURN jsonb_build_object('admitted', false, 'quota_kind', v_kind,
            'reason', v_kind || '_exhausted', 'remaining', 0, 'remaining_after_reserve', 0,
            'period_start', v_start, 'period_end', v_end);
    END IF;

    -- The shared ledger is authoritative. Legacy rows/pointers/counters stay intact;
    -- canonical new jobs deliberately have no monthly_quotas pointer.
    INSERT INTO public.account_quota_usage(
        job_id, owner_id, period_start, period_end, quota_state, legacy_quota_id
    ) VALUES (p_job_id, p_owner_id, v_start, v_end, 'reserved', NULL);
    UPDATE public.analysis_jobs SET quota_kind = v_kind, quota_state = 'reserved',
        quota_owner_id = p_owner_id, quota_installation_id = p_installation_id
    WHERE id = p_job_id;
    RETURN jsonb_build_object('admitted', true, 'quota_kind', v_kind,
        'monthly_quota_id', NULL, 'installation_id', p_installation_id,
        'period_start', v_start, 'period_end', v_end,
        'remaining_after_reserve', v_limit - v_used - 1);
END;
$$;
REVOKE ALL ON FUNCTION public.admit_analysis_quota(TEXT, UUID, UUID, UUID, TIMESTAMPTZ)
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.admit_analysis_quota(TEXT, UUID, UUID, UUID, TIMESTAMPTZ)
    TO service_role;
COMMIT;
