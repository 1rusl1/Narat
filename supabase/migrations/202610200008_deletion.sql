-- ============================================================================
-- Migration: 202610200008_deletion.sql
-- Tasks: T014
-- Coverage: FR-040, FR-041
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.deletion_jobs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    owner_id UUID NOT NULL,
    scope TEXT NOT NULL
        CHECK (scope IN ('plant', 'account')),
    target_id UUID NOT NULL,
    encrypted_apple_ref TEXT,
    state TEXT NOT NULL DEFAULT 'revoke_access'
        CHECK (state IN ('revoke_access', 'purge_storage', 'purge_data', 'revoke_apple', 'delete_auth', 'completed', 'failed')),
    operation_id UUID NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    completed_at TIMESTAMPTZ,
    UNIQUE (owner_id, operation_id)
);

CREATE INDEX IF NOT EXISTS idx_deletion_jobs_state
    ON public.deletion_jobs (state, created_at);
