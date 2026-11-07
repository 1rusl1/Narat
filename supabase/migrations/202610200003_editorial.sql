-- ============================================================================
-- Migration: 202610200003_editorial.sql
-- Tasks: T009
-- Coverage: FR-019, FR-044, FR-052–FR-059
-- ============================================================================

-- 1. Care Profiles (PlantProfile Golden Records: parameters, cat/dog safety with evidence/unknown)
CREATE TABLE IF NOT EXISTS public.care_profiles (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    kb_release_id UUID NOT NULL REFERENCES public.kb_releases(id) ON DELETE CASCADE,
    taxon_id UUID NOT NULL REFERENCES public.catalogue_taxa(id) ON DELETE CASCADE,
    version TEXT NOT NULL,
    profile JSONB NOT NULL,
    field_evidence JSONB NOT NULL,
    validation_report JSONB NOT NULL DEFAULT '{}'::jsonb,
    state TEXT NOT NULL DEFAULT 'draft'
        CHECK (state IN ('draft', 'validated', 'published', 'quarantined', 'retired')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    UNIQUE (kb_release_id, taxon_id)
);

-- 2. Condition Profiles (ConditionProfile Golden Records: visual_markers, disambiguation, treatment_plan)
CREATE TABLE IF NOT EXISTS public.condition_profiles (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    kb_release_id UUID NOT NULL REFERENCES public.kb_releases(id) ON DELETE CASCADE,
    condition_id TEXT NOT NULL
        CHECK (condition_id IN (
            'overwatering', 'underwatering', 'poor_drainage', 'root_rot',
            'low_light', 'sunburn', 'cold_stress', 'heat_stress', 'low_humidity',
            'nutrient_deficiency', 'fertilizer_burn', 'salt_buildup', 'nitrogen_deficiency',
            'iron_chlorosis', 'potassium_deficiency', 'magnesium_deficiency', 'ph_imbalance',
            'root_bound', 'transplant_shock', 'acclimation_stress', 'edema',
            'mechanical_damage', 'chemical_phytotoxicity', 'natural_leaf_senescence',
            'thrips_infestation', 'spider_mites', 'mealybugs', 'scale_insects',
            'aphids', 'whiteflies', 'fungus_gnats', 'broad_mites',
            'powdery_mildew', 'grey_mould', 'fungal_leaf_spot', 'bacterial_leaf_spot',
            'bacterial_soft_rot', 'crown_rot', 'sooty_mould', 'suspected_viral_disease'
        )),
    version TEXT NOT NULL,
    protocol JSONB NOT NULL,
    field_evidence JSONB NOT NULL,
    state TEXT NOT NULL DEFAULT 'draft'
        CHECK (state IN ('draft', 'validated', 'published', 'quarantined', 'retired')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    UNIQUE (kb_release_id, condition_id)
);

-- 3. KB Vocabularies (symptom, check, limitation, action codes in PL/EN)
CREATE TABLE IF NOT EXISTS public.kb_vocabularies (
    kb_release_id UUID NOT NULL REFERENCES public.kb_releases(id) ON DELETE CASCADE,
    kind TEXT NOT NULL
        CHECK (kind IN ('symptom', 'visual_marker', 'check', 'limitation', 'action')),
    code TEXT NOT NULL
        CHECK (code ~ '^[a-z][a-z0-9_]*$'),
    localized_text JSONB NOT NULL
        CHECK (localized_text ? 'pl' AND localized_text ? 'en'),
    PRIMARY KEY (kb_release_id, kind, code)
);

-- 4. KB Fallback Protocols (healthy, unknown, out_of_scope, unknown_conditions)
CREATE TABLE IF NOT EXISTS public.kb_fallback_protocols (
    kb_release_id UUID NOT NULL REFERENCES public.kb_releases(id) ON DELETE CASCADE,
    fallback_id TEXT NOT NULL
        CHECK (fallback_id IN ('healthy', 'unknown', 'out_of_scope', 'unknown_conditions')),
    prerequisites JSONB NOT NULL DEFAULT '{}'::jsonb,
    actions JSONB NOT NULL,
    task_rules JSONB NOT NULL DEFAULT '[]'::jsonb,
    content_i18n JSONB NOT NULL
        CHECK (content_i18n ? 'pl' AND content_i18n ? 'en'),
    field_evidence JSONB NOT NULL DEFAULT '{}'::jsonb,
    PRIMARY KEY (kb_release_id, fallback_id)
);

-- 5. Treatment Options (active ingredient / soap / biological / mechanical)
CREATE TABLE IF NOT EXISTS public.treatment_options (
    id TEXT PRIMARY KEY,
    category TEXT NOT NULL
        CHECK (category IN ('chemical', 'soap', 'biological', 'mechanical')),
    active_ingredient TEXT,
    biological_agent TEXT,
    scope JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);

-- 6. Product Evidence (Polish MRiRW registry, PL label, indoor/non-professional use, <=30 days freshness)
CREATE TABLE IF NOT EXISTS public.product_evidence (
    id TEXT PRIMARY KEY,
    treatment_id TEXT NOT NULL REFERENCES public.treatment_options(id) ON DELETE CASCADE,
    exact_sku TEXT NOT NULL,
    category TEXT NOT NULL
        CHECK (category IN ('chemical', 'soap', 'biological', 'mechanical')),
    pl_label_url TEXT NOT NULL,
    authorization_id TEXT,
    authorization_status TEXT NOT NULL
        CHECK (authorization_status IN ('authorized', 'exempt_biocontrol', 'exempt_mechanical', 'expired', 'revoked', 'unknown')),
    application_scope JSONB NOT NULL,
    non_professional_use BOOLEAN NOT NULL DEFAULT false,
    indoor_use BOOLEAN NOT NULL DEFAULT false,
    offer_url TEXT NOT NULL,
    checked_at TIMESTAMPTZ NOT NULL,
    valid_until TIMESTAMPTZ NOT NULL,
    state TEXT NOT NULL DEFAULT 'pending'
        CHECK (state IN ('pending', 'approved', 'blocked', 'expired')),
    CONSTRAINT product_evidence_validity_window_chk
        CHECK (valid_until <= checked_at + INTERVAL '30 days'),
    CONSTRAINT product_evidence_approved_requirements_chk
        CHECK (
            state <> 'approved'
            OR (
                non_professional_use = true
                AND indoor_use = true
                AND authorization_status IN ('authorized', 'exempt_biocontrol', 'exempt_mechanical')
            )
        )
);

-- 7. Urgent Treatment Blocks (revocation independent of immutable KB release)
CREATE TABLE IF NOT EXISTS public.treatment_blocks (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    treatment_id TEXT REFERENCES public.treatment_options(id) ON DELETE CASCADE,
    product_id TEXT REFERENCES public.product_evidence(id) ON DELETE CASCADE,
    reason TEXT NOT NULL,
    effective_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT treatment_blocks_target_chk
        CHECK (treatment_id IS NOT NULL OR product_id IS NOT NULL)
);
