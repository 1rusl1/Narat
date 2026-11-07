-- ============================================================================
-- Migration: 202611050001_catalogue_skeleton.sql
-- Tasks: T147
-- Coverage: FR-014, FR-042, FR-043, FR-044
-- Independent publication, release-isolated staging, projection, and search of
-- the basic plant catalogue (skeleton-300-v1 / 606 species) without requiring
-- a published kb_releases row or care_profiles / condition_profiles.
-- ============================================================================

-- 1. Normalize search text (casefold + fold Polish/Latin diacritics + collapse whitespace)
CREATE OR REPLACE FUNCTION public.normalize_catalogue_search_text(p_text TEXT)
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT regexp_replace(
        translate(
            lower(trim(COALESCE(p_text, ''))),
            'ąćęłńóśźżàáâãäåèéêëìíîïñòôõöùúûüýÿ',
            'acelnoszzaaaaaaeeeeiiiinoooouuuuyy'
        ),
        '\s+',
        ' ',
        'g'
    );
$$;

-- 2. Per-release species snapshots (`catalogue_release_species`)
--    Isolates staging/draft/retired releases from the active published catalogue_taxa rows
--    while keeping `catalogue_taxa.id` (taxon_id UUID) <-> `plant_id` stable across releases.
CREATE TABLE IF NOT EXISTS public.catalogue_release_species (
    release_id UUID NOT NULL REFERENCES public.catalogue_releases(id) ON DELETE CASCADE,
    taxon_id UUID NOT NULL REFERENCES public.catalogue_taxa(id) ON DELETE CASCADE,
    plant_id TEXT NOT NULL
        CHECK (plant_id ~ '^[a-z][a-z0-9_]*$'),
    accepted_scientific_name TEXT NOT NULL,
    scientific_name TEXT NOT NULL,
    scientific_name_status TEXT NOT NULL DEFAULT 'Wikidata species name; accepted-taxonomy audit pending',
    wikidata_id TEXT,
    source_revision BIGINT,
    rank TEXT NOT NULL DEFAULT 'species'
        CHECK (rank IN ('species', 'genus', 'hybrid')),
    genus TEXT NOT NULL,
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
    updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (release_id, taxon_id),
    UNIQUE (release_id, plant_id)
);

ALTER TABLE public.catalogue_release_species ENABLE ROW LEVEL SECURITY;

-- 3. Authorization guard for privileged catalogue write operations
CREATE OR REPLACE FUNCTION public.assert_catalogue_write_authorized()
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_jwt_role TEXT := COALESCE(NULLIF(current_setting('request.jwt.claim.role', true), ''), '');
BEGIN
    IF current_user IN ('anon', 'authenticated')
       OR v_jwt_role IN ('anon', 'authenticated')
       OR (
           current_user NOT IN ('postgres', 'supabase_admin', 'service_role')
           AND v_jwt_role <> 'service_role'
       )
    THEN
        RAISE EXCEPTION 'catalogue_write_forbidden' USING ERRCODE = '42501';
    END IF;
END;
$$;

