-- ============================================================================
-- pgTAP / SQL Test Suite: supabase/tests/catalogue_skeleton.test.sql
-- Task: T147 (Decoupled basic catalogue release without full KB release,
--             role-locked SECURITY DEFINER write functions, release staging
--             isolation & atomic switch/rollback, strict sha256/watering
--             validation, EN/PL descriptions & common names, diacritic/family
--             search, and species <-> plant instance link)
-- Coverage: FR-014, FR-042, FR-043, FR-044, FR-048
-- ============================================================================

BEGIN;
SELECT plan(235);

-- 1. Ensure zero kb_releases / care_profiles exist
SELECT is(
    (SELECT count(*)::int FROM public.kb_releases),
    0,
    'Database starts with zero kb_releases (no full care/condition KB published)'
);

-- 2. When no catalogue_releases is published, search returns 0 and card lookup returns NULL
SELECT is(
    (SELECT (public.search_catalogue_species(NULL, 'pl', 10, 0)->>'total')::int = 0
        AND public.get_catalogue_species_card('monstera_deliciosa', 'pl') IS NULL),
    true,
    'When no catalogue release is published, search returns 0 and get_catalogue_species_card returns NULL'
);

-- 3. Create release v1 in DRAFT state first (kb_release_id = NULL)
INSERT INTO public.catalogue_releases (
    id, version, schema_version, source_hash, state, published_at, kb_release_id
) VALUES (
    '00000000-0000-0000-0000-000000000701',
    'skeleton-300-v1',
    'catalogue-skeleton-1.1',
    repeat('a', 64),
    'draft',
    NULL,
    NULL
);

-- 4. Verify anon and authenticated roles are forbidden from calling SECURITY DEFINER write functions
SET LOCAL ROLE anon;
SELECT throws_ok(
    $$SELECT public.upsert_catalogue_skeleton_species('00000000-0000-0000-0000-000000000701', '{"plant_id":"hack","scientific_name":"Hack sp"}'::jsonb, true)$$,
    '42501',
    NULL,
    'anon role is denied EXECUTE on upsert_catalogue_skeleton_species'
);
RESET ROLE;

SET LOCAL ROLE authenticated;
SELECT throws_ok(
    $$SELECT public.publish_catalogue_release('00000000-0000-0000-0000-000000000701')$$,
    '42501',
    NULL,
    'authenticated role is denied EXECUTE on publish_catalogue_release'
);
RESET ROLE;

-- 5. Verify upsert_catalogue_skeleton_species rejects invalid sha256 and invalid watering intervals
SELECT throws_ok(
    $$SELECT public.upsert_catalogue_skeleton_species(
        '00000000-0000-0000-0000-000000000701',
        '{
          "plant_id": "bad_hash_plant",
          "scientific_name": "Badus hashus",
          "hero_image": {
            "sha256": "not-a-hash",
            "author": "Botanist",
            "license_url": "https://creativecommons.org/licenses/by-sa/4.0/"
          }
        }'::jsonb,
        true
    )$$,
    '22023',
    NULL,
    'upsert_catalogue_skeleton_species rejects invalid hero_image.sha256'
);

SELECT throws_ok(
    $$SELECT public.upsert_catalogue_skeleton_species(
        '00000000-0000-0000-0000-000000000701',
        '{
          "plant_id": "bad_watering_plant",
          "scientific_name": "Badus waterus",
          "watering": {
            "intervals_days": {"spring": -7, "summer": "bad", "fall": 0, "winter": null}
          }
        }'::jsonb,
        true
    )$$,
    '22023',
    NULL,
    'upsert_catalogue_skeleton_species rejects invalid watering.intervals_days values'
);

SELECT throws_ok(
    $$SELECT public.upsert_catalogue_skeleton_species(
        '00000000-0000-0000-0000-000000000701',
        '{
          "plant_id": "bad_wikidata_plant",
          "scientific_name": "Badus wikidatus",
          "wikidata_id": "not-wikidata",
          "source_revision": 123,
          "family": "Araceae",
          "common_names": {"en": [], "pl": []},
          "search_aliases": {"en": [], "pl": []}
        }'::jsonb,
        true
    )$$,
    '22023',
    NULL,
    'upsert_catalogue_skeleton_species rejects invalid wikidata_id (not-wikidata)'
);

SELECT throws_ok(
    $$SELECT public.upsert_catalogue_skeleton_species(
        '00000000-0000-0000-0000-000000000701',
        '{
          "plant_id": "bad_desc_lang_plant",
          "scientific_name": "Badus langus",
          "wikidata_id": "Q161077",
          "source_revision": 123,
          "family": "Araceae",
          "common_names": {"en": [], "pl": []},
          "search_aliases": {"en": [], "pl": []},
          "descriptions": {
            "en": {
              "text": "Test",
              "language": "fr",
              "source_url": "https://en.wikipedia.org/wiki/Test",
              "source_revision": 1,
              "revision_url": "https://en.wikipedia.org/w/index.php?oldid=1",
              "history_url": "https://en.wikipedia.org/wiki/Test?action=history",
              "attribution": "Wikipedia",
              "license": "CC-BY-SA-4.0",
              "license_url": "https://creativecommons.org/licenses/by-sa/4.0/",
              "modifications": "None",
              "review_status": "imported_intro_editorial_review_pending"
            },
            "pl": {
              "text": "Test PL",
              "language": "pl",
              "source_url": "https://pl.wikipedia.org/wiki/Test",
              "source_revision": 1,
              "revision_url": "https://pl.wikipedia.org/w/index.php?oldid=1",
              "history_url": "https://pl.wikipedia.org/wiki/Test?action=history",
              "attribution": "Wikipedia",
              "license": "CC-BY-SA-4.0",
              "license_url": "https://creativecommons.org/licenses/by-sa/4.0/",
              "modifications": "None",
              "review_status": "imported_intro_editorial_review_pending"
            }
          }
        }'::jsonb,
        true
    )$$,
    '22023',
    NULL,
    'upsert_catalogue_skeleton_species rejects mismatched descriptions.en.language = fr'
);

