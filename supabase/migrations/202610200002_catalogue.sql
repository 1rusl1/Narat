-- ============================================================================
-- Migration: 202610200002_catalogue.sql
-- Tasks: T008, T147
-- Coverage: FR-014, FR-042, FR-043, FR-052, FR-053, FR-059
-- ============================================================================

-- 1. Source Registry (Donor rights & operation-level permissions)
CREATE TABLE IF NOT EXISTS public.source_registry (
    id TEXT PRIMARY KEY,
    donor TEXT NOT NULL,
    urls JSONB NOT NULL DEFAULT '[]'::jsonb,
    status TEXT NOT NULL DEFAULT 'candidate'
        CHECK (status IN ('candidate', 'allowed', 'blocked', 'expired')),
    use_basis TEXT NOT NULL,
    allowed_operations JSONB NOT NULL DEFAULT '{}'::jsonb,
    terms_checked_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    valid_until TIMESTAMPTZ,
    rate_limit JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);

-- 2. Immutable Source Documents (Markdown snapshots & provenance)
CREATE TABLE IF NOT EXISTS public.source_documents (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    source_id TEXT NOT NULL REFERENCES public.source_registry(id),
    canonical_url TEXT NOT NULL,
    content_hash TEXT NOT NULL,
    markdown_key TEXT NOT NULL,
    published_at TIMESTAMPTZ,
    retrieved_at TIMESTAMPTZ NOT NULL,
    rights_snapshot JSONB NOT NULL,
    UNIQUE (source_id, canonical_url, content_hash)
);

-- 3. Knowledge Base Releases (Immutable 300 species / 40 conditions release)
CREATE TABLE IF NOT EXISTS public.kb_releases (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    version TEXT NOT NULL UNIQUE,
    schema_version TEXT NOT NULL DEFAULT '3.0',
    manifest_hash TEXT NOT NULL DEFAULT '',
    manifest_sha256 TEXT,
    seed_version TEXT NOT NULL DEFAULT '1.0',
    condition_manifest_version TEXT NOT NULL DEFAULT '1.0',
    disambiguation_policy JSONB NOT NULL DEFAULT '{
        "policy_version": "1.0",
        "confidence_threshold": 0.80,
        "closeness_delta": 0.10,
        "max_questions": 2,
        "answer_weight": 0.15
    }'::jsonb,
    prompt_version TEXT NOT NULL DEFAULT '3.0',
    guardrail_version TEXT NOT NULL DEFAULT '1.0',
    validation_report JSONB NOT NULL DEFAULT '{}'::jsonb,
    state TEXT NOT NULL DEFAULT 'draft'
        CHECK (state IN ('draft', 'validated', 'published', 'retired')),
    status TEXT
        CHECK (status IS NULL OR status IN ('draft', 'validated', 'published', 'retired')),
    published_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);

CREATE OR REPLACE FUNCTION public.sync_release_state_status()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF TG_OP = 'UPDATE' THEN
        IF NEW.state IS DISTINCT FROM OLD.state AND NEW.status IS NOT DISTINCT FROM OLD.status THEN
            NEW.status := NEW.state;
        ELSIF NEW.status IS DISTINCT FROM OLD.status AND NEW.state IS NOT DISTINCT FROM OLD.state THEN
            NEW.state := NEW.status;
        END IF;
    ELSE
        IF NEW.status IS NOT NULL AND (NEW.state IS NULL OR NEW.state = 'draft') THEN
            NEW.state := NEW.status;
        ELSIF NEW.state IS NOT NULL AND NEW.status IS NULL THEN
            NEW.status := NEW.state;
        END IF;
    END IF;
    IF TG_TABLE_NAME = 'kb_releases' THEN
        IF NEW.manifest_sha256 IS NOT NULL AND (NEW.manifest_hash IS NULL OR NEW.manifest_hash = '') THEN
            NEW.manifest_hash := NEW.manifest_sha256;
        ELSIF NEW.manifest_hash IS NOT NULL AND NEW.manifest_hash <> '' AND NEW.manifest_sha256 IS NULL THEN
            NEW.manifest_sha256 := NEW.manifest_hash;
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_kb_releases_sync_state ON public.kb_releases;
CREATE TRIGGER trg_kb_releases_sync_state
    BEFORE INSERT OR UPDATE ON public.kb_releases
    FOR EACH ROW
    EXECUTE FUNCTION public.sync_release_state_status();

