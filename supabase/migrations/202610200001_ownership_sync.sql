-- ============================================================================
-- Migration: 202610200001_ownership_sync.sql
-- Tasks: T007, T127 (profiles & operation_receipts)
-- Coverage: FR-010, FR-024, FR-025, FR-035, FR-039, FR-065, FR-068
-- ============================================================================

CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- 1. Profiles table (serialized owner lock & monotonic sync watermark)
CREATE TABLE IF NOT EXISTS public.profiles (
    id UUID PRIMARY KEY,
    account_state TEXT NOT NULL DEFAULT 'active'
        CHECK (account_state IN ('active', 'deleting', 'deleted')),
    anonymous BOOLEAN NOT NULL DEFAULT true,
    app_account_token UUID UNIQUE,
    preferred_locale TEXT NOT NULL DEFAULT 'en'
        CHECK (preferred_locale IN ('pl', 'en')),
    reminder_hour_local INT NOT NULL DEFAULT 9
        CHECK (reminder_hour_local BETWEEN 0 AND 23),
    starter_identification_consumed BOOLEAN NOT NULL DEFAULT false,
    starter_diagnosis_consumed BOOLEAN NOT NULL DEFAULT false,
    starter_identification_job_id UUID,
    starter_diagnosis_job_id UUID,
    first_starter_success_at TIMESTAMPTZ,
    quota_anchor_at TIMESTAMPTZ,
    free_selection_revision BIGINT NOT NULL DEFAULT 0
        CHECK (free_selection_revision >= 0),
    free_selection_explicit BOOLEAN NOT NULL DEFAULT false,
    report_notifications_enabled BOOLEAN NOT NULL DEFAULT false,
    trial_reminder_enabled BOOLEAN NOT NULL DEFAULT false,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    deleted_at TIMESTAMPTZ,
    CONSTRAINT profiles_permanent_app_account_token_chk
        CHECK (NOT anonymous OR app_account_token IS NULL)
);

CREATE INDEX IF NOT EXISTS idx_profiles_account_state
    ON public.profiles (id, account_state);

-- 2. Helper function to acquire owner lock and advance monotonic watermark
CREATE OR REPLACE FUNCTION public.advance_owner_watermark(p_owner_id UUID)
RETURNS TIMESTAMPTZ
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_state TEXT;
    v_prev_ts TIMESTAMPTZ;
    v_next_ts TIMESTAMPTZ;
BEGIN
    SELECT account_state, updated_at
      INTO v_state, v_prev_ts
      FROM public.profiles
     WHERE id = p_owner_id
       FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'owner_profile_not_found' USING ERRCODE = 'P0002';
    END IF;

    IF v_state <> 'active' THEN
        RAISE EXCEPTION 'account_not_active' USING ERRCODE = '42501';
    END IF;

    v_next_ts := GREATEST(clock_timestamp(), v_prev_ts + INTERVAL '1 microsecond');

    UPDATE public.profiles
       SET updated_at = v_next_ts
     WHERE id = p_owner_id;

    RETURN v_next_ts;
END;
$$;

-- 3. Idempotent command receipts (retained until account deletion)
CREATE TABLE IF NOT EXISTS public.operation_receipts (
    owner_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    operation_id UUID NOT NULL,
    command_name TEXT NOT NULL,
    payload_hash TEXT NOT NULL,
    response_payload JSONB NOT NULL,
    committed_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (owner_id, operation_id)
);

CREATE INDEX IF NOT EXISTS idx_operation_receipts_owner_committed
    ON public.operation_receipts (owner_id, committed_at DESC);
