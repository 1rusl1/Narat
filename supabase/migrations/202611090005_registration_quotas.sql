-- T163 B1a: registration anchors only. Ledger/admission follow separately.
BEGIN;
-- Serialize seeding with profile creation; never advance the sync watermark.
LOCK TABLE public.profiles IN SHARE ROW EXCLUSIVE MODE;

CREATE TABLE public.account_quota_anchors (
    owner_id UUID PRIMARY KEY REFERENCES public.profiles(id) ON DELETE CASCADE,
    registered_at TIMESTAMPTZ,
    source TEXT NOT NULL CHECK (source ~ '[^[:space:]]')
);
ALTER TABLE public.account_quota_anchors ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.account_quota_anchors FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT ON TABLE public.account_quota_anchors TO service_role;

-- Historical created_at may be a guest creation date, not registration evidence.
INSERT INTO public.account_quota_anchors(owner_id, registered_at, source)
SELECT id, NULL, 'unresolved' FROM public.profiles;

CREATE FUNCTION public.guard_registration_quota_anchor()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_anonymous BOOLEAN;
BEGIN
    -- Trusted writers lock the owner before touching the anchor.
    SELECT anonymous INTO v_anonymous FROM public.profiles
    WHERE id = CASE WHEN TG_OP = 'INSERT' THEN NEW.owner_id ELSE OLD.owner_id END
    FOR UPDATE;

    IF TG_OP = 'DELETE' THEN
        -- FK cascade runs after the parent row disappears. Direct deletion cannot refill.
        IF NOT FOUND THEN RETURN OLD; END IF;
        RAISE EXCEPTION 'REGISTRATION_ANCHOR_IMMUTABLE' USING ERRCODE = '55000';
    END IF;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'OWNER_NOT_FOUND' USING ERRCODE = 'P0002';
    END IF;
    IF TG_OP = 'UPDATE' THEN
        IF NEW.owner_id IS DISTINCT FROM OLD.owner_id
           OR (OLD.registered_at IS NOT NULL AND
               (NEW.registered_at IS DISTINCT FROM OLD.registered_at
                OR NEW.source IS DISTINCT FROM OLD.source))
           OR (NEW.registered_at IS NULL AND NEW.source IS DISTINCT FROM OLD.source) THEN
            RAISE EXCEPTION 'REGISTRATION_ANCHOR_IMMUTABLE' USING ERRCODE = '55000';
        END IF;
    END IF;
    IF NEW.registered_at IS NOT NULL AND
       (v_anonymous OR NOT isfinite(NEW.registered_at)
        OR NEW.registered_at > clock_timestamp()) THEN
        RAISE EXCEPTION 'INVALID_REGISTRATION_ANCHOR' USING ERRCODE = '22023';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_registration_anchor_immutable
BEFORE INSERT OR UPDATE OR DELETE ON public.account_quota_anchors
FOR EACH ROW EXECUTE FUNCTION public.guard_registration_quota_anchor();

CREATE FUNCTION public.capture_registration_quota_anchor()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
    -- INSERT/UPDATE already holds the owner row lock.
    IF TG_OP = 'INSERT' THEN
        INSERT INTO public.account_quota_anchors(owner_id, registered_at, source)
        VALUES (NEW.id, CASE WHEN NEW.anonymous THEN NULL ELSE NEW.created_at END,
                CASE WHEN NEW.anonymous THEN 'anonymous' ELSE 'profile_insert' END);
    ELSIF NEW.anonymous THEN
        IF EXISTS (SELECT 1 FROM public.account_quota_anchors
                   WHERE owner_id = NEW.id AND registered_at IS NOT NULL) THEN
            RAISE EXCEPTION 'REGISTRATION_ANCHOR_IMMUTABLE' USING ERRCODE = '55000';
        END IF;
    ELSIF OLD.anonymous THEN
        -- Guest age is never reused. A later profile edit cannot move this instant.
        UPDATE public.account_quota_anchors
        SET registered_at = clock_timestamp(), source = 'anonymous_conversion'
        WHERE owner_id = NEW.id AND registered_at IS NULL;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_profiles_registration_anchor
AFTER INSERT OR UPDATE OF anonymous ON public.profiles
FOR EACH ROW EXECUTE FUNCTION public.capture_registration_quota_anchor();