SELECT throws_ok(
    $$SELECT public.upsert_catalogue_skeleton_species(
        '00000000-0000-0000-0000-000000000701',
        '{
          "plant_id": "bad_hero_width_plant",
          "scientific_name": "Badus widthus",
          "wikidata_id": "Q161077",
          "source_revision": 123,
          "family": "Araceae",
          "common_names": {"en": [], "pl": []},
          "search_aliases": {"en": [], "pl": []},
          "descriptions": {
            "en": {
              "text": "Test",
              "language": "en",
              "source_url": "https://en.wikipedia.org/wiki/Test",
              "source_revision": 1,
              "revision_url": "https://en.wikipedia.org/w/index.php?oldid=1",
              "history_url": "https://en.wikipedia.org/wiki/Test?action=history",
              "attribution": "Wikipedia",
              "license": "CC-BY-SA-4.0",
              "license_url": "https://creativecommons.org/licenses/by-sa/4.0/",
              "modifications": "None",
              "review_status": "imported_intro_editorial_review_pending"
            },
            "pl": {
              "text": "Test PL",
              "language": "pl",
              "source_url": "https://pl.wikipedia.org/wiki/Test",
              "source_revision": 1,
              "revision_url": "https://pl.wikipedia.org/w/index.php?oldid=1",
              "history_url": "https://pl.wikipedia.org/wiki/Test?action=history",
              "attribution": "Wikipedia",
              "license": "CC-BY-SA-4.0",
              "license_url": "https://creativecommons.org/licenses/by-sa/4.0/",
              "modifications": "None",
              "review_status": "imported_intro_editorial_review_pending"
            }
          },
          "hero_image": {
            "file_title": "File:Test.jpg",
            "source_page": "https://commons.wikimedia.org/wiki/File:Test.jpg",
            "local_path": "catalogue/releases/skeleton-300-v1/media/test.jpg",
            "sha256": "1111111111111111111111111111111111111111111111111111111111111111",
            "bytes": 245000,
            "width": -1,
            "height": 720,
            "mime": "image/jpeg",
            "license": "CC BY-SA 3.0",
            "license_url": "https://creativecommons.org/licenses/by-sa/3.0/",
            "author": "Raul654",
            "attribution": "Raul654",
            "modifications": "None"
          }
        }'::jsonb,
        true
    )$$,
    '22023',
    NULL,
    'upsert_catalogue_skeleton_species rejects negative hero_image.width (-1)'
);

-- 6. Stage two species into DRAFT release v1 (even with p_publish = true)
SELECT lives_ok(
    $$SELECT public.upsert_catalogue_skeleton_species(
        '00000000-0000-0000-0000-000000000701',
        '{
          "plant_id": "monstera_deliciosa",
          "scientific_name": "Monstera deliciosa",
          "scientific_name_status": "Wikidata species name; accepted-taxonomy audit pending",
          "wikidata_id": "Q161077",
          "source_revision": 2270001,
          "family": "Araceae",
          "external_taxon_ids": {"P846": ["2868241"], "P961": ["60446273-2"], "P5037": ["urn:lsid:ipni.org:names:60446273-2"]},
          "common_names": {
            "en": [{"name": "Swiss cheese plant", "source_property": "P1843"}],
            "pl": [{"name": "Monstera dziurawa", "source_property": "label"}]
          },
          "search_aliases": {
            "en": ["Hurricane plant", "Ceriman"],
            "pl": ["Monstera wonna"]
          },
          "descriptions": {
            "en": {
              "text": "Monstera deliciosa is a species of flowering plant native to tropical forests of southern Mexico.",
              "language": "en",
              "source_url": "https://en.wikipedia.org/wiki/Monstera_deliciosa",
              "source_revision": 1250001,
              "revision_url": "https://en.wikipedia.org/w/index.php?oldid=1250001",
              "history_url": "https://en.wikipedia.org/wiki/Monstera_deliciosa?action=history",
              "attribution": "Wikipedia contributors, Monstera deliciosa",
              "license": "CC-BY-SA-4.0",
              "license_url": "https://creativecommons.org/licenses/by-sa/4.0/",
              "modifications": "Plain-text introductory section extracted by the Wikimedia API; not translated.",
              "review_status": "imported_intro_editorial_review_pending"
            },
            "pl": {
              "text": "Monstera dziurawa – gatunek rośliny z rodziny obrazkowatych.",
              "language": "pl",
              "source_url": "https://pl.wikipedia.org/wiki/Monstera_dziurawa",
              "source_revision": 740001,
              "revision_url": "https://pl.wikipedia.org/w/index.php?oldid=740001",
              "history_url": "https://pl.wikipedia.org/wiki/Monstera_dziurawa?action=history",
              "attribution": "Wikipedia contributors, Monstera dziurawa",
              "license": "CC-BY-SA-4.0",
              "license_url": "https://creativecommons.org/licenses/by-sa/4.0/",
              "modifications": "Plain-text introductory section extracted by the Wikimedia API; not translated.",
              "review_status": "imported_intro_editorial_review_pending"
            }
          },
          "hero_image": {
            "file_title": "File:Monstera deliciosa.jpg",
            "source_page": "https://commons.wikimedia.org/wiki/File:Monstera_deliciosa.jpg",
            "local_path": "catalogue/releases/skeleton-300-v1/media/monstera_deliciosa.jpg",
            "sha256": "1111111111111111111111111111111111111111111111111111111111111111",
            "bytes": 245000,
            "width": 960,
            "height": 720,
            "mime": "image/jpeg",
            "license": "CC BY-SA 3.0",
            "license_url": "https://creativecommons.org/licenses/by-sa/3.0/",
            "author": "Raul654",
            "attribution": "File:Monstera deliciosa.jpg — Raul654 / Wikimedia Commons / CC BY-SA 3.0",
            "modifications": "Wikimedia-resized thumbnail; no crop or other edit by Narat."
          },
          "watering": {
            "intervals_days": {"spring": 7, "summer": 7, "fall": 10, "winter": 14},
            "watering_method": "topWatering",
            "drainage_preference": "wellDraining",
            "match_level": "species_exact",
            "matched_on": "Monstera deliciosa",
            "source": {
              "id": "plantfolio_common_plants",
              "repository": "https://github.com/Luminoid/plantfolio-common-plants",
              "commit": "bbb364534cfbca28168085897ac9f2ff00a151a5",
              "snapshot_sha256": "432de43b36cefacc8a6ebb1d3b1f76836f2fac906e4a9da38e1de76aa3f36efd",
              "plantfolio_id": "swiss-cheese-plant"
            }
          },
          "care_profile_available": false
        }'::jsonb,
        true
    )$$,
    'upsert_catalogue_skeleton_species stages Monstera deliciosa into draft release v1'
);

