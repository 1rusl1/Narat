-- ============================================================================
-- Migration: 202610200004_collection.sql
-- Tasks: T010
-- Coverage: FR-004, FR-009–FR-014, FR-034, FR-046, FR-047, FR-049, FR-050, FR-062
-- ============================================================================

-- 1. Rooms (user plant groups; deleting room unlinks plants without deleting them)
CREATE TABLE IF NOT EXISTS public.rooms (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    owner_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    name TEXT NOT NULL CHECK (char_length(trim(name)) BETWEEN 1 AND 80),
    revision INT NOT NULL DEFAULT 1 CHECK (revision >= 1),
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    deleted_at TIMESTAMPTZ
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_rooms_owner_name_active
    ON public.rooms (owner_id, lower(name))
    WHERE deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_rooms_owner_sync
    ON public.rooms (owner_id, updated_at, id);

-- 2. Plants (specific plant instance; preserves UUID across species/condition edits)
CREATE TABLE IF NOT EXISTS public.plants (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    owner_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    origin_flow_id UUID,
    creation_intent TEXT NOT NULL DEFAULT 'care'
        CHECK (creation_intent IN ('problem', 'care')),
    add_method TEXT NOT NULL DEFAULT 'catalogue'
        CHECK (add_method IN ('scan', 'catalogue')),
    personal_name TEXT CHECK (personal_name IS NULL OR char_length(trim(personal_name)) BETWEEN 1 AND 120),
    display_name TEXT CHECK (display_name IS NULL OR char_length(trim(display_name)) BETWEEN 1 AND 120),
    taxon_id UUID REFERENCES public.catalogue_taxa(id),
    plant_id TEXT,
    cultivar_label TEXT,
    room_id UUID REFERENCES public.rooms(id) ON DELETE SET NULL,
    main_photo_id UUID,
    current_condition_snapshot_id UUID,
    current_snapshot_id UUID,
    origin_draft_id UUID,
    creation_source TEXT NOT NULL DEFAULT 'catalogue'
        CHECK (creation_source IN ('catalogue', 'analysis', 'identification', 'guest_claim', 'local_fallback')),
    revision INT NOT NULL DEFAULT 1 CHECK (revision >= 1),
    care_revision INT NOT NULL DEFAULT 1 CHECK (care_revision >= 1),
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    deleted_at TIMESTAMPTZ,
    CONSTRAINT plants_catalogue_requires_taxon_chk
        CHECK (creation_source <> 'catalogue' OR taxon_id IS NOT NULL),
    CONSTRAINT plants_name_present_chk
        CHECK (COALESCE(personal_name, display_name) IS NOT NULL)
);

CREATE OR REPLACE FUNCTION public.sync_plant_instance_columns()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.personal_name IS NULL AND NEW.display_name IS NOT NULL THEN
        NEW.personal_name := NEW.display_name;
    ELSIF NEW.display_name IS NULL AND NEW.personal_name IS NOT NULL THEN
        NEW.display_name := NEW.personal_name;
    END IF;
    IF NEW.current_condition_snapshot_id IS NULL AND NEW.current_snapshot_id IS NOT NULL THEN
        NEW.current_condition_snapshot_id := NEW.current_snapshot_id;
    ELSIF NEW.current_snapshot_id IS NULL AND NEW.current_condition_snapshot_id IS NOT NULL THEN
        NEW.current_snapshot_id := NEW.current_condition_snapshot_id;
    ELSIF NEW.current_snapshot_id IS DISTINCT FROM OLD.current_snapshot_id THEN
        NEW.current_condition_snapshot_id := NEW.current_snapshot_id;
    ELSIF NEW.current_condition_snapshot_id IS DISTINCT FROM OLD.current_condition_snapshot_id THEN
        NEW.current_snapshot_id := NEW.current_condition_snapshot_id;
    END IF;
    IF NEW.taxon_id IS NOT NULL AND NEW.plant_id IS NULL THEN
        SELECT t.plant_id INTO NEW.plant_id FROM public.catalogue_taxa t WHERE t.id = NEW.taxon_id;
    ELSIF NEW.plant_id IS NOT NULL AND NEW.taxon_id IS NULL THEN
        SELECT t.id INTO NEW.taxon_id FROM public.catalogue_taxa t WHERE t.plant_id = NEW.plant_id;
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_plants_sync_columns ON public.plants;
CREATE TRIGGER trg_plants_sync_columns
    BEFORE INSERT OR UPDATE ON public.plants
    FOR EACH ROW
    EXECUTE FUNCTION public.sync_plant_instance_columns();

CREATE UNIQUE INDEX IF NOT EXISTS idx_plants_owner_origin_draft_unique
    ON public.plants (owner_id, origin_draft_id)
    WHERE origin_draft_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_plants_owner_sync
    ON public.plants (owner_id, updated_at, id);

-- 3. Guest Drafts (24h server TTL; does not reset starter consumption on cleanup)
CREATE TABLE IF NOT EXISTS public.guest_drafts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    guest_owner_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    flow_id UUID NOT NULL,
    intent TEXT NOT NULL CHECK (intent IN ('problem', 'care')),
    add_method TEXT NOT NULL CHECK (add_method IN ('scan', 'catalogue')),
    photo_id UUID,
    condition_snapshot_id UUID,
    analysis_job_id UUID,
    expires_at TIMESTAMPTZ NOT NULL DEFAULT (clock_timestamp() + INTERVAL '24 hours'),
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    deleted_at TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_guest_drafts_expires_at
    ON public.guest_drafts (expires_at);

-- 4. Condition Snapshots (immutable history of light, watering, drainage, pot_type, season_override)
CREATE TABLE IF NOT EXISTS public.condition_snapshots (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    owner_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    plant_id UUID REFERENCES public.plants(id) ON DELETE CASCADE,
    draft_id UUID REFERENCES public.guest_drafts(id) ON DELETE CASCADE,
    version INT NOT NULL DEFAULT 1 CHECK (version >= 1),
    revision INT NOT NULL DEFAULT 1 CHECK (revision >= 1),
    light_code TEXT NOT NULL DEFAULT 'unknown'
        CHECK (light_code IN ('low', 'medium', 'bright_indirect', 'direct_sun', 'unknown')),
    light_level TEXT,
    light_source TEXT NOT NULL DEFAULT 'unknown'
        CHECK (light_source IN ('manual', 'camera_estimate', 'unknown')),
    light_confirmed BOOLEAN NOT NULL DEFAULT false,
    watering_code TEXT NOT NULL DEFAULT 'unknown'
        CHECK (watering_code IN ('several_weekly', 'weekly', 'less_often', 'frequent', 'moderate', 'sparse', 'unknown')),
    watering_habit TEXT,
    drainage_code TEXT NOT NULL DEFAULT 'unknown'
        CHECK (drainage_code IN ('yes', 'no', 'within_7_days', 'over_7_days', 'unknown')),
    last_watered TEXT,
    pot_type TEXT NOT NULL DEFAULT 'unknown'
        CHECK (pot_type IN ('terracotta', 'plastic', 'glazed_ceramic', 'standard_drainage', 'other', 'unknown')),
    season_override TEXT NOT NULL DEFAULT 'auto'
        CHECK (season_override IN ('auto', 'summer', 'winter')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    deleted_at TIMESTAMPTZ,
    CONSTRAINT condition_snapshots_single_parent_chk
        CHECK (num_nonnulls(plant_id, draft_id) = 1),
    CONSTRAINT condition_snapshots_light_semantics_chk
        CHECK (
            (light_source = 'manual' AND light_code <> 'unknown' AND light_confirmed = true)
            OR (light_source = 'camera_estimate' AND light_code IN ('low', 'bright_indirect') AND light_confirmed = true)
            OR (light_source = 'unknown' AND light_code = 'unknown' AND light_confirmed = false)
        )
);

CREATE OR REPLACE FUNCTION public.sync_condition_snapshot_columns()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.revision IS NOT NULL AND NEW.version = 1 AND NEW.revision <> 1 THEN
        NEW.version := NEW.revision;
    ELSE
        NEW.revision := NEW.version;
    END IF;
    IF NEW.light_level IS NOT NULL AND NEW.light_code = 'unknown' THEN
        NEW.light_code := NEW.light_level;
    ELSIF NEW.light_level IS NULL THEN
        NEW.light_level := NEW.light_code;
    END IF;
    IF NEW.watering_habit IS NOT NULL AND NEW.watering_code = 'unknown' THEN
        NEW.watering_code := NEW.watering_habit;
    ELSIF NEW.watering_habit IS NULL THEN
        NEW.watering_habit := NEW.watering_code;
    END IF;
    IF NEW.last_watered IS NOT NULL AND NEW.drainage_code = 'unknown' THEN
        NEW.drainage_code := NEW.last_watered;
    ELSIF NEW.last_watered IS NULL THEN
        NEW.last_watered := NEW.drainage_code;
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_condition_snapshots_sync_columns ON public.condition_snapshots;
CREATE TRIGGER trg_condition_snapshots_sync_columns
    BEFORE INSERT OR UPDATE ON public.condition_snapshots
    FOR EACH ROW
    EXECUTE FUNCTION public.sync_condition_snapshot_columns();

CREATE UNIQUE INDEX IF NOT EXISTS idx_condition_snapshots_plant_version
    ON public.condition_snapshots (plant_id, version)
    WHERE plant_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_condition_snapshots_owner_sync
    ON public.condition_snapshots (owner_id, updated_at, id);

-- 5. Photo Assets (private user photos; immutable uploaded_at on first ready, nullable capture_at)
CREATE TABLE IF NOT EXISTS public.photo_assets (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    owner_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    plant_id UUID REFERENCES public.plants(id) ON DELETE CASCADE,
    draft_id UUID REFERENCES public.guest_drafts(id) ON DELETE CASCADE,
    purpose TEXT NOT NULL
        CHECK (purpose IN ('initial', 'follow_up', 'diary')),
    original_key TEXT NOT NULL,
    analysis_key TEXT,
    content_hash TEXT NOT NULL,
    capture_at TIMESTAMPTZ,
    uploaded_at TIMESTAMPTZ,
    state TEXT NOT NULL DEFAULT 'initialized'
        CHECK (state IN ('initialized', 'uploaded', 'ready', 'failed', 'deleting', 'deleted')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    deleted_at TIMESTAMPTZ,
    CONSTRAINT photo_assets_ready_uploaded_at_chk
        CHECK (state <> 'ready' OR uploaded_at IS NOT NULL)
);

CREATE INDEX IF NOT EXISTS idx_photo_assets_owner_sync
    ON public.photo_assets (owner_id, updated_at, id);

-- Enforce immutable uploaded_at once set
CREATE OR REPLACE FUNCTION public.enforce_photo_uploaded_at_immutability()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF OLD.uploaded_at IS NOT NULL AND NEW.uploaded_at IS DISTINCT FROM OLD.uploaded_at THEN
        RAISE EXCEPTION 'photo_uploaded_at_immutable' USING ERRCODE = '42501';
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_photo_uploaded_at_immutable ON public.photo_assets;
CREATE TRIGGER trg_photo_uploaded_at_immutable
    BEFORE UPDATE ON public.photo_assets
    FOR EACH ROW
    EXECUTE FUNCTION public.enforce_photo_uploaded_at_immutability();

-- Add deferred FKs between plants/guest_drafts and snapshots/photos
ALTER TABLE public.plants
    ADD CONSTRAINT fk_plants_main_photo
    FOREIGN KEY (main_photo_id) REFERENCES public.photo_assets(id) ON DELETE SET NULL;

ALTER TABLE public.plants
    ADD CONSTRAINT fk_plants_current_condition_snapshot
    FOREIGN KEY (current_condition_snapshot_id) REFERENCES public.condition_snapshots(id) ON DELETE SET NULL;

ALTER TABLE public.guest_drafts
    ADD CONSTRAINT fk_guest_drafts_photo
    FOREIGN KEY (photo_id) REFERENCES public.photo_assets(id) ON DELETE SET NULL;

ALTER TABLE public.guest_drafts
    ADD CONSTRAINT fk_guest_drafts_condition_snapshot
    FOREIGN KEY (condition_snapshot_id) REFERENCES public.condition_snapshots(id) ON DELETE SET NULL;

-- 6. Draft Claims (15-minute single-use proof, overrides & two-phase staging copy)
CREATE TABLE IF NOT EXISTS public.draft_claims (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    draft_id UUID NOT NULL REFERENCES public.guest_drafts(id) ON DELETE CASCADE,
    proof_hash TEXT NOT NULL,
    expires_at TIMESTAMPTZ NOT NULL DEFAULT (clock_timestamp() + INTERVAL '15 minutes'),
    target_owner_id UUID REFERENCES public.profiles(id) ON DELETE CASCADE,
    operation_id UUID NOT NULL,
    payload_hash TEXT,
    overrides JSONB,
    result_plant_id UUID REFERENCES public.plants(id) ON DELETE SET NULL,
    state TEXT NOT NULL DEFAULT 'prepared'
        CHECK (state IN ('prepared', 'copying', 'published', 'cleanup_done')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);

CREATE INDEX IF NOT EXISTS idx_draft_claims_draft_state
    ON public.draft_claims (draft_id, state);