CREATE FUNCTION public.set_registration_quota_anchor(
    p_owner_id UUID, p_registered_at TIMESTAMPTZ, p_evidence TEXT
)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_profile public.profiles%ROWTYPE;
    v_anchor public.account_quota_anchors%ROWTYPE;
BEGIN
    SELECT * INTO v_profile FROM public.profiles WHERE id = p_owner_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'OWNER_NOT_FOUND' USING ERRCODE = 'P0002';
    END IF;
    IF v_profile.anonymous OR v_profile.account_state <> 'active' THEN
        RAISE EXCEPTION 'ACTIVE_PERMANENT_OWNER_REQUIRED' USING ERRCODE = '42501';
    END IF;
    IF p_registered_at IS NULL OR NOT isfinite(p_registered_at)
       OR p_registered_at > clock_timestamp()
       OR p_evidence IS NULL OR p_evidence !~ '[^[:space:]]' THEN
        RAISE EXCEPTION 'INVALID_REGISTRATION_EVIDENCE' USING ERRCODE = '22023';
    END IF;
    SELECT * INTO v_anchor FROM public.account_quota_anchors
    WHERE owner_id = p_owner_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'REGISTRATION_ANCHOR_MISSING' USING ERRCODE = 'P0002';
    END IF;
    IF v_anchor.registered_at IS NOT NULL THEN
        IF v_anchor.registered_at = p_registered_at THEN
            RETURN; -- Preserve the original evidence on retries.
        END IF;
        RAISE EXCEPTION 'REGISTRATION_ANCHOR_CONFLICT' USING ERRCODE = '23505';
    END IF;
    UPDATE public.account_quota_anchors
    SET registered_at = p_registered_at, source = p_evidence
    WHERE owner_id = p_owner_id;
END;
$$;

-- Keep the installed purchase trigger, but stop all purchase/trial/restore anchoring.
-- In particular, historical profiles.quota_anchor_at remains byte-for-byte intact.
CREATE OR REPLACE FUNCTION public.ensure_profile_quota_anchor()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.compute_paid_quota_window(
    p_anchor_at TIMESTAMPTZ, p_now TIMESTAMPTZ DEFAULT now()
)
RETURNS TABLE (period_start TIMESTAMPTZ, period_end TIMESTAMPTZ)
LANGUAGE plpgsql IMMUTABLE
SET search_path = ''
AS $$
DECLARE
    v_anchor TIMESTAMP := p_anchor_at AT TIME ZONE 'UTC';
    v_now TIMESTAMP := p_now AT TIME ZONE 'UTC';
    v_months INTEGER;
    v_start TIMESTAMP;
BEGIN
    IF p_anchor_at IS NULL OR p_now IS NULL
       OR NOT isfinite(p_anchor_at) OR NOT isfinite(p_now) THEN
        RAISE EXCEPTION 'INVALID_QUOTA_WINDOW_INPUT' USING ERRCODE = '22023';
    END IF;
    -- Preserve the previous pre-anchor behavior: return the first window.
    v_months := GREATEST(0,
        (extract(year FROM v_now)::INTEGER - extract(year FROM v_anchor)::INTEGER) * 12
        + extract(month FROM v_now)::INTEGER - extract(month FROM v_anchor)::INTEGER);
    v_start := v_anchor + make_interval(months => v_months);
    IF v_months > 0 AND v_start > v_now THEN
        v_months := v_months - 1;
        v_start := v_anchor + make_interval(months => v_months);
    END IF;
    period_start := v_start AT TIME ZONE 'UTC';
    -- Always offset the ORIGINAL UTC timestamp: clamp, then rebound, without DST.
    period_end := (v_anchor + make_interval(months => v_months + 1)) AT TIME ZONE 'UTC';
    RETURN NEXT;
END;
$$;

REVOKE ALL ON FUNCTION
    public.guard_registration_quota_anchor(),
    public.capture_registration_quota_anchor(),
    public.set_registration_quota_anchor(UUID, TIMESTAMPTZ, TEXT),
    public.ensure_profile_quota_anchor(),
    public.compute_paid_quota_window(TIMESTAMPTZ, TIMESTAMPTZ)
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION
    public.guard_registration_quota_anchor(),
    public.capture_registration_quota_anchor(),
    public.set_registration_quota_anchor(UUID, TIMESTAMPTZ, TEXT),
    public.ensure_profile_quota_anchor(),
    public.compute_paid_quota_window(TIMESTAMPTZ, TIMESTAMPTZ)
TO service_role;
COMMIT;