SELECT lives_ok(
    $$SELECT public.upsert_catalogue_skeleton_species(
        '00000000-0000-0000-0000-000000000701',
        '{
          "plant_id": "aglaonema_commutatum",
          "scientific_name": "Aglaonema commutatum",
          "scientific_name_status": "Wikidata species name; accepted-taxonomy audit pending",
          "wikidata_id": "Q2717691",
          "source_revision": 2270002,
          "family": "Araceae",
          "external_taxon_ids": {},
          "common_names": {
            "en": [{"name": "Chinese evergreen", "source_property": "wikipedia_intro"}],
            "pl": []
          },
          "search_aliases": {
            "en": [],
            "pl": ["Chiński wieczniezielony"]
          },
          "descriptions": {
            "en": {
              "text": "Aglaonema commutatum is a species of flowering plant in the arum family Araceae.",
              "language": "en",
              "source_url": "https://en.wikipedia.org/wiki/Aglaonema_commutatum",
              "source_revision": 1190001,
              "revision_url": "https://en.wikipedia.org/w/index.php?oldid=1190001",
              "history_url": "https://en.wikipedia.org/wiki/Aglaonema_commutatum?action=history",
              "attribution": "Wikipedia contributors, Aglaonema commutatum",
              "license": "CC-BY-SA-4.0",
              "license_url": "https://creativecommons.org/licenses/by-sa/4.0/",
              "modifications": "Plain-text introductory section extracted by the Wikimedia API; not translated.",
              "review_status": "imported_intro_editorial_review_pending"
            },
            "pl": {
              "text": "Aglaonema commutatum to gatunek rośliny zielnej z rodziny obrazkowatych (Araceae).",
              "language": "pl",
              "source_url": "https://en.wikipedia.org/wiki/Aglaonema_commutatum",
              "source_revision": 1190001,
              "revision_url": "https://en.wikipedia.org/w/index.php?oldid=1190001",
              "history_url": "https://en.wikipedia.org/wiki/Aglaonema_commutatum?action=history",
              "attribution": "Wikipedia contributors, Aglaonema commutatum (Polish translation)",
              "license": "CC-BY-SA-4.0",
              "license_url": "https://creativecommons.org/licenses/by-sa/4.0/",
              "modifications": "Translated into Polish from the English Wikipedia introductory section under CC BY-SA 4.0.",
              "translation_source_language": "en",
              "review_status": "translated_intro_editorial_review_pending"
            }
          },
          "hero_image": {
            "file_title": "File:Aglaonema commutatum.jpg",
            "source_page": "https://commons.wikimedia.org/wiki/File:Aglaonema_commutatum.jpg",
            "local_path": "catalogue/releases/skeleton-300-v1/media/aglaonema_commutatum.jpg",
            "sha256": "2222222222222222222222222222222222222222222222222222222222222222",
            "bytes": 198000,
            "width": 800,
            "height": 600,
            "mime": "image/jpeg",
            "license": "CC BY-SA 4.0",
            "license_url": "https://creativecommons.org/licenses/by-sa/4.0/",
            "author": "Botanist",
            "attribution": "File:Aglaonema commutatum.jpg — Botanist / Wikimedia Commons / CC BY-SA 4.0",
            "modifications": "Wikimedia-resized thumbnail; no crop or other edit by Narat."
          },
          "watering": {
            "intervals_days": {"spring": 7, "summer": 7, "fall": 10, "winter": 14},
            "watering_method": "topWatering",
            "drainage_preference": "wellDraining",
            "match_level": "genus_representative",
            "matched_on": "Aglaonema",
            "source": {
              "id": "plantfolio_common_plants",
              "repository": "https://github.com/Luminoid/plantfolio-common-plants",
              "commit": "bbb364534cfbca28168085897ac9f2ff00a151a5",
              "snapshot_sha256": "432de43b36cefacc8a6ebb1d3b1f76836f2fac906e4a9da38e1de76aa3f36efd",
              "plantfolio_id": "aglaonema"
            }
          },
          "care_profile_available": false
        }'::jsonb,
        true
    )$$,
    'upsert_catalogue_skeleton_species stages Aglaonema commutatum into draft release v1'
);

-- 7. While release v1 is still DRAFT, neither search nor get_catalogue_species_card exposes staged species
SELECT is(
    (SELECT (public.search_catalogue_species('Monstera', 'pl', 10, 0)->>'total')::int = 0
        AND public.get_catalogue_species_card('monstera_deliciosa', 'pl') IS NULL),
    true,
    'Species staged into a DRAFT release are not visible in search or get_catalogue_species_card'
);

-- 8. Publish release v1 atomically (with kb_release_id = NULL)
SELECT is(
    (public.publish_catalogue_release('00000000-0000-0000-0000-000000000701')->>'state'),
    'published',
    'publish_catalogue_release activates release v1'
);

SELECT is(
    (SELECT kb_release_id IS NULL AND state = 'published'
     FROM public.catalogue_releases
     WHERE id = '00000000-0000-0000-0000-000000000701'),
    true,
    'catalogue_releases v1 is published with kb_release_id = NULL'
);

