-- T163 B1b: shared monthly history only; admission/finalization follow separately.
BEGIN;

CREATE TABLE public.account_quota_usage (
    job_id UUID PRIMARY KEY REFERENCES public.analysis_jobs(id) ON DELETE CASCADE,
    owner_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    period_start TIMESTAMPTZ NOT NULL,
    period_end TIMESTAMPTZ NOT NULL,
    quota_state TEXT NOT NULL CHECK (quota_state IN ('reserved', 'consumed', 'released')),
    legacy_quota_id UUID REFERENCES public.monthly_quotas(id) ON DELETE SET NULL,
    CHECK (isfinite(period_start) AND isfinite(period_end) AND period_end > period_start)
);
CREATE INDEX account_quota_usage_owner_period
    ON public.account_quota_usage(owner_id, period_start, period_end, quota_state);
CREATE INDEX account_quota_usage_legacy
    ON public.account_quota_usage(legacy_quota_id);

CREATE TABLE public.quota_legacy_reconciliation (
    monthly_quota_id UUID PRIMARY KEY REFERENCES public.monthly_quotas(id) ON DELETE CASCADE,
    unallocated_consumed INTEGER NOT NULL CHECK (unallocated_consumed >= 0),
    unallocated_reserved INTEGER NOT NULL CHECK (unallocated_reserved >= 0),
    requires_review BOOLEAN NOT NULL
);
ALTER TABLE public.account_quota_usage ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.quota_legacy_reconciliation ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.account_quota_usage, public.quota_legacy_reconciliation
    FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT ON TABLE public.account_quota_usage, public.quota_legacy_reconciliation
    TO service_role;

CREATE FUNCTION public.reconcile_registration_quota(p_owner_id UUID)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_profile public.profiles%ROWTYPE;
    v_anchor TIMESTAMPTZ;
    v_job RECORD;
    v_window RECORD;
    v_quota public.monthly_quotas%ROWTYPE;
    v_consumed BIGINT;
    v_reserved BIGINT;
    v_unresolved BOOLEAN;
    v_review BOOLEAN;
