-- ============================================================================
-- Migration: 202610200006_billing.sql
-- Tasks: T012
-- Coverage: FR-015–FR-021, SC-008
-- ============================================================================

-- 1. Purchase Ownership (maps environment + original_transaction_id to a single app account)
CREATE TABLE IF NOT EXISTS public.purchase_ownership (
    environment TEXT NOT NULL
        CHECK (environment IN ('Sandbox', 'Production', 'Xcode')),
    original_transaction_id TEXT NOT NULL,
    owner_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    app_account_token UUID NOT NULL,
    first_verified_access_at TIMESTAMPTZ NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (environment, original_transaction_id)
);

CREATE INDEX IF NOT EXISTS idx_purchase_ownership_owner
    ON public.purchase_ownership (owner_id);

-- 2. Subscription Events (App Store Server Notifications V2 deduplication & verified ledger)
CREATE TABLE IF NOT EXISTS public.subscription_events (
    notification_uuid TEXT PRIMARY KEY,
    environment TEXT NOT NULL
        CHECK (environment IN ('Sandbox', 'Production', 'Xcode')),
    transaction_id TEXT NOT NULL,
    verified_payload JSONB NOT NULL,
    processed_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    state TEXT NOT NULL DEFAULT 'processed'
        CHECK (state IN ('processed', 'ignored_older', 'failed'))
);

-- 3. Entitlements (server-verified subscription state, trial/paid offer_kind, verified dates)
CREATE TABLE IF NOT EXISTS public.entitlements (
    owner_id UUID PRIMARY KEY REFERENCES public.profiles(id) ON DELETE CASCADE,
    product_id TEXT NOT NULL
        CHECK (product_id IN ('app.narat.plants.pro.monthly', 'app.narat.plants.pro.yearly')),
    state TEXT NOT NULL
        CHECK (state IN ('active', 'grace', 'billing_retry', 'expired', 'revoked')),
    offer_kind TEXT NOT NULL
        CHECK (offer_kind IN ('trial', 'paid')),
    valid_until TIMESTAMPTZ NOT NULL,
    grace_until TIMESTAMPTZ,
    trial_end_at TIMESTAMPTZ,
    auto_renew_enabled BOOLEAN NOT NULL DEFAULT false,
    checked_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT entitlements_monthly_no_trial_chk
        CHECK (product_id <> 'app.narat.plants.pro.monthly' OR (offer_kind = 'paid' AND trial_end_at IS NULL)),
    CONSTRAINT entitlements_trial_end_required_chk
        CHECK (offer_kind <> 'trial' OR trial_end_at IS NOT NULL)
);

-- Automatically set profiles.quota_anchor_at on first verified access (including trial) without resetting later
CREATE OR REPLACE FUNCTION public.ensure_profile_quota_anchor()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    UPDATE public.profiles
       SET quota_anchor_at = LEAST(COALESCE(quota_anchor_at, NEW.first_verified_access_at), NEW.first_verified_access_at)
     WHERE id = NEW.owner_id;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_purchase_ownership_quota_anchor ON public.purchase_ownership;
CREATE TRIGGER trg_purchase_ownership_quota_anchor
    AFTER INSERT OR UPDATE ON public.purchase_ownership
    FOR EACH ROW
    EXECUTE FUNCTION public.ensure_profile_quota_anchor();