-- 9. Search by Polish common name returns Monstera dziurawa
SELECT is(
    (SELECT (public.search_catalogue_species('Monstera dziurawa', 'pl', 10, 0)->'items'->0->>'plant_id')),
    'monstera_deliciosa',
    'search_catalogue_species finds Monstera by Polish common name'
);

-- 10. Search by English alias returns Monstera deliciosa
SELECT is(
    (SELECT (public.search_catalogue_species('Hurricane plant', 'en', 10, 0)->'items'->0->>'plant_id')),
    'monstera_deliciosa',
    'search_catalogue_species finds Monstera by English search alias'
);

-- 11. Diacritic-insensitive search: 'chinski wieczniezielony' matches 'Chiński wieczniezielony'
SELECT is(
    (SELECT (public.search_catalogue_species('chinski wieczniezielony', 'pl', 10, 0)->'items'->0->>'plant_id')),
    'aglaonema_commutatum',
    'search_catalogue_species matches Polish alias without diacritics (chinski -> Chiński)'
);

-- 12. Family search: 'Araceae' finds both published Araceae species
SELECT is(
    (SELECT (public.search_catalogue_species('Araceae', 'en', 10, 0)->>'total')::int),
    2,
    'search_catalogue_species matches species by botanical family (Araceae)'
);

-- 13. Species without a PL common name keeps localized_name = NULL and display_name = scientific_name (no fabricated translation)
SELECT is(
    (SELECT (public.get_catalogue_species_card('aglaonema_commutatum', 'pl')->>'localized_name') IS NULL
        AND (public.get_catalogue_species_card('aglaonema_commutatum', 'pl')->>'display_name') = 'Aglaonema commutatum'
        AND (public.get_catalogue_species_card('aglaonema_commutatum', 'pl')->'description'->>'translation_source_language') = 'en'),
    true,
    'get_catalogue_species_card falls back to scientific_name when PL common name is absent and returns translated PL description'
);

-- 14. Watering intervals, Commons attribution, and all 21 canonical keys are present in the species card
SELECT is(
    (SELECT (public.get_catalogue_species_card('monstera_deliciosa', 'pl')->'watering'->'intervals_days'->>'spring')::int = 7
        AND (public.get_catalogue_species_card('monstera_deliciosa', 'pl')->'hero_image'->>'author') = 'Raul654'
        AND (public.get_catalogue_species_card('monstera_deliciosa', 'pl')->>'care_profile_available')::boolean = false
        AND (public.get_catalogue_species_card('monstera_deliciosa', 'pl')->>'accepted_scientific_name') = 'Monstera deliciosa'
        AND (public.get_catalogue_species_card('monstera_deliciosa', 'pl')->>'rank') = 'species'),
    true,
    'Species card includes Plantfolio watering intervals, Commons attribution, and canonical 21-key DTO fields'
);

-- 15. Stage a second release v2 in DRAFT state that modifies monstera_deliciosa and adds ficus_elastica
INSERT INTO public.catalogue_releases (
    id, version, schema_version, source_hash, state, published_at, kb_release_id
) VALUES (
    '00000000-0000-0000-0000-000000000702',
    'skeleton-300-v2-draft',
    'catalogue-skeleton-1.1',
    repeat('b', 64),
    'draft',
    NULL,
    NULL
);

SELECT lives_ok(
    $$SELECT public.upsert_catalogue_skeleton_species(
        '00000000-0000-0000-0000-000000000702',
        '{
          "plant_id": "monstera_deliciosa",
          "scientific_name": "Monstera deliciosa",
          "scientific_name_status": "Wikidata species name; accepted-taxonomy audit pending",
          "external_taxon_ids": {}, "care_profile_available": false,
          "wikidata_id": "Q161077",
          "source_revision": 2270099,
          "family": "Araceae",
          "common_names": {"en": [{"name": "Swiss cheese plant", "source_property": "P1843"}], "pl": [{"name": "Monstera dziurawa", "source_property": "label"}]},
          "search_aliases": {"en": [], "pl": []},
          "descriptions": {
            "en": {"text": "Updated v2 EN.", "language": "en", "source_url": "https://en.wikipedia.org/wiki/Monstera_deliciosa", "source_revision": 1250002, "revision_url": "https://en.wikipedia.org/w/index.php?oldid=1250002", "history_url": "https://en.wikipedia.org/wiki/Monstera_deliciosa?action=history", "attribution": "Wikipedia", "license": "CC-BY-SA-4.0", "license_url": "https://creativecommons.org/licenses/by-sa/4.0/", "modifications": "None", "review_status": "imported_intro_editorial_review_pending"},
            "pl": {"text": "Wersja 2 draft opisu Monstery.", "language": "pl", "source_url": "https://pl.wikipedia.org/wiki/Monstera_dziurawa", "source_revision": 740002, "revision_url": "https://pl.wikipedia.org/w/index.php?oldid=740002", "history_url": "https://pl.wikipedia.org/wiki/Monstera_dziurawa?action=history", "attribution": "Wikipedia", "license": "CC-BY-SA-4.0", "license_url": "https://creativecommons.org/licenses/by-sa/4.0/", "modifications": "None", "review_status": "imported_intro_editorial_review_pending"}
          },
          "hero_image": {
            "file_title": "File:Monstera deliciosa.jpg",
            "source_page": "https://commons.wikimedia.org/wiki/File:Monstera_deliciosa.jpg",
            "local_path": "catalogue/releases/skeleton-300-v1/media/monstera_deliciosa.jpg",
            "sha256": "1111111111111111111111111111111111111111111111111111111111111111",
            "bytes": 245000, "width": 960, "height": 720, "mime": "image/jpeg",
            "license": "CC BY-SA 3.0", "license_url": "https://creativecommons.org/licenses/by-sa/3.0/",
            "author": "Raul654", "attribution": "Raul654", "modifications": "None"
          },
          "watering": {
            "intervals_days": {"spring": 5, "summer": 5, "fall": 8, "winter": 12},
            "watering_method": "topWatering", "drainage_preference": "wellDraining",
            "match_level": "species_exact", "matched_on": "Monstera deliciosa",
            "source": {"id": "plantfolio_common_plants", "repository": "https://github.com/Luminoid/plantfolio-common-plants", "commit": "bbb3645", "snapshot_sha256": "432de43b36cefacc8a6ebb1d3b1f76836f2fac906e4a9da38e1de76aa3f36efd", "plantfolio_id": "swiss-cheese-plant"}
          }
        }'::jsonb,
        true
    )$$,
    'Staging modified Monstera deliciosa into draft release v2 succeeds'
);