BEGIN
    -- Lock without advancing the collection/sync watermark.
    SELECT * INTO v_profile FROM public.profiles WHERE id = p_owner_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'OWNER_NOT_FOUND' USING ERRCODE = 'P0002';
    END IF;
    IF v_profile.anonymous OR v_profile.account_state <> 'active' THEN
        RAISE EXCEPTION 'ACTIVE_PERMANENT_OWNER_REQUIRED' USING ERRCODE = '42501';
    END IF;
    SELECT registered_at INTO v_anchor FROM public.account_quota_anchors
    WHERE owner_id = p_owner_id;
    v_unresolved := v_anchor IS NULL;

    -- No migration-time backfill. A verified setter call must precede a known import.
    -- Lock source jobs before legacy quotas, retaining every lease/receipt/pointer.
    FOR v_job IN
        SELECT j.*, q.owner_id AS legacy_owner, q.quota_kind AS legacy_kind
        FROM public.analysis_jobs j
        LEFT JOIN public.monthly_quotas q ON q.id = j.monthly_quota_id
        WHERE j.owner_id = p_owner_id
          AND j.quota_kind IN ('free_monthly', 'paid_monthly')
        ORDER BY j.id FOR UPDATE OF j
    LOOP
        IF v_anchor IS NULL
           OR NOT isfinite(v_job.created_at) OR v_job.created_at < v_anchor
           OR v_job.mode = 'plan'
           OR v_job.quota_state NOT IN ('reserved', 'consumed', 'released')
           OR (v_job.quota_owner_id IS NOT NULL AND v_job.quota_owner_id <> p_owner_id)
           OR (v_job.monthly_quota_id IS NOT NULL AND
               (v_job.legacy_owner IS DISTINCT FROM p_owner_id
                OR v_job.legacy_kind IS DISTINCT FROM v_job.quota_kind)) THEN
            v_unresolved := true;
            CONTINUE;
        END IF;
        BEGIN
            SELECT * INTO v_window FROM public.compute_paid_quota_window(v_anchor, v_job.created_at);
        EXCEPTION WHEN datetime_field_overflow OR numeric_value_out_of_range THEN
            v_unresolved := true;
            CONTINUE;
        END;
        INSERT INTO public.account_quota_usage(
            job_id, owner_id, period_start, period_end, quota_state, legacy_quota_id
        ) VALUES (
            v_job.id, p_owner_id, v_window.period_start, v_window.period_end,
            v_job.quota_state, v_job.monthly_quota_id
        ) ON CONFLICT (job_id) DO NOTHING;
        -- Never overwrite a terminal row or silently move an existing reservation.
        IF NOT EXISTS (
            SELECT 1 FROM public.account_quota_usage u
            WHERE u.job_id = v_job.id AND u.owner_id = p_owner_id
              AND u.period_start = v_window.period_start AND u.period_end = v_window.period_end
              AND u.legacy_quota_id IS NOT DISTINCT FROM v_job.monthly_quota_id
        ) THEN
            v_unresolved := true;
        END IF;
    END LOOP;

    FOR v_quota IN
        SELECT * FROM public.monthly_quotas WHERE owner_id = p_owner_id
        ORDER BY id FOR UPDATE
    LOOP
        -- Attribution uses SOURCE states, not mutable ledger states. If a ledger
        -- reservation is released/consumed, retry cannot turn it into residual reserve.
        -- Counters minus attributable jobs are the only additional legacy charge.
        SELECT count(*) FILTER (WHERE j.quota_state = 'consumed'),
               count(*) FILTER (WHERE j.quota_state = 'reserved')
        INTO v_consumed, v_reserved
        FROM public.analysis_jobs j
        JOIN public.account_quota_usage u ON u.job_id = j.id
        WHERE j.monthly_quota_id = v_quota.id AND u.legacy_quota_id = v_quota.id
          AND j.owner_id = p_owner_id AND u.owner_id = p_owner_id
          AND (j.quota_owner_id IS NULL OR j.quota_owner_id = p_owner_id)
          AND j.quota_kind = v_quota.quota_kind AND j.mode <> 'plan'
          AND j.created_at >= u.period_start AND j.created_at < u.period_end;

        v_review := v_unresolved
            OR NOT isfinite(v_quota.period_start) OR NOT isfinite(v_quota.period_end)
            OR v_quota.consumed_count <> v_consumed OR v_quota.reserved_count <> v_reserved
            OR EXISTS (
                SELECT 1 FROM public.analysis_jobs j WHERE j.monthly_quota_id = v_quota.id
                  AND (j.owner_id <> p_owner_id
                       OR (j.quota_owner_id IS NOT NULL AND j.quota_owner_id <> p_owner_id)
                       OR j.quota_kind <> v_quota.quota_kind
                       OR j.quota_state NOT IN ('reserved', 'consumed', 'released'))
            );
        INSERT INTO public.quota_legacy_reconciliation(
            monthly_quota_id, unallocated_consumed, unallocated_reserved, requires_review
        ) VALUES (
            v_quota.id, GREATEST(0, v_quota.consumed_count - v_consumed)::INTEGER,
            GREATEST(0, v_quota.reserved_count - v_reserved)::INTEGER, v_review
        ) ON CONFLICT (monthly_quota_id) DO UPDATE SET
            unallocated_consumed = EXCLUDED.unallocated_consumed,
            unallocated_reserved = EXCLUDED.unallocated_reserved,
            requires_review = EXCLUDED.requires_review;
    END LOOP;
    -- Includes unmappable jobs with no legacy pointer: callers must honor this
    -- explicit result as well as period-scoped reconciliation rows.
    RETURN jsonb_build_object(
        'registration_required', v_anchor IS NULL,
        'requires_review', v_unresolved OR EXISTS (
            SELECT 1 FROM public.quota_legacy_reconciliation r
            JOIN public.monthly_quotas q ON q.id = r.monthly_quota_id
            WHERE q.owner_id = p_owner_id AND r.requires_review
        )
    );
END;
$$;
REVOKE ALL ON FUNCTION public.reconcile_registration_quota(UUID) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.reconcile_registration_quota(UUID) TO service_role;
COMMIT;
