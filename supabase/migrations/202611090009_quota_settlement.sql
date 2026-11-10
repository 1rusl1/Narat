-- T163 finalize-only: settle existing reservations without granting new access.
-- No migration-time DML; original public rows and leases remain unchanged.
BEGIN;
CREATE OR REPLACE FUNCTION public.finalize_analysis_quota(
    p_job_id UUID, p_outcome TEXT,
    p_is_non_billable_result BOOLEAN DEFAULT FALSE,
    p_now TIMESTAMPTZ DEFAULT now()
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_owner UUID;
    v_installation_id UUID;
    v_profile public.profiles%ROWTYPE;
    v_installation public.installation_access%ROWTYPE;
    v_job public.analysis_jobs%ROWTYPE;
    v_usage public.account_quota_usage%ROWTYPE;
    v_quota public.monthly_quotas%ROWTYPE;
    v_consume BOOLEAN;
    v_terminal TEXT;
    v_identification BOOLEAN;
    v_marker BOOLEAN;
    v_first TIMESTAMPTZ;
BEGIN
    IF p_outcome IS NULL OR p_outcome NOT IN ('succeeded', 'failed', 'timed_out')
       OR p_is_non_billable_result IS NULL THEN
        RAISE EXCEPTION 'INVALID_QUOTA_OUTCOME' USING ERRCODE = '22023';
    END IF;
    IF p_now IS NULL OR NOT isfinite(p_now) THEN
        RAISE EXCEPTION 'INVALID_QUOTA_TIME' USING ERRCODE = '22023';
    END IF;

    -- Discover identity without locking the job. Never reverse owner -> job.
    SELECT owner_id, quota_installation_id INTO v_owner, v_installation_id
    FROM public.analysis_jobs WHERE id = p_job_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'JOB_NOT_FOUND' USING ERRCODE = 'P0002';
    END IF;
    SELECT * INTO v_profile FROM public.profiles WHERE id = v_owner FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'OWNER_NOT_FOUND' USING ERRCODE = 'P0002';
    END IF;
    -- Force stale RR/SERIALIZABLE contenders to retry without moving sync time.
    UPDATE public.profiles SET updated_at = updated_at WHERE id = v_owner;
    IF v_installation_id IS NOT NULL THEN
        SELECT * INTO v_installation FROM public.installation_access
        WHERE id = v_installation_id FOR UPDATE;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'INSTALLATION_NOT_FOUND' USING ERRCODE = 'P0002';
        END IF;
    END IF;
    SELECT * INTO v_job FROM public.analysis_jobs WHERE id = p_job_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'JOB_NOT_FOUND' USING ERRCODE = 'P0002';
    END IF;
    IF v_job.owner_id IS DISTINCT FROM v_owner
       OR v_job.quota_installation_id IS DISTINCT FROM v_installation_id THEN
        RAISE EXCEPTION 'QUOTA_IDENTITY_CHANGED' USING ERRCODE = '40001';
    END IF;
    IF v_job.quota_owner_id IS NOT NULL AND v_job.quota_owner_id <> v_owner THEN
        RAISE EXCEPTION 'QUOTA_OWNER_MISMATCH' USING ERRCODE = '23514';
    END IF;

    SELECT * INTO v_usage FROM public.account_quota_usage
    WHERE job_id = p_job_id FOR UPDATE;
    IF v_usage.job_id IS NOT NULL AND
       (v_usage.owner_id <> v_owner
        OR v_usage.legacy_quota_id IS DISTINCT FROM v_job.monthly_quota_id
        OR v_job.quota_kind NOT IN ('free_monthly', 'paid_monthly')) THEN
        RAISE EXCEPTION 'QUOTA_HISTORY_UNRESOLVED' USING ERRCODE = '23514';
    END IF;

    -- Either terminal source is sufficient to prevent a second settlement.
    -- A contradictory retry outcome returns the original terminal result.
    IF v_job.quota_state IN ('consumed', 'released') THEN
        v_terminal := v_job.quota_state;
    END IF;
    IF v_usage.quota_state IN ('consumed', 'released') THEN
        IF v_terminal IS NOT NULL AND v_terminal <> v_usage.quota_state THEN
            RAISE EXCEPTION 'QUOTA_TERMINAL_CONFLICT' USING ERRCODE = '23514';
        END IF;
        v_terminal := v_usage.quota_state;
    END IF;
    IF v_terminal IS NOT NULL THEN
        RETURN jsonb_build_object('job_id', p_job_id, 'already_finalized', true,
            'quota_state', v_terminal, 'quota_kind', v_job.quota_kind);
    END IF;

    -- A job that was never admitted cannot acquire a consumed quota on success.
    IF v_job.quota_kind = 'none' AND v_job.quota_state = 'not_applicable'
       AND v_job.monthly_quota_id IS NULL THEN
        IF v_job.state IN ('succeeded', 'failed', 'timed_out') THEN
            RETURN jsonb_build_object('job_id', p_job_id, 'already_finalized', true,
                'quota_state', 'not_applicable', 'quota_kind', 'none');
        END IF;
        UPDATE public.analysis_jobs SET state = p_outcome, updated_at = p_now
        WHERE id = p_job_id;
        RETURN jsonb_build_object('job_id', p_job_id, 'already_finalized', false,
            'quota_state', 'not_applicable', 'quota_kind', 'none');
    END IF;
    IF v_job.quota_state <> 'reserved' THEN
        RAISE EXCEPTION 'QUOTA_HISTORY_UNRESOLVED' USING ERRCODE = '23514';
    END IF;
    IF v_job.state IN ('succeeded', 'failed', 'timed_out') AND v_job.state <> p_outcome THEN
        RAISE EXCEPTION 'QUOTA_TERMINAL_CONFLICT' USING ERRCODE = '23514';
    END IF;
    v_consume := p_outcome = 'succeeded' AND NOT p_is_non_billable_result;
    v_terminal := CASE WHEN v_consume THEN 'consumed' ELSE 'released' END;

    IF v_job.quota_kind IN ('free_monthly', 'paid_monthly') THEN
        IF v_job.monthly_quota_id IS NOT NULL THEN
            SELECT * INTO v_quota FROM public.monthly_quotas
            WHERE id = v_job.monthly_quota_id FOR UPDATE;
            IF NOT FOUND OR v_quota.owner_id <> v_owner
               OR v_quota.quota_kind <> v_job.quota_kind THEN
                RAISE EXCEPTION 'QUOTA_HISTORY_UNRESOLVED' USING ERRCODE = '23514';
            END IF;
            IF v_quota.reserved_count < 1 THEN
                RAISE EXCEPTION 'QUOTA_RESERVATION_INCONSISTENT' USING ERRCODE = '23514';
            END IF;
            UPDATE public.monthly_quotas
            SET reserved_count = reserved_count - 1,
                consumed_count = consumed_count + CASE WHEN v_consume THEN 1 ELSE 0 END,
                updated_at = p_now
            WHERE id = v_quota.id;
        ELSIF v_usage.job_id IS NULL THEN
            RAISE EXCEPTION 'QUOTA_HISTORY_UNRESOLVED' USING ERRCODE = '23514';
        END IF;
        -- No current-window lookup, entitlement check or anchor requirement.
        -- Unimported legacy jobs settle their original source now; 006 can import
        -- their terminal state later, after registration evidence is verified.
        UPDATE public.account_quota_usage SET quota_state = v_terminal
        WHERE job_id = p_job_id;
    ELSIF v_job.quota_kind IN ('starter_identification', 'starter_diagnosis')
          AND v_job.quota_kind = 'starter_' || v_job.mode
          AND v_job.monthly_quota_id IS NULL THEN
        v_identification := v_job.quota_kind = 'starter_identification';
        v_marker := v_consume
            OR CASE WHEN v_identification THEN v_profile.starter_identification_consumed
                    ELSE v_profile.starter_diagnosis_consumed END
            OR COALESCE(CASE WHEN v_identification THEN v_installation.starter_identification_consumed
                            ELSE v_installation.starter_diagnosis_consumed END, false);
        v_first := LEAST(v_profile.first_starter_success_at,
                         v_installation.first_starter_success_at,
                         CASE WHEN v_consume THEN p_now END);
        -- Preserve other modes and newer pointers, even when this old lease ends.
        UPDATE public.profiles SET
            starter_identification_consumed = CASE WHEN v_identification THEN v_marker ELSE starter_identification_consumed END,
            starter_diagnosis_consumed = CASE WHEN NOT v_identification THEN v_marker ELSE starter_diagnosis_consumed END,
            starter_identification_job_id = CASE WHEN v_identification AND starter_identification_job_id = p_job_id THEN NULL ELSE starter_identification_job_id END,
            starter_diagnosis_job_id = CASE WHEN NOT v_identification AND starter_diagnosis_job_id = p_job_id THEN NULL ELSE starter_diagnosis_job_id END,
            first_starter_success_at = v_first,
            updated_at = GREATEST(p_now, updated_at + INTERVAL '1 microsecond')
        WHERE id = v_owner;
        UPDATE public.installation_access SET
            starter_identification_consumed = CASE WHEN v_identification THEN v_marker ELSE starter_identification_consumed END,
            starter_diagnosis_consumed = CASE WHEN NOT v_identification THEN v_marker ELSE starter_diagnosis_consumed END,
            starter_identification_job_id = CASE WHEN v_identification AND starter_identification_job_id = p_job_id THEN NULL ELSE starter_identification_job_id END,
            starter_diagnosis_job_id = CASE WHEN NOT v_identification AND starter_diagnosis_job_id = p_job_id THEN NULL ELSE starter_diagnosis_job_id END,
            first_starter_success_at = v_first,
            updated_at = GREATEST(p_now, updated_at)
        WHERE id = v_installation_id;
    ELSE
        RAISE EXCEPTION 'QUOTA_HISTORY_UNRESOLVED' USING ERRCODE = '23514';
    END IF;

    UPDATE public.analysis_jobs SET quota_state = v_terminal,
        state = p_outcome, updated_at = p_now WHERE id = p_job_id;
    RETURN jsonb_build_object('job_id', p_job_id, 'already_finalized', false,
        'quota_state', v_terminal, 'quota_kind', v_job.quota_kind);
END;
$$;
REVOKE ALL ON FUNCTION public.finalize_analysis_quota(UUID, TEXT, BOOLEAN, TIMESTAMPTZ)
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.finalize_analysis_quota(UUID, TEXT, BOOLEAN, TIMESTAMPTZ)
    TO service_role;
COMMIT;