SELECT lives_ok(
    $$SELECT public.upsert_catalogue_skeleton_species(
        '00000000-0000-0000-0000-000000000702',
        '{
          "plant_id": "ficus_elastica",
          "scientific_name": "Ficus elastica",
          "scientific_name_status": "Wikidata species name; accepted-taxonomy audit pending",
          "external_taxon_ids": {}, "care_profile_available": false,
          "wikidata_id": "Q157953",
          "source_revision": 2270100,
          "family": "Moraceae",
          "common_names": {"en": [{"name": "Rubber fig", "source_property": "P1843"}], "pl": [{"name": "Figowiec sprężysty", "source_property": "label"}]},
          "search_aliases": {"en": [], "pl": []},
          "descriptions": {
            "en": {"text": "Ficus elastica is a species of fig.", "language": "en", "source_url": "https://en.wikipedia.org/wiki/Ficus_elastica", "source_revision": 1250003, "revision_url": "https://en.wikipedia.org/w/index.php?oldid=1250003", "history_url": "https://en.wikipedia.org/wiki/Ficus_elastica?action=history", "attribution": "Wikipedia", "license": "CC-BY-SA-4.0", "license_url": "https://creativecommons.org/licenses/by-sa/4.0/", "modifications": "None", "review_status": "imported_intro_editorial_review_pending"},
            "pl": {"text": "Figowiec sprężysty – gatunek rośliny z rodziny morwowatych.", "language": "pl", "source_url": "https://pl.wikipedia.org/wiki/Figowiec_spr%C4%99%C5%BCysty", "source_revision": 740003, "revision_url": "https://pl.wikipedia.org/w/index.php?oldid=740003", "history_url": "https://pl.wikipedia.org/wiki/Figowiec_spr%C4%99%C5%BCysty?action=history", "attribution": "Wikipedia", "license": "CC-BY-SA-4.0", "license_url": "https://creativecommons.org/licenses/by-sa/4.0/", "modifications": "None", "review_status": "imported_intro_editorial_review_pending"}
          },
          "hero_image": {
            "file_title": "File:Ficus elastica.jpg",
            "source_page": "https://commons.wikimedia.org/wiki/File:Ficus_elastica.jpg",
            "local_path": "catalogue/releases/skeleton-300-v1/media/ficus_elastica.jpg",
            "sha256": "3333333333333333333333333333333333333333333333333333333333333333",
            "bytes": 210000, "width": 960, "height": 720, "mime": "image/jpeg",
            "license": "CC BY-SA 4.0", "license_url": "https://creativecommons.org/licenses/by-sa/4.0/",
            "author": "Botanist", "attribution": "Botanist", "modifications": "None"
          },
          "watering": {
            "intervals_days": {"spring": 7, "summer": 7, "fall": 10, "winter": 14},
            "watering_method": "topWatering", "drainage_preference": "wellDraining",
            "match_level": "species_exact", "matched_on": "Ficus elastica",
            "source": {"id": "plantfolio_common_plants", "repository": "https://github.com/Luminoid/plantfolio-common-plants", "commit": "bbb3645", "snapshot_sha256": "432de43b36cefacc8a6ebb1d3b1f76836f2fac906e4a9da38e1de76aa3f36efd", "plantfolio_id": "rubber-plant"}
          }
        }'::jsonb,
        true
    )$$,
    'Staging new species Ficus elastica into draft release v2 succeeds'
);

-- 16. Verify staging isolation: while v2 is DRAFT, Monstera keeps v1 text/watering and Ficus elastica is invisible
SELECT is(
    (SELECT (public.get_catalogue_species_card('monstera_deliciosa', 'pl')->'description'->>'text') = 'Monstera dziurawa – gatunek rośliny z rodziny obrazkowatych.'
        AND (public.get_catalogue_species_card('monstera_deliciosa', 'pl')->'watering'->'intervals_days'->>'spring')::int = 7
        AND public.get_catalogue_species_card('ficus_elastica', 'pl') IS NULL
        AND (public.search_catalogue_species('Ficus', 'pl', 10, 0)->>'total')::int = 0),
    true,
    'Staging draft release v2 does not overwrite active v1 Monstera snapshot and does not expose draft-only Ficus elastica'
);

-- 17. Atomically switch active release from v1 to v2 and verify v2 snapshot is active
DO $$
BEGIN
    PERFORM public.publish_catalogue_release('00000000-0000-0000-0000-000000000702');
END;
$$;

SELECT is(
    (SELECT (public.get_catalogue_species_card('monstera_deliciosa', 'pl')->'description'->>'text') = 'Wersja 2 draft opisu Monstery.'
        AND (public.get_catalogue_species_card('monstera_deliciosa', 'pl')->'watering'->'intervals_days'->>'spring')::int = 5
        AND (public.get_catalogue_species_card('ficus_elastica', 'pl')->>'plant_id') = 'ficus_elastica'
        AND public.get_catalogue_species_card('aglaonema_commutatum', 'pl') IS NULL),
    true,
    'Publishing v2 atomically switches Monstera to v2 snapshot, exposes Ficus elastica, and hides species omitted from v2'
);

-- 18. Roll back from v2 to v1 and verify v1 snapshot is restored intact
DO $$
BEGIN
    PERFORM public.publish_catalogue_release('00000000-0000-0000-0000-000000000701');
END;
$$;