-- 4. Materialize a single species snapshot into active `catalogue_taxa`, `taxon_names`,
--    `taxon_external_ids`, and `catalogue_media` for a published release.
CREATE OR REPLACE FUNCTION public.sync_active_catalogue_taxon_from_snapshot(
    p_release_id UUID,
    p_release_ver TEXT,
    p_snap public.catalogue_release_species
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_lang TEXT;
    v_item JSONB;
    v_alias TEXT;
    v_prop TEXT;
    v_ext_id TEXT;
    v_hero JSONB := p_snap.hero_image;
BEGIN
    UPDATE public.catalogue_taxa
    SET release_id = p_release_id,
        accepted_scientific_name = p_snap.accepted_scientific_name,
        scientific_name = p_snap.scientific_name,
        scientific_name_status = p_snap.scientific_name_status,
        wikidata_id = p_snap.wikidata_id,
        source_revision = p_snap.source_revision,
        rank = p_snap.rank,
        genus = p_snap.genus,
        family = p_snap.family,
        common_names = p_snap.common_names,
        search_aliases = p_snap.search_aliases,
        descriptions = p_snap.descriptions,
        hero_image = p_snap.hero_image,
        watering = p_snap.watering,
        external_taxon_ids = p_snap.external_taxon_ids,
        name_source = p_snap.name_source,
        gaps = p_snap.gaps,
        care_profile_available = p_snap.care_profile_available,
        status = p_snap.status,
        updated_at = clock_timestamp()
    WHERE id = p_snap.taxon_id;

    DELETE FROM public.taxon_names WHERE taxon_id = p_snap.taxon_id;

    INSERT INTO public.taxon_names (
        taxon_id, language, kind, value, normalized_search, source_property, source_revision
    ) VALUES (
        p_snap.taxon_id,
        'la',
        'scientific',
        p_snap.scientific_name,
        public.normalize_catalogue_search_text(p_snap.scientific_name),
        'P225',
        p_snap.source_revision
    )
    ON CONFLICT (taxon_id, language, kind, value) DO NOTHING;

    FOREACH v_lang IN ARRAY ARRAY['en', 'pl'] LOOP
        FOR v_item IN
            SELECT value FROM jsonb_array_elements(COALESCE(p_snap.common_names->v_lang, '[]'::jsonb))
        LOOP
            IF trim(COALESCE(v_item->>'name', '')) <> '' THEN
                INSERT INTO public.taxon_names (
                    taxon_id, language, kind, value, normalized_search,
                    source_property, source_revision, review_status
                ) VALUES (
                    p_snap.taxon_id,
                    v_lang,
                    'common',
                    trim(v_item->>'name'),
                    public.normalize_catalogue_search_text(v_item->>'name'),
                    v_item->>'source_property',
                    (v_item->>'source_revision')::BIGINT,
                    v_item->>'review_status'
                )
                ON CONFLICT (taxon_id, language, kind, value) DO NOTHING;
            END IF;
        END LOOP;

        FOR v_alias IN
            SELECT value FROM jsonb_array_elements_text(COALESCE(p_snap.search_aliases->v_lang, '[]'::jsonb))
        LOOP
            IF trim(COALESCE(v_alias, '')) <> '' THEN
                INSERT INTO public.taxon_names (
                    taxon_id, language, kind, value, normalized_search, source_property
                ) VALUES (
                    p_snap.taxon_id,
                    v_lang,
                    'synonym',
                    trim(v_alias),
                    public.normalize_catalogue_search_text(v_alias),
                    'wikidata_alias'
                )
                ON CONFLICT (taxon_id, language, kind, value) DO NOTHING;
            END IF;
        END LOOP;
    END LOOP;

    IF p_snap.wikidata_id IS NOT NULL AND trim(p_snap.wikidata_id) <> '' THEN
        INSERT INTO public.taxon_external_ids (
            taxon_id, provider, external_id, source_release
        ) VALUES (
            p_snap.taxon_id, 'wikidata', p_snap.wikidata_id, p_release_ver
        )
        ON CONFLICT (provider, external_id, source_release) DO UPDATE
        SET taxon_id = EXCLUDED.taxon_id;
    END IF;

    FOREACH v_prop IN ARRAY ARRAY['P846', 'P961', 'P5037'] LOOP
        FOR v_ext_id IN
            SELECT value FROM jsonb_array_elements_text(COALESCE(p_snap.external_taxon_ids->v_prop, '[]'::jsonb))
        LOOP
            IF trim(COALESCE(v_ext_id, '')) <> '' THEN
                INSERT INTO public.taxon_external_ids (
                    taxon_id, provider, external_id, source_release
                ) VALUES (
                    p_snap.taxon_id, v_prop, trim(v_ext_id), p_release_ver
                )
                ON CONFLICT (provider, external_id, source_release) DO UPDATE
                SET taxon_id = EXCLUDED.taxon_id;
            END IF;
        END LOOP;
    END LOOP;

    DELETE FROM public.catalogue_media WHERE taxon_id = p_snap.taxon_id;

    IF v_hero IS NOT NULL AND jsonb_typeof(v_hero) = 'object' AND v_hero->>'sha256' IS NOT NULL THEN
        INSERT INTO public.catalogue_media (
            taxon_id,
            file_title,
            original_page,
            local_path,
            storage_path,
            sha256,
            width,
            height,
            mime_type,
            byte_size,
            author,
            credit,
            license_id,
            license_url,
            attribution,
            modifications,
            is_hero,
            review_state
        ) VALUES (
            p_snap.taxon_id,
            v_hero->>'file_title',
            COALESCE(v_hero->>'source_page', ''),
            v_hero->>'local_path',
            COALESCE(v_hero->>'storage_path', v_hero->>'local_path'),
            v_hero->>'sha256',
            (v_hero->>'width')::INT,
            (v_hero->>'height')::INT,
            v_hero->>'mime',
            (v_hero->>'bytes')::BIGINT,
            COALESCE(v_hero->>'author', ''),
            v_hero->>'credit',
            COALESCE(v_hero->>'license', ''),
            COALESCE(v_hero->>'license_url', ''),
            COALESCE(v_hero->>'attribution', ''),
            v_hero->>'modifications',
            true,
            CASE WHEN p_snap.status = 'published' THEN 'approved' ELSE 'pending' END
        )
        ON CONFLICT (taxon_id, sha256) DO UPDATE SET
            local_path = EXCLUDED.local_path,
            storage_path = EXCLUDED.storage_path,
            author = EXCLUDED.author,
            license_id = EXCLUDED.license_id,
            license_url = EXCLUDED.license_url,
            attribution = EXCLUDED.attribution,
            review_state = EXCLUDED.review_state;
    END IF;
END;
$$;

-- Canonical JSON Schema, synchronized by knowledge-base/pipeline/sync_catalogue_schema.py.
CREATE OR REPLACE FUNCTION public.catalogue_skeleton_schema()
RETURNS JSONB LANGUAGE sql IMMUTABLE AS $schema$
    SELECT $json${"$schema":"http://json-schema.org/draft-07/schema#","title":"Catalogue skeleton card and import record","$ref":"#/definitions/card","definitions":{"commonName":{"type":"object","properties":{"name":{"type":"string","pattern":"\\S"},"source_property":{"type":"string","pattern":"\\S"},"source_entity":{"type":"string","pattern":"\\S"},"source_page_title":{"type":"string","pattern":"\\S"},"source_revision":{"anyOf":[{"type":"integer","minimum":1,"maximum":9007199254740991},{"type":"null"}]},"evidence":{"type":"string","pattern":"\\S"},"review_status":{"type":"string","pattern":"\\S"}},"required":["name","source_property"],"additionalProperties":true},"commonNames":{"type":"object","properties":{"en":{"type":"array","items":{"$ref":"#/definitions/commonName"}},"pl":{"type":"array","items":{"$ref":"#/definitions/commonName"}}},"required":["en","pl"],"additionalProperties":false},"aliases":{"type":"object","properties":{"en":{"type":"array","items":{"type":"string","pattern":"\\S"}},"pl":{"type":"array","items":{"type":"string","pattern":"\\S"}}},"required":["en","pl"],"additionalProperties":false},"description":{"type":"object","properties":{"text":{"type":"string","pattern":"\\S"},"language":{"enum":["en","pl"]},"source_url":{"type":"string","pattern":"^https://[^\\s/?#]+[^\\s]*$"},"source_revision":{"type":"integer","minimum":1,"maximum":9007199254740991},"article_wikidata_id":{"anyOf":[{"type":"string","pattern":"^Q[1-9][0-9]*$"},{"type":"null"}]},"revision_url":{"type":"string","pattern":"^https://[^\\s/?#]+[^\\s]*$"},"history_url":{"type":"string","pattern":"^https://[^\\s/?#]+[^\\s]*$"},"attribution":{"type":"string","pattern":"\\S"},"license":{"enum":["CC-BY-SA-4.0"]},"license_url":{"type":"string","pattern":"^https://[^\\s/?#]+[^\\s]*$"},"modifications":{"type":"string","pattern":"\\S"},"review_status":{"type":"string","pattern":"\\S"},"translation_source_language":{"enum":["en"]},"taxon_scope":{"type":"string","pattern":"\\S"}},"required":["text","language","source_url","source_revision","revision_url","history_url","attribution","license","license_url","modifications","review_status"],"additionalProperties":true},"descriptions":{"type":"object","properties":{"en":{"allOf":[{"$ref":"#/definitions/description"},{"properties":{"language":{"enum":["en"]}}}]},"pl":{"allOf":[{"$ref":"#/definitions/description"},{"properties":{"language":{"enum":["pl"]}}}]}},"required":["en","pl"],"additionalProperties":false},"hero":{"type":"object","properties":{"file_title":{"type":"string","pattern":"\\S"},"source_page":{"type":"string","pattern":"^https://[^\\s/?#]+[^\\s]*$"},"local_path":{"type":"string","pattern":"\\.(jpg|jpeg|png|webp|JPG|JPEG|PNG|WEBP)$"},"storage_path":{"type":"string","pattern":"\\S"},"sha256":{"type":"string","pattern":"^[0-9a-f]{64}$"},"bytes":{"type":"integer","minimum":1,"maximum":9007199254740991},"width":{"type":"integer","minimum":1,"maximum":9007199254740991},"height":{"type":"integer","minimum":1,"maximum":9007199254740991},"mime":{"enum":["image/jpeg","image/png","image/webp"]},"license":{"type":"string","pattern":"\\S"},"license_url":{"type":"string","pattern":"^https?://[^\\s/?#]+[^\\s]*$"},"author":{"type":"string","pattern":"\\S"},"credit":{"type":"string"},"attribution":{"type":"string","pattern":"\\S"},"modifications":{"type":"string","pattern":"\\S"}},"required":["file_title","source_page","local_path","sha256","bytes","width","height","license","license_url","author","attribution","modifications"],"additionalProperties":true},"watering":{"type":"object","properties":{"intervals_days":{"type":"object","properties":{"spring":{"anyOf":[{"type":"integer","minimum":1,"maximum":365},{"type":"null"}]},"summer":{"anyOf":[{"type":"integer","minimum":1,"maximum":365},{"type":"null"}]},"fall":{"anyOf":[{"type":"integer","minimum":1,"maximum":365},{"type":"null"}]},"winter":{"anyOf":[{"type":"integer","minimum":1,"maximum":365},{"type":"null"}]}},"required":["spring","summer","fall","winter"],"additionalProperties":false},"watering_method":{"anyOf":[{"type":"string","pattern":"\\S"},{"type":"null"}]},"drainage_preference":{"anyOf":[{"type":"string","pattern":"\\S"},{"type":"null"}]},"match_level":{"enum":["species_exact","species_synonym","genus_representative","botanical_group_representative"]},"matched_on":{"type":"string","pattern":"\\S"},"source":{"type":"object","properties":{"id":{"type":"string","pattern":"\\S"},"repository":{"type":"string","pattern":"^https://[^\\s/?#]+[^\\s]*$"},"commit":{"type":"string","pattern":"\\S"},"snapshot_sha256":{"type":"string","pattern":"^[0-9a-f]{64}$"},"plantfolio_id":{"type":"string","pattern":"\\S"},"plantfolio_type_name":{"type":"string"},"plantfolio_common_examples":{"type":"string"}},"required":["id","repository","commit","snapshot_sha256","plantfolio_id"],"additionalProperties":true}},"required":["intervals_days","watering_method","drainage_preference","match_level","matched_on","source"],"additionalProperties":true},"externalIds":{"type":"object","additionalProperties":{"type":"array","items":{"type":"string","pattern":"\\S"}}},"card":{"type":"object","properties":{"taxon_id":{"anyOf":[{"type":"string","pattern":"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"},{"type":"null"}]},"plant_id":{"type":"string","pattern":"^[a-z][a-z0-9_]*$"},"scientific_name":{"type":"string","pattern":"\\S"},"accepted_scientific_name":{"type":"string","pattern":"\\S"},"scientific_name_status":{"type":"string","pattern":"\\S"},"wikidata_id":{"type":"string","pattern":"^Q[1-9][0-9]*$"},"rank":{"enum":["species","genus","hybrid"]},"genus":{"type":"string","pattern":"\\S"},"family":{"type":"string","pattern":"\\S"},"external_taxon_ids":{"$ref":"#/definitions/externalIds"},"localized_name":{"anyOf":[{"type":"string","pattern":"\\S"},{"type":"null"}]},"display_name":{"type":"string","pattern":"\\S"},"common_names":{"$ref":"#/definitions/commonNames"},"search_aliases":{"$ref":"#/definitions/aliases"},"description":{"$ref":"#/definitions/description"},"descriptions":{"$ref":"#/definitions/descriptions"},"hero_image":{"$ref":"#/definitions/hero"},"watering":{"$ref":"#/definitions/watering"},"care_profile_available":{"type":"boolean"},"safety":{"type":"object","properties":{"cat":{"type":"object","properties":{"status":{"enum":["safe","toxic","unknown"]}},"required":["status"],"additionalProperties":false},"dog":{"type":"object","properties":{"status":{"enum":["safe","toxic","unknown"]}},"required":["status"],"additionalProperties":false}},"required":["cat","dog"],"additionalProperties":false},"name_source":{"anyOf":[{"type":"object"},{"type":"null"}]}},"required":["taxon_id","plant_id","scientific_name","accepted_scientific_name","scientific_name_status","wikidata_id","rank","genus","family","external_taxon_ids","localized_name","display_name","common_names","search_aliases","description","descriptions","hero_image","watering","care_profile_available","safety","name_source"],"additionalProperties":false},"record":{"type":"object","properties":{"taxon_id":{"anyOf":[{"type":"string","pattern":"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"},{"type":"null"}]},"plant_id":{"type":"string","pattern":"^[a-z][a-z0-9_]*$"},"scientific_name":{"type":"string","pattern":"\\S"},"scientific_name_status":{"type":"string","pattern":"\\S"},"wikidata_id":{"type":"string","pattern":"^Q[1-9][0-9]*$"},"rank":{"enum":["species","genus","hybrid"]},"genus":{"type":"string","pattern":"\\S"},"family":{"type":"string","pattern":"\\S"},"external_taxon_ids":{"$ref":"#/definitions/externalIds"},"common_names":{"$ref":"#/definitions/commonNames"},"search_aliases":{"$ref":"#/definitions/aliases"},"descriptions":{"$ref":"#/definitions/descriptions"},"hero_image":{"$ref":"#/definitions/hero"},"watering":{"$ref":"#/definitions/watering"},"care_profile_available":{"type":"boolean"},"name_source":{"anyOf":[{"type":"object"},{"type":"null"}]},"source_revision":{"type":"integer","minimum":1,"maximum":9007199254740991},"status":{"enum":["draft","imported_editorial_review_pending","published","deprecated"]},"gaps":{"type":"array","items":{"type":"string","pattern":"\\S"}},"accepted_scientific_name":{"type":"string","pattern":"\\S"}},"required":["plant_id","scientific_name","scientific_name_status","wikidata_id","external_taxon_ids","common_names","search_aliases","descriptions","hero_image","watering","care_profile_available","source_revision"],"additionalProperties":true}}}$json$::jsonb;
$schema$;

-- Implements only the keywords used by the canonical schema (not a general JSON Schema engine).
CREATE OR REPLACE FUNCTION public.catalogue_json_matches_schema(p_value JSONB, p_schema JSONB, p_root JSONB)
RETURNS BOOLEAN LANGUAGE plpgsql IMMUTABLE SET search_path = public AS $$
DECLARE
    v_type TEXT := jsonb_typeof(p_value);
    v_key TEXT;
    v_child JSONB;
    v_rule JSONB;
    v_match BOOLEAN;
BEGIN
    IF p_value IS NULL THEN RETURN false; END IF;
    IF p_schema ? '$ref' THEN
        RETURN public.catalogue_json_matches_schema(p_value,
            p_root #> string_to_array(substr(p_schema->>'$ref', 3), '/'), p_root);
    END IF;
    IF p_schema ? 'anyOf' THEN
        v_match := false;
        FOR v_rule IN SELECT value FROM jsonb_array_elements(p_schema->'anyOf') LOOP
            v_match := v_match OR public.catalogue_json_matches_schema(p_value, v_rule, p_root);
        END LOOP;
        IF NOT v_match THEN RETURN false; END IF;
    END IF;
    IF p_schema ? 'allOf' THEN
        FOR v_rule IN SELECT value FROM jsonb_array_elements(p_schema->'allOf') LOOP
            IF NOT public.catalogue_json_matches_schema(p_value, v_rule, p_root) THEN RETURN false; END IF;
        END LOOP;
    END IF;
    IF p_schema ? 'enum' AND NOT EXISTS (
        SELECT 1 FROM jsonb_array_elements(p_schema->'enum') e WHERE e.value = p_value
    ) THEN RETURN false; END IF;
    IF p_schema ? 'type' THEN
        IF p_schema->>'type' = 'integer' THEN
            IF v_type <> 'number' THEN RETURN false; END IF;
            IF (p_value #>> '{}')::numeric <> trunc((p_value #>> '{}')::numeric) THEN RETURN false; END IF;
        ELSIF v_type <> p_schema->>'type' THEN RETURN false;
        END IF;
    END IF;
    IF v_type = 'number' THEN
        IF p_schema ? 'minimum' AND (p_value #>> '{}')::numeric < (p_schema->>'minimum')::numeric THEN RETURN false; END IF;
        IF p_schema ? 'maximum' AND (p_value #>> '{}')::numeric > (p_schema->>'maximum')::numeric THEN RETURN false; END IF;
    ELSIF v_type = 'string' THEN
        IF p_schema ? 'pattern' AND (p_value #>> '{}') !~ (p_schema->>'pattern') THEN RETURN false; END IF;
    ELSIF v_type = 'array' AND p_schema ? 'items' THEN
        FOR v_child IN SELECT value FROM jsonb_array_elements(p_value) LOOP
            IF NOT public.catalogue_json_matches_schema(v_child, p_schema->'items', p_root) THEN RETURN false; END IF;
        END LOOP;
    ELSIF v_type = 'object' THEN
        FOR v_key IN SELECT jsonb_array_elements_text(COALESCE(p_schema->'required', '[]')) LOOP
            IF NOT (p_value ? v_key) THEN RETURN false; END IF;
        END LOOP;
        FOR v_key, v_child IN SELECT key, value FROM jsonb_each(p_value) LOOP
            IF COALESCE(p_schema->'properties', '{}') ? v_key THEN
                IF NOT public.catalogue_json_matches_schema(v_child, p_schema->'properties'->v_key, p_root) THEN RETURN false; END IF;
            ELSIF p_schema->'additionalProperties' = 'false'::jsonb THEN RETURN false;
            ELSIF jsonb_typeof(p_schema->'additionalProperties') = 'object' THEN
                IF NOT public.catalogue_json_matches_schema(v_child, p_schema->'additionalProperties', p_root) THEN RETURN false; END IF;
            END IF;
        END LOOP;
    END IF;
    RETURN true;
END;
$$;

-- 5. Validate a species record against the canonical catalogue skeleton schema
--    (aligned with `validateAndProjectSkeletonRelease` and `validateCatalogueSkeletonCardContract` in `catalogue/import.ts`).
CREATE OR REPLACE FUNCTION public.validate_catalogue_skeleton_species_record(
    p_record JSONB
)
RETURNS VOID
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
    v_active_seasons INT;
BEGIN
    IF NOT public.catalogue_json_matches_schema(p_record,
        public.catalogue_skeleton_schema()->'definitions'->'record', public.catalogue_skeleton_schema()) THEN
        RAISE EXCEPTION 'invalid_catalogue_species_schema' USING ERRCODE = '22023';
    END IF;
    SELECT count(*) INTO v_active_seasons
    FROM jsonb_each(p_record->'watering'->'intervals_days')
    WHERE jsonb_typeof(value) = 'number';
    IF p_record->'watering'->>'watering_method' IS DISTINCT FROM 'immersion' AND v_active_seasons < 2 THEN
        RAISE EXCEPTION 'invalid_catalogue_watering_intervals' USING ERRCODE = '22023';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.assert_catalogue_snapshot_valid()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
    PERFORM public.validate_catalogue_skeleton_species_record(to_jsonb(NEW));
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_catalogue_snapshot_validate
    BEFORE INSERT OR UPDATE ON public.catalogue_release_species
    FOR EACH ROW EXECUTE FUNCTION public.assert_catalogue_snapshot_valid();

-- 6. Upsert a species record from `catalogue/releases/skeleton-300-v1/plants.json`
--    into `catalogue_release_species` (and into active `catalogue_taxa` ONLY when
--    the target release is currently `published`).
--    Coordinates with `publish_catalogue_release` via transaction-scoped advisory
--    lock (`public.catalogue_releases_mutex`) and `FOR UPDATE` row lock on `catalogue_releases`.
CREATE OR REPLACE FUNCTION public.upsert_catalogue_skeleton_species(
    p_release_id UUID,
    p_record JSONB,
    p_publish BOOLEAN DEFAULT true
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_release RECORD;
    v_taxon_id UUID;
    v_plant_id TEXT := trim(COALESCE(p_record->>'plant_id', ''));
    v_sci_name TEXT := trim(COALESCE(p_record->>'scientific_name', ''));
    v_rank TEXT := COALESCE(p_record->>'rank', 'species');
    v_status TEXT := CASE WHEN p_publish THEN 'published' ELSE COALESCE(p_record->>'status', 'imported_editorial_review_pending') END;
    v_hero JSONB := p_record->'hero_image';
    v_watering JSONB := p_record->'watering';
    v_snap public.catalogue_release_species;
BEGIN
    PERFORM public.assert_catalogue_write_authorized();

    IF p_release_id IS NULL THEN
        RAISE EXCEPTION 'catalogue_release_required' USING ERRCODE = '22023';
    END IF;

    -- Acquire global catalogue release mutex first (same lock order as publish_catalogue_release)
    PERFORM pg_advisory_xact_lock(hashtext('public.catalogue_releases_mutex'));

    SELECT id, version, state
    INTO v_release
    FROM public.catalogue_releases
    WHERE id = p_release_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'catalogue_release_not_found' USING ERRCODE = '22023';
    END IF;

    PERFORM public.validate_catalogue_skeleton_species_record(p_record);

    -- Ensure stable taxon identity exists in catalogue_taxa without overwriting an active release
    SELECT id INTO v_taxon_id
    FROM public.catalogue_taxa
    WHERE plant_id = v_plant_id
    FOR UPDATE;

    IF v_taxon_id IS NULL THEN
        INSERT INTO public.catalogue_taxa (
            release_id,
            plant_id,
            accepted_scientific_name,
            scientific_name,
            scientific_name_status,
            wikidata_id,
            source_revision,
            rank,
            genus,
            family,
            common_names,
            search_aliases,
            descriptions,
            hero_image,
            watering,
            external_taxon_ids,
            name_source,
            gaps,
            care_profile_available,
            status,
            updated_at
        ) VALUES (
            CASE WHEN v_release.state = 'published' THEN p_release_id ELSE NULL END,
            v_plant_id,
            v_sci_name,
            v_sci_name,
            COALESCE(p_record->>'scientific_name_status', 'Wikidata species name; accepted-taxonomy audit pending'),
            p_record->>'wikidata_id',
            (p_record->>'source_revision')::BIGINT,
            v_rank,
            COALESCE(NULLIF(trim(p_record->>'genus'), ''), split_part(v_sci_name, ' ', 1)),
            COALESCE(NULLIF(trim(COALESCE(p_record->>'family', '')), ''), 'unknown'),
            p_record->'common_names',
            p_record->'search_aliases',
            p_record->'descriptions',
            v_hero,
            v_watering,
            COALESCE(p_record->'external_taxon_ids', '{}'::jsonb),
            p_record->'name_source',
            COALESCE(p_record->'gaps', '[]'::jsonb),
            COALESCE((p_record->>'care_profile_available')::BOOLEAN, false),
            CASE WHEN v_release.state = 'published' THEN v_status ELSE 'draft' END,
            clock_timestamp()
        )
        RETURNING id INTO v_taxon_id;
    END IF;

    -- Store release-scoped snapshot in catalogue_release_species
    INSERT INTO public.catalogue_release_species (
        release_id,
        taxon_id,
        plant_id,
        accepted_scientific_name,
        scientific_name,
        scientific_name_status,
        wikidata_id,
        source_revision,
        rank,
        genus,
        family,
        common_names,
        search_aliases,
        descriptions,
        hero_image,
        watering,
        external_taxon_ids,
        name_source,
        gaps,
        care_profile_available,
        status,
        updated_at
    ) VALUES (
        p_release_id,
        v_taxon_id,
        v_plant_id,
        v_sci_name,
        v_sci_name,
        COALESCE(p_record->>'scientific_name_status', 'Wikidata species name; accepted-taxonomy audit pending'),
        p_record->>'wikidata_id',
        (p_record->>'source_revision')::BIGINT,
        v_rank,
        COALESCE(NULLIF(trim(p_record->>'genus'), ''), split_part(v_sci_name, ' ', 1)),
        COALESCE(NULLIF(trim(COALESCE(p_record->>'family', '')), ''), 'unknown'),
        p_record->'common_names',
        p_record->'search_aliases',
        p_record->'descriptions',
        v_hero,
        v_watering,
        COALESCE(p_record->'external_taxon_ids', '{}'::jsonb),
        p_record->'name_source',
        COALESCE(p_record->'gaps', '[]'::jsonb),
        COALESCE((p_record->>'care_profile_available')::BOOLEAN, false),
        v_status,
        clock_timestamp()
    )
    ON CONFLICT (release_id, taxon_id) DO UPDATE SET
        plant_id = EXCLUDED.plant_id,
        accepted_scientific_name = EXCLUDED.accepted_scientific_name,
        scientific_name = EXCLUDED.scientific_name,
        scientific_name_status = EXCLUDED.scientific_name_status,
        wikidata_id = EXCLUDED.wikidata_id,
        source_revision = EXCLUDED.source_revision,
        rank = EXCLUDED.rank,
        genus = EXCLUDED.genus,
        family = EXCLUDED.family,
        common_names = EXCLUDED.common_names,
        search_aliases = EXCLUDED.search_aliases,
        descriptions = EXCLUDED.descriptions,
        hero_image = EXCLUDED.hero_image,
        watering = EXCLUDED.watering,
        external_taxon_ids = EXCLUDED.external_taxon_ids,
        name_source = EXCLUDED.name_source,
        gaps = EXCLUDED.gaps,
        care_profile_available = EXCLUDED.care_profile_available,
        status = EXCLUDED.status,
        updated_at = clock_timestamp()
    RETURNING * INTO v_snap;

    -- Only materialize into active catalogue_taxa / taxon_names / catalogue_media if target release is published
    IF v_release.state = 'published' THEN
        PERFORM public.sync_active_catalogue_taxon_from_snapshot(p_release_id, v_release.version, v_snap);
    END IF;

    RETURN v_taxon_id;
END;
$$;

-- 7. Activate/switch a catalogue release snapshot atomically (publish or rollback)
CREATE OR REPLACE FUNCTION public.lock_catalogue_releases_mutex()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    PERFORM pg_advisory_xact_lock(hashtext('public.catalogue_releases_mutex'));
    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_catalogue_releases_lock_mutex ON public.catalogue_releases;
CREATE TRIGGER trg_catalogue_releases_lock_mutex
    BEFORE INSERT OR UPDATE OR DELETE ON public.catalogue_releases
    FOR EACH STATEMENT
    EXECUTE FUNCTION public.lock_catalogue_releases_mutex();

CREATE OR REPLACE FUNCTION public.activate_catalogue_release_snapshot()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_snap public.catalogue_release_species;
BEGIN
    IF NEW.state = 'published' AND (TG_OP = 'INSERT' OR OLD.state IS DISTINCT FROM 'published') THEN
        IF EXISTS (SELECT 1 FROM public.catalogue_release_species WHERE release_id = NEW.id) THEN
            -- Demote any taxa not present in the newly published release snapshot
            UPDATE public.catalogue_taxa t
            SET status = 'draft',
                updated_at = clock_timestamp()
            WHERE NOT EXISTS (
                SELECT 1
                FROM public.catalogue_release_species crs
                WHERE crs.release_id = NEW.id
                  AND crs.taxon_id = t.id
            );

            UPDATE public.catalogue_media cm
            SET review_state = 'pending'
            WHERE NOT EXISTS (
                SELECT 1
                FROM public.catalogue_release_species crs
                WHERE crs.release_id = NEW.id
                  AND crs.taxon_id = cm.taxon_id
                  AND crs.status = 'published'
            );

            -- Materialize all species snapshots from the newly published release
            FOR v_snap IN
                SELECT * FROM public.catalogue_release_species WHERE release_id = NEW.id
            LOOP
                PERFORM public.validate_catalogue_skeleton_species_record(to_jsonb(v_snap));
                PERFORM public.sync_active_catalogue_taxon_from_snapshot(NEW.id, NEW.version, v_snap);
            END LOOP;
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_catalogue_releases_activate_snapshot ON public.catalogue_releases;
CREATE TRIGGER trg_catalogue_releases_activate_snapshot
    AFTER INSERT OR UPDATE OF state ON public.catalogue_releases
    FOR EACH ROW
    EXECUTE FUNCTION public.activate_catalogue_release_snapshot();

CREATE OR REPLACE FUNCTION public.publish_catalogue_release(p_release_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_target RECORD;
BEGIN
    PERFORM public.assert_catalogue_write_authorized();

    -- Acquire global catalogue release mutex first (same lock order as upsert_catalogue_skeleton_species)
    PERFORM pg_advisory_xact_lock(hashtext('public.catalogue_releases_mutex'));

    SELECT id, version, kb_release_id
    INTO v_target
    FROM public.catalogue_releases
    WHERE id = p_release_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'catalogue_release_not_found' USING ERRCODE = '22023';
    END IF;

    -- Retire any currently published release
    UPDATE public.catalogue_releases
    SET state = 'retired',
        status = 'retired'
    WHERE state = 'published'
      AND id <> p_release_id;

    -- Promote target release to published (fires trg_catalogue_releases_activate_snapshot)
    UPDATE public.catalogue_releases
    SET state = 'published',
        status = 'published',
        published_at = COALESCE(published_at, clock_timestamp())
    WHERE id = p_release_id;

    RETURN jsonb_build_object(
        'release_id', v_target.id,
        'version', v_target.version,
        'state', 'published',
        'kb_release_id', v_target.kb_release_id
    );
END;
$$;

-- 7. Project a species row into the canonical client-safe catalogue card DTO
--    Matches `PublicCatalogueSkeletonCard` in `catalogue/import.ts` and `contracts/api.md`.
CREATE OR REPLACE FUNCTION public.project_catalogue_species_card(
    p_taxon public.catalogue_taxa,
    p_locale TEXT DEFAULT 'en'
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_loc TEXT := CASE WHEN p_locale = 'pl' THEN 'pl' ELSE 'en' END;
    v_sci_name TEXT := COALESCE(p_taxon.accepted_scientific_name, p_taxon.scientific_name);
    v_localized_name TEXT;
    v_description JSONB;
    v_has_care_profile BOOLEAN := COALESCE(p_taxon.care_profile_available, false);
    v_safety JSONB := jsonb_build_object(
        'cat', jsonb_build_object('status', 'unknown'),
        'dog', jsonb_build_object('status', 'unknown')
    );
    v_care_profile RECORD;
BEGIN
    -- Primary common name in the requested locale (null if none; client falls back to scientific_name, never fabricates translation)
    SELECT trim(elem->>'name')
    INTO v_localized_name
    FROM jsonb_array_elements(COALESCE(p_taxon.common_names->v_loc, '[]'::jsonb)) AS elem
    WHERE trim(COALESCE(elem->>'name', '')) <> ''
    LIMIT 1;

    -- Localized description in requested locale, falling back to 'en' with explicit language metadata
    IF p_taxon.descriptions ? v_loc
       AND jsonb_typeof(p_taxon.descriptions->v_loc) = 'object'
       AND trim(COALESCE(p_taxon.descriptions->v_loc->>'text', '')) <> '' THEN
        v_description := p_taxon.descriptions->v_loc;
    ELSIF p_taxon.descriptions ? 'en'
          AND jsonb_typeof(p_taxon.descriptions->'en') = 'object' THEN
        v_description := p_taxon.descriptions->'en';
    ELSE
        v_description := NULL;
    END IF;

    -- Check if a published care_profile exists in an active published kb_release
    SELECT cp.profile
    INTO v_care_profile
    FROM public.care_profiles cp
    JOIN public.kb_releases kr ON kr.id = cp.kb_release_id
    WHERE cp.taxon_id = p_taxon.id
      AND cp.state = 'published'
      AND kr.state = 'published'
    ORDER BY kr.published_at DESC NULLS LAST
    LIMIT 1;

    IF FOUND THEN
        v_has_care_profile := true;
        IF v_care_profile.profile ? 'safety' THEN
            v_safety := v_care_profile.profile->'safety';
        END IF;
    END IF;

    RETURN jsonb_build_object(
        'taxon_id', p_taxon.id,
        'plant_id', p_taxon.plant_id,
        'scientific_name', v_sci_name,
        'accepted_scientific_name', v_sci_name,
        'scientific_name_status', p_taxon.scientific_name_status,
        'wikidata_id', p_taxon.wikidata_id,
        'rank', COALESCE(p_taxon.rank, 'species'),
        'genus', COALESCE(p_taxon.genus, split_part(v_sci_name, ' ', 1)),
        'family', COALESCE(p_taxon.family, 'unknown'),
        'external_taxon_ids', COALESCE(p_taxon.external_taxon_ids, '{}'::jsonb),
        'localized_name', v_localized_name,
        'display_name', COALESCE(v_localized_name, v_sci_name),
        'common_names', COALESCE(p_taxon.common_names, '{"en": [], "pl": []}'::jsonb),
        'search_aliases', COALESCE(p_taxon.search_aliases, '{"en": [], "pl": []}'::jsonb),
        'description', v_description,
        'descriptions', COALESCE(p_taxon.descriptions, '{"en": null, "pl": null}'::jsonb),
        'hero_image', p_taxon.hero_image,
        'watering', p_taxon.watering,
        'care_profile_available', v_has_care_profile,
        'safety', v_safety,
        'name_source', p_taxon.name_source
    );
END;
$$;

-- 8. Search published catalogue species by scientific name, common names (PL/EN),
--    search aliases, genus, or family (case- and diacritic-insensitive).
--    Strictly isolated to the currently active `published` catalogue_releases row.
CREATE OR REPLACE FUNCTION public.search_catalogue_species(
    p_query TEXT DEFAULT NULL,
    p_locale TEXT DEFAULT 'en',
    p_limit INT DEFAULT 50,
    p_offset INT DEFAULT 0
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_norm_q TEXT := public.normalize_catalogue_search_text(p_query);
    v_loc TEXT := CASE WHEN p_locale = 'pl' THEN 'pl' ELSE 'en' END;
    v_lim INT := GREATEST(1, LEAST(COALESCE(p_limit, 50), 200));
    v_off INT := GREATEST(0, COALESCE(p_offset, 0));
    v_release RECORD;
    v_total INT := 0;
    v_items JSONB := '[]'::jsonb;
BEGIN
    SELECT id, version, kb_release_id
    INTO v_release
    FROM public.catalogue_releases
    WHERE state = 'published'
    ORDER BY published_at DESC NULLS LAST, created_at DESC
    LIMIT 1;

    -- If no catalogue release is currently published, return an empty result set
    IF v_release.id IS NULL THEN
        RETURN jsonb_build_object(
            'release_version', NULL,
            'kb_release_id', NULL,
            'locale', v_loc,
            'total', 0,
            'limit', v_lim,
            'offset', v_off,
            'items', '[]'::jsonb
        );
    END IF;

    IF v_norm_q = '' THEN
        SELECT count(*)::INT
        INTO v_total
        FROM public.catalogue_taxa t
        WHERE t.status = 'published'
          AND t.release_id = v_release.id;

        SELECT COALESCE(jsonb_agg(public.project_catalogue_species_card(sub.t, v_loc)), '[]'::jsonb)
        INTO v_items
        FROM (
            SELECT t
            FROM public.catalogue_taxa t
            WHERE t.status = 'published'
              AND t.release_id = v_release.id
            ORDER BY COALESCE(t.accepted_scientific_name, t.scientific_name) ASC
            LIMIT v_lim OFFSET v_off
        ) sub;
    ELSE
        WITH matched AS (
            SELECT
                t.id,
                MIN(
                    CASE
                        WHEN public.normalize_catalogue_search_text(COALESCE(t.accepted_scientific_name, t.scientific_name)) = v_norm_q THEN 1
                        WHEN tn.language = v_loc AND tn.kind = 'common' AND tn.normalized_search = v_norm_q THEN 2
                        WHEN tn.normalized_search = v_norm_q THEN 3
                        WHEN public.normalize_catalogue_search_text(COALESCE(t.accepted_scientific_name, t.scientific_name)) LIKE v_norm_q || '%' THEN 4
                        WHEN tn.language = v_loc AND tn.kind = 'common' AND tn.normalized_search LIKE v_norm_q || '%' THEN 5
                        WHEN tn.normalized_search LIKE v_norm_q || '%' THEN 6
                        WHEN public.normalize_catalogue_search_text(COALESCE(t.genus, '')) = v_norm_q THEN 7
                        WHEN public.normalize_catalogue_search_text(COALESCE(t.family, '')) = v_norm_q THEN 8
                        WHEN public.normalize_catalogue_search_text(COALESCE(t.accepted_scientific_name, t.scientific_name)) LIKE '%' || v_norm_q || '%' THEN 9
                        ELSE 10
                    END
                ) AS best_rank
            FROM public.catalogue_taxa t
            LEFT JOIN public.taxon_names tn ON tn.taxon_id = t.id
            WHERE t.status = 'published'
              AND t.release_id = v_release.id
              AND (
                  public.normalize_catalogue_search_text(COALESCE(t.accepted_scientific_name, t.scientific_name)) LIKE '%' || v_norm_q || '%'
                  OR tn.normalized_search LIKE '%' || v_norm_q || '%'
                  OR public.normalize_catalogue_search_text(COALESCE(t.genus, '')) LIKE '%' || v_norm_q || '%'
                  OR public.normalize_catalogue_search_text(COALESCE(t.family, '')) LIKE '%' || v_norm_q || '%'
                  OR t.plant_id LIKE '%' || replace(v_norm_q, ' ', '_') || '%'
              )
            GROUP BY t.id
        )
        SELECT
            (SELECT count(*)::INT FROM matched),
            COALESCE((
                SELECT jsonb_agg(public.project_catalogue_species_card(t, v_loc))
                FROM (
                    SELECT t.*
                    FROM matched m
                    JOIN public.catalogue_taxa t ON t.id = m.id
                    ORDER BY m.best_rank ASC, COALESCE(t.accepted_scientific_name, t.scientific_name) ASC
                    LIMIT v_lim OFFSET v_off
                ) t
            ), '[]'::jsonb)
        INTO v_total, v_items;
    END IF;

    RETURN jsonb_build_object(
        'release_version', v_release.version,
        'kb_release_id', v_release.kb_release_id,
        'locale', v_loc,
        'total', COALESCE(v_total, 0),
        'limit', v_lim,
        'offset', v_off,
        'items', COALESCE(v_items, '[]'::jsonb)
    );
END;
$$;

-- 9. Get a single published species card by taxon UUID or plant_id slug
--    Strictly isolated to the currently active `published` catalogue_releases row.
CREATE OR REPLACE FUNCTION public.get_catalogue_species_card(
    p_identifier TEXT,
    p_locale TEXT DEFAULT 'en'
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_active_release_id UUID;
    v_taxon public.catalogue_taxa;
    v_uuid UUID := NULL;
BEGIN
    IF p_identifier IS NULL OR trim(p_identifier) = '' THEN
        RETURN NULL;
    END IF;

    SELECT id
    INTO v_active_release_id
    FROM public.catalogue_releases
    WHERE state = 'published'
    ORDER BY published_at DESC NULLS LAST, created_at DESC
    LIMIT 1;

    IF v_active_release_id IS NULL THEN
        RETURN NULL;
    END IF;

    IF trim(p_identifier) ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
        v_uuid := trim(p_identifier)::UUID;
    END IF;

    SELECT *
    INTO v_taxon
    FROM public.catalogue_taxa t
    WHERE t.status = 'published'
      AND t.release_id = v_active_release_id
      AND (
          (v_uuid IS NOT NULL AND t.id = v_uuid)
          OR t.plant_id = lower(trim(p_identifier))
      )
    LIMIT 1;

    IF NOT FOUND THEN
        RETURN NULL;
    END IF;

    RETURN public.project_catalogue_species_card(v_taxon, p_locale);
END;
$$;

-- 10. Explicitly lock down SECURITY DEFINER write/internal functions from PUBLIC, anon, and authenticated
REVOKE ALL ON FUNCTION public.assert_catalogue_write_authorized() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.validate_catalogue_skeleton_species_record(JSONB) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.sync_active_catalogue_taxon_from_snapshot(UUID, TEXT, public.catalogue_release_species) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.upsert_catalogue_skeleton_species(UUID, JSONB, BOOLEAN) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.publish_catalogue_release(UUID) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.assert_catalogue_write_authorized() TO service_role;
GRANT EXECUTE ON FUNCTION public.validate_catalogue_skeleton_species_record(JSONB) TO service_role;
GRANT EXECUTE ON FUNCTION public.sync_active_catalogue_taxon_from_snapshot(UUID, TEXT, public.catalogue_release_species) TO service_role;
GRANT EXECUTE ON FUNCTION public.upsert_catalogue_skeleton_species(UUID, JSONB, BOOLEAN) TO service_role;
GRANT EXECUTE ON FUNCTION public.publish_catalogue_release(UUID) TO service_role;

GRANT EXECUTE ON FUNCTION public.normalize_catalogue_search_text(TEXT) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.project_catalogue_species_card(public.catalogue_taxa, TEXT) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.search_catalogue_species(TEXT, TEXT, INT, INT) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_catalogue_species_card(TEXT, TEXT) TO anon, authenticated, service_role;