CREATE UNIQUE INDEX IF NOT EXISTS idx_kb_releases_single_published
    ON public.kb_releases ((state))
    WHERE state = 'published';

-- 4. Catalogue Releases (decoupled from full KB release: kb_release_id is nullable per T147)
CREATE TABLE IF NOT EXISTS public.catalogue_releases (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    version TEXT NOT NULL UNIQUE,
    schema_version TEXT NOT NULL DEFAULT 'catalogue-skeleton-1.1',
    source_doi TEXT,
    source_hash TEXT NOT NULL DEFAULT '',
    sources JSONB NOT NULL DEFAULT '[]'::jsonb,
    published_at TIMESTAMPTZ,
    state TEXT NOT NULL DEFAULT 'draft'
        CHECK (state IN ('draft', 'imported_not_published', 'validated', 'published', 'retired')),
    status TEXT
        CHECK (status IS NULL OR status IN ('draft', 'imported_not_published', 'validated', 'published', 'retired')),
    kb_release_id UUID REFERENCES public.kb_releases(id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);

DROP TRIGGER IF EXISTS trg_catalogue_releases_sync_state ON public.catalogue_releases;
CREATE TRIGGER trg_catalogue_releases_sync_state
    BEFORE INSERT OR UPDATE ON public.catalogue_releases
    FOR EACH ROW
    EXECUTE FUNCTION public.sync_release_state_status();

CREATE UNIQUE INDEX IF NOT EXISTS idx_catalogue_releases_single_published
    ON public.catalogue_releases ((state))
    WHERE state = 'published';

-- 5. Catalogue Taxa (plant_id TEXT <-> taxon UUID; stores basic catalogue fields independently of care_profiles)
CREATE TABLE IF NOT EXISTS public.catalogue_taxa (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    release_id UUID REFERENCES public.catalogue_releases(id) ON DELETE SET NULL,
    plant_id TEXT NOT NULL UNIQUE
        CHECK (plant_id ~ '^[a-z][a-z0-9_]*$'),
    accepted_scientific_name TEXT NOT NULL,
    scientific_name TEXT,
    scientific_name_status TEXT NOT NULL DEFAULT 'Wikidata species name; accepted-taxonomy audit pending',
    wikidata_id TEXT UNIQUE,
    source_revision BIGINT,
    rank TEXT NOT NULL DEFAULT 'species'
        CHECK (rank IN ('species', 'genus', 'hybrid')),
    genus TEXT,
    family TEXT NOT NULL DEFAULT 'unknown',
    common_names JSONB NOT NULL DEFAULT '{"en": [], "pl": []}'::jsonb,
    search_aliases JSONB NOT NULL DEFAULT '{"en": [], "pl": []}'::jsonb,
    descriptions JSONB NOT NULL DEFAULT '{"en": null, "pl": null}'::jsonb,
    hero_image JSONB,
    watering JSONB,
    external_taxon_ids JSONB NOT NULL DEFAULT '{}'::jsonb,
    name_source JSONB,
    gaps JSONB NOT NULL DEFAULT '[]'::jsonb,
    care_profile_available BOOLEAN NOT NULL DEFAULT false,
    status TEXT NOT NULL DEFAULT 'published'
        CHECK (status IN ('draft', 'imported_editorial_review_pending', 'published', 'deprecated')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);

CREATE OR REPLACE FUNCTION public.sync_catalogue_taxa_names()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.accepted_scientific_name IS NULL AND NEW.scientific_name IS NOT NULL THEN
        NEW.accepted_scientific_name := NEW.scientific_name;
    ELSIF NEW.scientific_name IS NULL AND NEW.accepted_scientific_name IS NOT NULL THEN
        NEW.scientific_name := NEW.accepted_scientific_name;
    END IF;
    IF NEW.genus IS NULL AND NEW.accepted_scientific_name IS NOT NULL THEN
        NEW.genus := split_part(NEW.accepted_scientific_name, ' ', 1);
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_catalogue_taxa_sync_names ON public.catalogue_taxa;
CREATE TRIGGER trg_catalogue_taxa_sync_names
    BEFORE INSERT OR UPDATE ON public.catalogue_taxa
    FOR EACH ROW
    EXECUTE FUNCTION public.sync_catalogue_taxa_names();

ALTER TABLE public.catalogue_taxa
    ALTER COLUMN accepted_scientific_name DROP NOT NULL;

ALTER TABLE public.catalogue_taxa
    ADD CONSTRAINT catalogue_taxa_scientific_name_present_chk
    CHECK (COALESCE(accepted_scientific_name, scientific_name) IS NOT NULL);

-- 6. External Taxon IDs (Perenual, WFO, RHS, NC State, Wikidata, GBIF P846, IPNI P961, POWO P5037)
CREATE TABLE IF NOT EXISTS public.taxon_external_ids (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    taxon_id UUID NOT NULL REFERENCES public.catalogue_taxa(id) ON DELETE CASCADE,
    provider TEXT NOT NULL,
    external_id TEXT NOT NULL,
    source_release TEXT NOT NULL DEFAULT 'skeleton-300-v1',
    redirect_target UUID REFERENCES public.catalogue_taxa(id),
    UNIQUE (provider, external_id, source_release)
);

-- 7. Localized & Synonym Taxon Names (PL / EN / Latin)
CREATE TABLE IF NOT EXISTS public.taxon_names (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    taxon_id UUID NOT NULL REFERENCES public.catalogue_taxa(id) ON DELETE CASCADE,
    language TEXT NOT NULL
        CHECK (language IN ('pl', 'en', 'la')),
    kind TEXT NOT NULL
        CHECK (kind IN ('scientific', 'common', 'synonym', 'trade')),
    value TEXT NOT NULL,
    normalized_search TEXT NOT NULL,
    source_id TEXT REFERENCES public.source_registry(id),
    source_property TEXT,
    source_revision BIGINT,
    review_status TEXT,
    UNIQUE (taxon_id, language, kind, value)
);

CREATE INDEX IF NOT EXISTS idx_taxon_names_search
    ON public.taxon_names (normalized_search, language);

CREATE INDEX IF NOT EXISTS idx_taxon_names_taxon
    ON public.taxon_names (taxon_id, language, kind);

-- 8. Approved Catalogue Media & Licensing
CREATE TABLE IF NOT EXISTS public.catalogue_media (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    taxon_id UUID NOT NULL REFERENCES public.catalogue_taxa(id) ON DELETE CASCADE,
    file_title TEXT,
    original_page TEXT NOT NULL,
    local_path TEXT,
    storage_path TEXT,
    sha256 TEXT NOT NULL,
    width INT,
    height INT,
    mime_type TEXT,
    byte_size BIGINT,
    author TEXT NOT NULL,
    credit TEXT,
    license_id TEXT NOT NULL,
    license_url TEXT NOT NULL,
    attribution TEXT NOT NULL,
    modifications TEXT,
    is_hero BOOLEAN NOT NULL DEFAULT true,
    review_state TEXT NOT NULL DEFAULT 'approved'
        CHECK (review_state IN ('pending', 'approved', 'rejected')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    UNIQUE (taxon_id, sha256)
);

-- 9. Evidence Sources (Field-level provenance)
CREATE TABLE IF NOT EXISTS public.evidence_sources (
    id TEXT PRIMARY KEY,
    source_document_id UUID NOT NULL REFERENCES public.source_documents(id),
    url TEXT NOT NULL,
    retrieved_at TIMESTAMPTZ NOT NULL,
    license_or_use_basis TEXT NOT NULL,
    validation_method TEXT NOT NULL,
    validated_at TIMESTAMPTZ NOT NULL,
    scope JSONB NOT NULL DEFAULT '{}'::jsonb
);