SELECT is(
    (SELECT (public.get_catalogue_species_card('monstera_deliciosa', 'pl')->'description'->>'text') = 'Monstera dziurawa – gatunek rośliny z rodziny obrazkowatych.'
        AND (public.get_catalogue_species_card('monstera_deliciosa', 'pl')->'watering'->'intervals_days'->>'spring')::int = 7
        AND (public.get_catalogue_species_card('aglaonema_commutatum', 'pl')->>'plant_id') = 'aglaonema_commutatum'
        AND public.get_catalogue_species_card('ficus_elastica', 'pl') IS NULL),
    true,
    'Rolling back to v1 restores v1 Monstera & Aglaonema snapshots and hides retired v2 Ficus elastica'
);

-- Client roles own these temp tables but cannot attach the privileged trigger.
SET LOCAL ROLE anon;
CREATE TEMP TABLE shadow_anon(id uuid, version text, state text);
SELECT throws_ok($q$CREATE TRIGGER forged AFTER INSERT ON shadow_anon FOR EACH ROW
    EXECUTE FUNCTION public.activate_catalogue_release_snapshot()$q$,
    '42501', NULL, 'anon cannot attach activation to its own table');
RESET ROLE;
SET LOCAL ROLE authenticated;
CREATE TEMP TABLE shadow_authenticated(id uuid, version text, state text);
SELECT throws_ok($q$CREATE TRIGGER forged AFTER INSERT ON shadow_authenticated FOR EACH ROW
    EXECUTE FUNCTION public.activate_catalogue_release_snapshot()$q$,
    '42501', NULL, 'authenticated cannot attach activation to its own table');
RESET ROLE;

-- Model a trigger already installed before EXECUTE was revoked.
CREATE TRIGGER legacy_forged AFTER INSERT ON shadow_anon FOR EACH ROW
    EXECUTE FUNCTION public.activate_catalogue_release_snapshot();
SET LOCAL ROLE anon;
SELECT throws_ok($q$INSERT INTO shadow_anon VALUES
    ('00000000-0000-0000-0000-000000000702','v2','published')$q$,
    '42501', 'invalid_catalogue_activation_trigger', 'existing forged trigger is rejected at execution');
RESET ROLE;
SELECT is(public.get_catalogue_species_card('monstera_deliciosa','pl') #>> '{watering,intervals_days,spring}',
    '7', 'failed activation leaves the v1 card intact');

-- Exercise the supported status alias in both directions with overlapping and distinct taxa.
UPDATE public.catalogue_releases SET status = 'retired' WHERE id = '00000000-0000-0000-0000-000000000701';
UPDATE public.catalogue_releases SET status = 'published' WHERE id = '00000000-0000-0000-0000-000000000702';
SELECT ok((public.get_catalogue_species_card('monstera_deliciosa','pl') #>> '{watering,intervals_days,spring}') = '5'
    AND (public.search_catalogue_species('Ficus','pl')->>'total') = '1'
    AND public.get_catalogue_species_card('aglaonema_commutatum','pl') IS NULL,
    'status-only publication exposes v2 in search and card lookup');
UPDATE public.catalogue_releases SET status = 'retired' WHERE id = '00000000-0000-0000-0000-000000000702';
UPDATE public.catalogue_releases SET status = 'published' WHERE id = '00000000-0000-0000-0000-000000000701';
SELECT ok((public.get_catalogue_species_card('monstera_deliciosa','pl') #>> '{watering,intervals_days,spring}') = '7'
    AND (public.search_catalogue_species('Ficus','pl')->>'total') = '0'
    AND public.get_catalogue_species_card('aglaonema_commutatum','pl') IS NOT NULL,
    'status-only rollback restores v1 in search and card lookup');

-- 19. Save a user plant instance from the catalogue without care profile, without condition questions, and without personal photo
INSERT INTO public.profiles (id, account_state, anonymous, preferred_locale)
VALUES ('00000000-0000-0000-0000-000000000705', 'active', false, 'pl');

-- Attempting to save a retired species (ficus_elastica from retired v2) from catalogue must fail
SELECT throws_ok(
    $$SELECT public.execute_plant_create_command(
        '00000000-0000-0000-0000-000000000705',
        '00000000-0000-0000-0000-000000000799',
        '{"creation_source":"catalogue","creation_intent":"care","add_method":"catalogue","plant_id":"ficus_elastica"}'::jsonb,
        TIMESTAMPTZ '2026-11-05T12:04:00Z'
    )$$,
    'P0002',
    NULL,
    'execute_plant_create_command rejects species belonging to a retired/non-active release'
);

CREATE TEMP TABLE cat_save_out AS
SELECT public.execute_plant_create_command(
    '00000000-0000-0000-0000-000000000705',
    '00000000-0000-0000-0000-000000000706',
    '{
      "creation_source": "catalogue",
      "creation_intent": "care",
      "add_method": "catalogue",
      "plant_id": "monstera_deliciosa"
    }'::jsonb,
    TIMESTAMPTZ '2026-11-05T12:05:00Z'
) AS res;

SELECT is(
    (SELECT res->>'plan_availability' FROM cat_save_out),
    'care_profile_unavailable',
    'Saving from catalogue without care_profile returns plan_availability = care_profile_unavailable'
);

SELECT is(
    (SELECT res->>'next_available_step' FROM cat_save_out),
    'view_plant',
    'Saving from catalogue without care_profile returns next_available_step = view_plant'
);

SELECT is(
    (SELECT p.personal_name = 'Monstera dziurawa'
        AND p.plant_id = 'monstera_deliciosa'
        AND p.taxon_id IS NOT NULL
        AND p.main_photo_id IS NULL
        AND p.current_condition_snapshot_id IS NULL
     FROM public.plants p
     WHERE p.id = (SELECT (res->>'plant_id')::uuid FROM cat_save_out)),
    true,
    'Catalogue plant instance links taxon_id & plant_id, defaults personal_name to locale common name, and leaves main_photo_id and current_condition_snapshot_id NULL'
);

-- 20. Save a user plant instance with a personal photo (scan -> confirm species -> save) and verify species hero_image is unchanged
INSERT INTO public.photo_assets (
    id, owner_id, purpose, original_key, content_hash, uploaded_at, state
) VALUES (
    '00000000-0000-0000-0000-000000000707',
    '00000000-0000-0000-0000-000000000705',
    'initial',
    'owners/00000000-0000-0000-0000-000000000705/photos/user_monstera.jpg',
    repeat('f', 64),
    TIMESTAMPTZ '2026-11-05T12:06:00Z',
    'ready'
);

CREATE TEMP TABLE scan_cat_save_out AS
SELECT public.execute_plant_create_command(
    '00000000-0000-0000-0000-000000000705',
    '00000000-0000-0000-0000-000000000708',
    '{
      "creation_source": "catalogue",
      "creation_intent": "care",
      "add_method": "scan",
      "plant_id": "monstera_deliciosa",
      "photo_id": "00000000-0000-0000-0000-000000000707",
      "personal_name": "Moja Monstera w salonie"
    }'::jsonb,
    TIMESTAMPTZ '2026-11-05T12:06:30Z'
) AS res;

