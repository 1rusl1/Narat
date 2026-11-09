-- B2 authoritative quota metadata. No GET reservation or migration-time DML.
BEGIN;
CREATE FUNCTION public.get_analysis_access_snapshot(
    p_owner_id UUID, p_installation_credential_hash TEXT DEFAULT NULL,
    p_now TIMESTAMPTZ DEFAULT now()
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path = '' SET TimeZone = 'UTC' AS $$
DECLARE
    v_profile public.profiles%ROWTYPE;
    v_installation public.installation_access%ROWTYPE;
    v_anchor TIMESTAMPTZ;
    v_start TIMESTAMPTZ;
    v_end TIMESTAMPTZ;
    v_history JSONB;
    v_paid BOOLEAN;
    v_kind TEXT;
    v_limit INTEGER;
    v_consumed BIGINT;
    v_reserved BIGINT;
    v_remaining BIGINT;
    v_status TEXT;
    v_monthly JSONB;
    v_starter JSONB;
    v_modes JSONB := '{}'::jsonb;
    v_mode TEXT;
    v_spent BOOLEAN;
    v_pointer UUID;
    v_summary JSONB;
BEGIN
    IF p_now IS NULL OR NOT isfinite(p_now) THEN
        RAISE EXCEPTION 'INVALID_QUOTA_TIME' USING ERRCODE='22023';
    END IF;
    SELECT * INTO v_profile FROM public.profiles WHERE id=p_owner_id FOR UPDATE;
    IF NOT FOUND OR v_profile.account_state <> 'active' THEN
        RAISE EXCEPTION 'ACTIVE_OWNER_REQUIRED' USING ERRCODE='42501';
    END IF;
    UPDATE public.profiles SET updated_at=updated_at WHERE id=p_owner_id;
    IF p_installation_credential_hash IS NOT NULL THEN
        IF p_installation_credential_hash !~ '^[0-9a-f]{64}$' THEN
            RAISE EXCEPTION 'INVALID_INSTALLATION_CREDENTIAL' USING ERRCODE='22023';
        END IF;
        SELECT * INTO v_installation FROM public.installation_access
        WHERE credential_hash=p_installation_credential_hash FOR UPDATE;
        IF NOT FOUND OR (p_owner_id=ANY(v_installation.linked_owner_ids)) IS NOT TRUE THEN
            RAISE EXCEPTION 'INSTALLATION_CREDENTIAL_MISMATCH' USING ERRCODE='42501';
        END IF;
    ELSIF v_profile.anonymous THEN
        RAISE EXCEPTION 'INSTALLATION_REQUIRED' USING ERRCODE='22023';
    END IF;
    -- Normalization may repair copied terminal pointers/markers, never debit or
    -- associate an installation to an unproven owner. All identities checked above.
    PERFORM public.merge_installation_starters(v_installation.id,p_owner_id,p_now);
    SELECT * INTO v_profile FROM public.profiles WHERE id=p_owner_id;
    v_starter := jsonb_build_object(
        'identification_remaining',CASE WHEN v_profile.starter_identification_consumed
            OR v_profile.starter_identification_job_id IS NOT NULL THEN 0 ELSE 1 END,
        'diagnosis_remaining',CASE WHEN v_profile.starter_diagnosis_consumed
            OR v_profile.starter_diagnosis_job_id IS NOT NULL THEN 0 ELSE 1 END,
        'identification_in_progress_job_id',v_profile.starter_identification_job_id,
        'diagnosis_in_progress_job_id',v_profile.starter_diagnosis_job_id,
        'first_starter_success_at',v_profile.first_starter_success_at);
    v_status := 'not_applicable';
    v_paid := NOT v_profile.anonymous AND public.has_verified_paid_access(p_owner_id,p_now);
    IF NOT v_profile.anonymous THEN
        v_kind := CASE WHEN v_paid THEN 'paid_monthly' ELSE 'free_monthly' END;
        v_limit := CASE WHEN v_paid THEN 100 ELSE 3 END;
        SELECT registered_at INTO v_anchor FROM public.account_quota_anchors WHERE owner_id=p_owner_id;
        v_status := 'registration_required';
        IF v_anchor IS NOT NULL AND p_now >= v_anchor THEN
            SELECT period_start,period_end INTO v_start,v_end
            FROM public.compute_paid_quota_window(v_anchor,p_now);
            v_history := public.reconcile_registration_quota(p_owner_id);
            v_status := 'ready';
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
            v_status := 'history_unresolved';
        END IF;
    END IF;

            IF v_status='ready' THEN
                SELECT count(*) FILTER(WHERE quota_state='consumed'),
                       count(*) FILTER(WHERE quota_state='reserved')
                INTO v_consumed,v_reserved FROM public.account_quota_usage
                WHERE owner_id=p_owner_id AND period_start=v_start AND period_end=v_end;
                v_remaining := GREATEST(0,v_limit-v_consumed-v_reserved);
            END IF;
        END IF;
    END IF;
    v_monthly := jsonb_build_object('quota_kind',v_kind,'registered_at',v_anchor,
        'period_start',v_start,'period_end',v_end,
        'limit',CASE WHEN v_status='ready' THEN v_limit ELSE NULL END,
        'consumed',v_consumed,'reserved',v_reserved,'remaining',v_remaining,'status',v_status);
    FOREACH v_mode IN ARRAY ARRAY['identification','diagnosis'] LOOP
        v_spent := CASE v_mode WHEN 'identification' THEN v_profile.starter_identification_consumed
            ELSE v_profile.starter_diagnosis_consumed END;
        v_pointer := CASE v_mode WHEN 'identification' THEN v_profile.starter_identification_job_id
            ELSE v_profile.starter_diagnosis_job_id END;
        IF NOT v_paid AND (NOT v_spent OR v_profile.anonymous) THEN
            v_summary := jsonb_build_object('mode',v_mode,'allowed',NOT v_spent AND v_pointer IS NULL,
                'activeQuotaKind','starter_'||v_mode,'remaining',CASE WHEN NOT v_spent AND v_pointer IS NULL THEN 1 ELSE 0 END,
                'limit',1,'inProgressJobId',CASE WHEN NOT v_spent THEN v_pointer ELSE NULL END,'nextResetAt',NULL);
            IF v_spent THEN v_summary := v_summary || jsonb_build_object('reason','starter_exhausted');
            ELSIF v_pointer IS NOT NULL THEN v_summary := v_summary || jsonb_build_object('reason','starter_in_progress'); END IF;
        ELSE
            v_summary := jsonb_build_object('mode',v_mode,'allowed',v_status='ready' AND v_remaining>0,
                'activeQuotaKind',v_kind,'remaining',COALESCE(v_remaining,0),'limit',v_limit,
                'inProgressJobId',NULL,'nextResetAt',v_end);
            IF v_status='registration_required' THEN
                v_summary := v_summary || jsonb_build_object('reason','quota_registration_required');
            ELSIF v_status='history_unresolved' THEN
                v_summary := v_summary || jsonb_build_object('reason','quota_history_unresolved');
            ELSIF v_remaining=0 THEN
                v_summary := v_summary || jsonb_build_object('reason',v_kind||'_exhausted');
            END IF;
        END IF;
        v_modes := v_modes || jsonb_build_object(v_mode,v_summary);
    END LOOP;
    RETURN jsonb_build_object('owner_id',p_owner_id,'is_guest',v_profile.anonymous,
        'starter',v_starter,'monthly',v_monthly,'modes',v_modes);
END; $$;
REVOKE ALL ON FUNCTION public.get_analysis_access_snapshot(UUID,TEXT,TIMESTAMPTZ)
    FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.get_analysis_access_snapshot(UUID,TEXT,TIMESTAMPTZ) TO service_role;
COMMIT;
