-- ============================================================================
-- Migration: 202610200007_analysis_quota.sql
-- Tasks: T013
-- Coverage: FR-005, FR-017, FR-065, SC-008
-- ============================================================================

-- 1. Installation Access (Keychain credential hash, independent starter ID & diagnosis markers)
CREATE TABLE IF NOT EXISTS public.installation_access (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    credential_hash TEXT NOT NULL UNIQUE,
    starter_identification_consumed BOOLEAN NOT NULL DEFAULT false,
    starter_diagnosis_consumed BOOLEAN NOT NULL DEFAULT false,
    starter_identification_job_id UUID REFERENCES public.analysis_jobs(id) ON DELETE SET NULL,
    starter_diagnosis_job_id UUID REFERENCES public.analysis_jobs(id) ON DELETE SET NULL,
    first_starter_success_at TIMESTAMPTZ,
    linked_owner_ids UUID[] NOT NULL DEFAULT '{}'::uuid[],
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);

-- 2. Monthly Quotas (free_monthly = 1 UTC month after first starter; paid_monthly = 100 from quota_anchor_at)
CREATE TABLE IF NOT EXISTS public.monthly_quotas (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    owner_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    quota_kind TEXT NOT NULL
        CHECK (quota_kind IN ('free_monthly', 'paid_monthly')),
    period_start TIMESTAMPTZ NOT NULL,
    period_end TIMESTAMPTZ NOT NULL,
    limit_count INT NOT NULL,
    consumed_count INT NOT NULL DEFAULT 0,
    reserved_count INT NOT NULL DEFAULT 0,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    UNIQUE (owner_id, quota_kind, period_start),
    CONSTRAINT monthly_quotas_period_order_chk
        CHECK (period_end > period_start),
    CONSTRAINT monthly_quotas_limit_by_kind_chk
        CHECK (
            (quota_kind = 'free_monthly' AND limit_count = 1)
            OR (quota_kind = 'paid_monthly' AND limit_count = 100)
        ),
    CONSTRAINT monthly_quotas_counts_bounds_chk
        CHECK (
            consumed_count >= 0
            AND reserved_count >= 0
            AND consumed_count + reserved_count <= limit_count
        )
);

CREATE INDEX IF NOT EXISTS idx_monthly_quotas_owner_lookup
    ON public.monthly_quotas (owner_id, quota_kind, period_start DESC);

-- Link analysis_jobs quota pointers
ALTER TABLE public.analysis_jobs
    ADD CONSTRAINT fk_analysis_jobs_quota_installation
    FOREIGN KEY (quota_installation_id) REFERENCES public.installation_access(id) ON DELETE SET NULL;

ALTER TABLE public.analysis_jobs
    ADD CONSTRAINT fk_analysis_jobs_monthly_quota
    FOREIGN KEY (monthly_quota_id) REFERENCES public.monthly_quotas(id) ON DELETE SET NULL;

ALTER TABLE public.notification_claims
    ADD CONSTRAINT fk_notification_claims_installation
    FOREIGN KEY (installation_id) REFERENCES public.installation_access(id) ON DELETE CASCADE;

-- 3. Provider Daily Budget (project-wide guard against runaway AI spend)
CREATE TABLE IF NOT EXISTS public.provider_daily_budget (
    utc_date DATE PRIMARY KEY,
    started_calls INT NOT NULL DEFAULT 0,
    max_calls INT NOT NULL DEFAULT 500,
    input_tokens BIGINT NOT NULL DEFAULT 0,
    output_tokens BIGINT NOT NULL DEFAULT 0,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT provider_daily_budget_bounds_chk
        CHECK (started_calls >= 0 AND max_calls > 0 AND started_calls <= max_calls)
);