SELECT is(
    (SELECT p.main_photo_id = '00000000-0000-0000-0000-000000000707'::uuid
        AND pa.plant_id = p.id
     FROM public.plants p
     JOIN public.photo_assets pa ON pa.id = p.main_photo_id
     WHERE p.id = (SELECT (res->>'plant_id')::uuid FROM scan_cat_save_out)),
    true,
    'User personal photo is attached as main_photo_id on the user plant instance'
);

SELECT is(
    (SELECT (public.get_catalogue_species_card('monstera_deliciosa', 'pl')->'hero_image'->>'local_path') = 'catalogue/releases/skeleton-300-v1/media/monstera_deliciosa.jpg'
        AND (SELECT count(*)::int FROM public.owner_sync_entries
             WHERE owner_id = '00000000-0000-0000-0000-000000000705'
               AND entity_type = 'plants'
               AND data->>'plant_id' = 'monstera_deliciosa') = 2),
    true,
    'Species catalogue hero_image remains unchanged by user personal photo and both saved plants appear in owner_sync_entries'
);

-- Independent mutations start from a valid snapshot; no earlier invalid field masks a test.
CREATE TEMP TABLE catalogue_contract_base AS SELECT to_jsonb(s) AS record,
    public.get_catalogue_species_card(s.plant_id, 'en') AS card
FROM public.catalogue_release_species s
WHERE s.release_id = '00000000-0000-0000-0000-000000000701' AND s.plant_id = 'monstera_deliciosa';
CREATE TEMP TABLE catalogue_invalid_inputs(path TEXT[], invalid JSONB);
INSERT INTO catalogue_invalid_inputs VALUES
    (ARRAY['taxon_id'], '42'::jsonb),
    (ARRAY['wikidata_id'], '"not-wikidata"'::jsonb),
    (ARRAY['common_names'], '"oops"'::jsonb),
    (ARRAY['care_profile_available'], '"yes"'::jsonb),
    (ARRAY['scientific_name'], '42'::jsonb),
    (ARRAY['scientific_name_status'], 'false'::jsonb),
    (ARRAY['rank'], '"invalid"'::jsonb),
    (ARRAY['genus'], '42'::jsonb),
    (ARRAY['family'], '[]'::jsonb),
    (ARRAY['external_taxon_ids','P846'], '[42]'::jsonb),
    (ARRAY['common_names','en'], '{}'::jsonb),
    (ARRAY['common_names','pl'], '{}'::jsonb),
    (ARRAY['common_names','en','0','name'], '42'::jsonb),
    (ARRAY['common_names','en','0','source_property'], 'false'::jsonb),
    (ARRAY['common_names','en','0','source_revision'], '"oops"'::jsonb),
    (ARRAY['search_aliases','en'], '[42]'::jsonb),
    (ARRAY['search_aliases','pl'], '"oops"'::jsonb),
    (ARRAY['descriptions','en','language'], '"fr"'::jsonb),
    (ARRAY['descriptions','pl','language'], '"en"'::jsonb),
    (ARRAY['name_source'], '"oops"'::jsonb),
    (ARRAY['descriptions','en','text'], '0'::jsonb),
    (ARRAY['descriptions','en','source_url'], '0'::jsonb),
    (ARRAY['descriptions','en','source_revision'], '0'::jsonb),
    (ARRAY['descriptions','en','revision_url'], '0'::jsonb),
    (ARRAY['descriptions','en','history_url'], '0'::jsonb),
    (ARRAY['descriptions','en','attribution'], '0'::jsonb),
    (ARRAY['descriptions','en','license'], '0'::jsonb),
    (ARRAY['descriptions','en','license_url'], '0'::jsonb),
    (ARRAY['descriptions','en','modifications'], '0'::jsonb),
    (ARRAY['descriptions','en','review_status'], '0'::jsonb),
    (ARRAY['descriptions','pl','text'], '0'::jsonb),
    (ARRAY['descriptions','pl','source_url'], '0'::jsonb),
    (ARRAY['descriptions','pl','source_revision'], '0'::jsonb),
    (ARRAY['descriptions','pl','revision_url'], '0'::jsonb),
    (ARRAY['descriptions','pl','history_url'], '0'::jsonb),
    (ARRAY['descriptions','pl','attribution'], '0'::jsonb),
    (ARRAY['descriptions','pl','license'], '0'::jsonb),
    (ARRAY['descriptions','pl','license_url'], '0'::jsonb),
    (ARRAY['descriptions','pl','modifications'], '0'::jsonb),
    (ARRAY['descriptions','pl','review_status'], '0'::jsonb),
    (ARRAY['hero_image','file_title'], '42'::jsonb),
    (ARRAY['hero_image','source_page'], '42'::jsonb),
    (ARRAY['hero_image','local_path'], '42'::jsonb),
    (ARRAY['hero_image','sha256'], '42'::jsonb),
    (ARRAY['hero_image','bytes'], '-1'::jsonb),
    (ARRAY['hero_image','width'], '-1'::jsonb),
    (ARRAY['hero_image','height'], '-1'::jsonb),
    (ARRAY['hero_image','license'], '42'::jsonb),
    (ARRAY['hero_image','license_url'], '42'::jsonb),
    (ARRAY['hero_image','author'], '42'::jsonb),
    (ARRAY['hero_image','attribution'], '42'::jsonb),
    (ARRAY['hero_image','modifications'], '42'::jsonb),
    (ARRAY['hero_image','sha256'], '"not-a-hash"'::jsonb),
    (ARRAY['hero_image','mime'], '"image/gif"'::jsonb),
    (ARRAY['hero_image','source_page'], '"https://"'::jsonb),
    (ARRAY['hero_image','license_url'], '"javascript:bad"'::jsonb),
    (ARRAY['watering','intervals_days','spring'], '-1'::jsonb),
    (ARRAY['watering','intervals_days','summer'], '"7"'::jsonb),
    (ARRAY['watering','intervals_days','fall'], '366'::jsonb),
    (ARRAY['watering','intervals_days','winter'], '1.5'::jsonb),
    (ARRAY['watering','watering_method'], '42'::jsonb),
    (ARRAY['watering','drainage_preference'], 'false'::jsonb),
    (ARRAY['watering','match_level'], '"guessed"'::jsonb),
    (ARRAY['watering','matched_on'], '42'::jsonb),
    (ARRAY['watering','source','id'], '42'::jsonb),
    (ARRAY['watering','source','repository'], '42'::jsonb),
    (ARRAY['watering','source','commit'], '42'::jsonb),
    (ARRAY['watering','source','snapshot_sha256'], '42'::jsonb),
    (ARRAY['watering','source','plantfolio_id'], '42'::jsonb);
SELECT throws_ok(format('SELECT public.upsert_catalogue_skeleton_species(%L, %L::jsonb, true)',
    '00000000-0000-0000-0000-000000000701', jsonb_set(b.record, i.path, i.invalid)),
    '22023', NULL, 'Independent SQL input rejection: ' || array_to_string(i.path, '.'))
FROM catalogue_invalid_inputs i CROSS JOIN catalogue_contract_base b;
SELECT is(public.catalogue_json_matches_schema(jsonb_set(b.card, i.path, i.invalid),
    public.catalogue_skeleton_schema()->'definitions'->'card', public.catalogue_skeleton_schema()),
    false, 'Independent SQL DTO rejection: ' || array_to_string(i.path, '.'))
FROM catalogue_invalid_inputs i CROSS JOIN catalogue_contract_base b;
SELECT is(public.catalogue_json_matches_schema(b.card - k,
    public.catalogue_skeleton_schema()->'definitions'->'card', public.catalogue_skeleton_schema()),
    false, 'DTO required key: ' || k)
FROM catalogue_contract_base b, jsonb_object_keys(b.card) k;
SELECT is(public.catalogue_json_matches_schema(jsonb_set(b.card, ARRAY[k], '[]'::jsonb),
    public.catalogue_skeleton_schema()->'definitions'->'card', public.catalogue_skeleton_schema()),
    false, 'DTO wrong type: ' || k)
FROM catalogue_contract_base b, jsonb_object_keys(b.card) k;
SELECT throws_ok(format('SELECT public.upsert_catalogue_skeleton_species(%L, %L::jsonb, true)',
    '00000000-0000-0000-0000-000000000701', b.record - k),
    '22023', NULL, 'Required SQL record key: ' || k)
FROM catalogue_contract_base b, jsonb_array_elements_text(public.catalogue_skeleton_schema()->'definitions'->'record'->'required') k;
SELECT lives_ok(format('SELECT public.validate_catalogue_skeleton_species_record(%L::jsonb)',
    jsonb_set(record, '{watering,intervals_days,winter}', 'null'::jsonb)), 'Nullable winter accepted') FROM catalogue_contract_base;
SELECT throws_ok(format('SELECT public.validate_catalogue_skeleton_species_record(%L::jsonb)',
    jsonb_set(record, '{watering,intervals_days}', '{"spring":null,"summer":null,"fall":null,"winter":null}'::jsonb)),
    '22023', NULL, 'Non-immersion requires at least two numeric seasons') FROM catalogue_contract_base;
SELECT lives_ok(format('SELECT public.validate_catalogue_skeleton_species_record(%L::jsonb)',
    jsonb_set(jsonb_set(record, '{watering,intervals_days}', '{"spring":null,"summer":null,"fall":null,"winter":null}'::jsonb),
        '{watering,watering_method}', '"immersion"'::jsonb)), 'Immersion accepts all null seasons') FROM catalogue_contract_base;
SELECT throws_ok($q$UPDATE public.catalogue_release_species SET hero_image = jsonb_set(hero_image, '{width}', '-1')
    WHERE release_id = '00000000-0000-0000-0000-000000000701' AND plant_id = 'monstera_deliciosa'$q$,
    '22023', NULL, 'Direct snapshot mutation cannot bypass schema');
-- Simulate a legacy/corrupt snapshot written before validation existed.
ALTER TABLE public.catalogue_release_species DISABLE TRIGGER trg_catalogue_snapshot_validate;
UPDATE public.catalogue_release_species SET hero_image = jsonb_set(hero_image, '{width}', '-1')
    WHERE release_id = '00000000-0000-0000-0000-000000000702' AND plant_id = 'monstera_deliciosa';
ALTER TABLE public.catalogue_release_species ENABLE TRIGGER trg_catalogue_snapshot_validate;
SELECT throws_ok($q$SELECT public.publish_catalogue_release('00000000-0000-0000-0000-000000000702')$q$,
    '22023', NULL, 'Publishing revalidates legacy snapshots and rejects corruption');
SELECT is((SELECT version FROM public.catalogue_releases WHERE state = 'published'), 'skeleton-300-v1',
    'Failed publication keeps the previous release active');

SELECT * FROM finish();
ROLLBACK;
