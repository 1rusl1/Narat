import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'pipeline'))
from import_catalogue_300 import (
    Client,
    common_names,
    description,
    eligible_polish_article,
    intro_common_names,
    match_plantfolio_watering,
    parse_plantfolio_examples,
    permitted_image,
    polish_name_is_eligible,
    reviewed_image,
    taxon,
    translated_description,
    translated_pl_common_names,
)


def entity(name='Monstera deliciosa', rank='Q7432'):
    def claim(value):
        return [{'mainsnak': {'snaktype': 'value', 'datavalue': {'value': value}}}]
    return {'id': 'Q161077', 'claims': {'P225': claim(name), 'P105': claim({'id': rank})},
            'labels': {'en': {'value': name}, 'pl': {'value': 'Monstera dziurawa'}}}


def media(license='CC BY-SA 4.0', author='<a href="/wiki/X">Photographer</a>'):
    return {'title': 'File:Plant.jpg', 'imageinfo': [{'url': 'https://upload.wikimedia.org/plant.jpg',
        'descriptionurl': 'https://commons.wikimedia.org/wiki/File:Plant.jpg', 'width': 1000, 'height': 800,
        'mime': 'image/jpeg', 'extmetadata': {'LicenseShortName': {'value': license},
            'LicenseUrl': {'value': 'https://creativecommons.org/licenses/by-sa/4.0/'},
            'Artist': {'value': author}}}]}


class SkeletonTests(unittest.TestCase):
    def test_reviewed_image_stays_bound_to_original_identity_and_bytes(self):
        root = Path(__file__).resolve().parents[2]
        manifest = root / 'catalogue/manifests/skeleton-300-editorial-media.json'
        entry = json.loads(manifest.read_text())['plants']['hoya_lanceolata']
        image = entry['hero_image']
        original = {'file_title': entry['replaces']}
        self.assertEqual(reviewed_image('hoya_lanceolata', entry['wikidata_id'], original, entry), image)
        with self.assertRaisesRegex(ValueError, 'Editorial source changed'):
            reviewed_image('hoya_lanceolata', 'Q1', original, entry)

        with tempfile.TemporaryDirectory() as tmp:
            temp_root = Path(tmp)
            path = temp_root / image['local_path']
            path.parent.mkdir(parents=True)
            path.write_bytes((root / image['local_path']).read_bytes() + b'changed')
            with patch('import_catalogue_300.ROOT', temp_root), patch('import_catalogue_300.OUT', path.parent.parent):
                with self.assertRaisesRegex(ValueError, 'hash or size mismatch'):
                    reviewed_image('hoya_lanceolata', entry['wikidata_id'], original, entry)

    def test_polish_sources_must_match_the_species_even_with_matching_pageprops(self):
        cases = [('Q2893846', 'Lista gatunków z rodzaju begonia'),
                 ('Q814368', 'Begonia koralowa'), ('Q162311', 'Hoja piękna')]
        for qid, title in cases:
            with self.subTest(qid=qid):
                self.assertIsNone(eligible_polish_article(
                    {'id': qid}, {'title': title, 'pageprops': {'wikibase_item': qid}}))
        page = {'title': 'Monstera dziurawa', 'pageprops': {'wikibase_item': 'Q161077'}}
        self.assertIs(eligible_polish_article({'id': 'Q161077'}, page), page)
        self.assertIsNone(eligible_polish_article({'id': 'Q162311'}, page))
        self.assertFalse(polish_name_is_eligible('Hoya bella', 'Q162311'))
        self.assertTrue(polish_name_is_eligible('Monstera dziurawa', 'Q161077'))

    def test_genus_hybrid_and_ambiguous_name_not_counted_as_species(self):
        self.assertEqual(taxon(entity()), 'Monstera deliciosa')
        self.assertIsNone(taxon(entity(rank='Q34740')))
        self.assertIsNone(taxon(entity(name='Monstera')))
        self.assertIsNone(taxon(entity(name='Alocasia × amazonica')))
        e = entity()
        e['claims']['P225'].append({'mainsnak': {'snaktype': 'value', 'datavalue': {'value': 'Other name'}}})
        self.assertIsNone(taxon(e))

    def test_scientific_label_is_not_common_name(self):
        result = common_names(entity(), 'Monstera deliciosa')
        self.assertEqual(result['en'], [])
        self.assertEqual(result['pl'][0]['name'], 'Monstera dziurawa')

    def test_explicit_common_names_are_deduplicated(self):
        e = entity()
        e['labels']['en']['value'] = 'Swiss cheese plant'
        e['claims']['P1843'] = [{'mainsnak': {'snaktype': 'value', 'datavalue': {
            'value': {'language': 'en', 'text': 'Swiss cheese plant'}}}}]
        self.assertEqual(len(common_names(e, 'Monstera deliciosa')['en']), 1)
        self.assertEqual(common_names(e, 'Monstera deliciosa')['en'][0]['source_property'], 'P1843')

    def test_unknown_nc_nd_media_rejected(self):
        for license in ['CC BY-NC 4.0', 'CC BY-ND 4.0', 'GFDL', 'Unknown', '']:
            self.assertIsNone(permitted_image(media(license)))

    def test_artist_and_restrictions_required(self):
        self.assertIsNone(permitted_image(media(author='')))
        m = media()
        m['imageinfo'][0]['extmetadata']['Restrictions'] = {'value': 'Personality rights'}
        self.assertIsNone(permitted_image(m))

    def test_open_photo_preserves_credit_and_sanitizes_html(self):
        result = permitted_image(media())
        self.assertEqual(result['author'], 'Photographer')
        self.assertEqual(result['license'], 'CC BY-SA 4.0')
        self.assertEqual(result['species_visual_review'], 'pending')

    def test_intro_names_are_grounded_and_synonyms_excluded(self):
        page = {'title': 'Spathiphyllum wallisii', 'revisions': [{'revid': 123}],
                'extract': 'Spathiphyllum wallisii, commonly known as peace lily, white sails, or spathe flower, is a plant.'}
        self.assertEqual([n['name'] for n in intro_common_names(page, [], {'spathiphyllum'})],
                         ['peace lily', 'white sails', 'spathe flower'])
        page['extract'] = 'Goeppertia makoyana, also known as peacock plant, is a plant. Its synonym is Calathea makoyana.'
        result = intro_common_names(page, ['Calathea makoyana'], {'calathea', 'goeppertia'})
        self.assertEqual([n['name'] for n in result], ['peacock plant'])
        page['extract'] = 'Hoya pubicalyx is a species native to the Philippines.'
        self.assertEqual(intro_common_names(page, [], {'hoya'}), [])

    def test_intro_parser_does_not_name_parts_or_latin_synonyms(self):
        page = {'title': 'Dionaea muscipula', 'extract': 'Dionaea muscipula is a plant. Its hairs are known as trigger hairs.'}
        self.assertEqual(intro_common_names(page, [], {'dionaea'}), [])
        page['extract'] = 'Tradescantia zebrina, formerly known as Zebrina pendula, is a plant.'
        self.assertEqual(intro_common_names(page, [], {'tradescantia'}), [])
        page['extract'] = 'Anthurium scherzerianum, the flamingo flower or pigtail plant, is a species.'
        self.assertEqual([n['name'] for n in intro_common_names(page, [], {'anthurium'})],
                         ['flamingo flower', 'pigtail plant'])

    def test_current_commons_thumbnail_host_and_reviewed_author(self):
        m = media(author='')
        m['imageinfo'][0]['thumburl'] = 'https://thumb.wikimedia.org/plant.jpg'
        self.assertIsNone(permitted_image(m))
        result = permitted_image(m, reviewed_author='Previously reviewed creator')
        self.assertEqual(result['author'], 'Previously reviewed creator')
        self.assertIn('thumb.wikimedia.org', result['download_url'])

    def test_non_commons_download_and_non_image_rejected(self):
        m = media()
        m['imageinfo'][0]['url'] = 'https://example.org/not-commons.jpg'
        self.assertIsNone(permitted_image(m))
        m = media()
        m['imageinfo'][0]['mime'] = 'application/pdf'
        self.assertIsNone(permitted_image(m))

    def test_description_keeps_revision_license_and_language(self):
        result = description({'title': 'Monstera deliciosa', 'extract': 'Intro.\n\nSecond paragraph.',
            'revisions': [{'revid': 123}], 'snapshots': []}, 'en')
        self.assertEqual(result['source_revision'], 123)
        self.assertEqual(result['license'], 'CC-BY-SA-4.0')
        self.assertEqual(result['language'], 'en')
        self.assertIsNone(description(None, 'pl'))

    def test_translated_description_requires_matching_revision_and_records_provenance(self):
        page = {'title': 'Monstera deliciosa', 'extract': 'Intro.\n\nSecond paragraph.',
                'revisions': [{'revid': 123}], 'snapshots': [{'snapshot': 'raw.json'}],
                'pageprops': {'wikibase_item': 'Q161077'}}
        pl_entry = {'source_revision': 123, 'pl_text': 'Wstęp.\n\nDrugi akapit.'}
        result = translated_description(page, pl_entry)
        self.assertEqual(result['language'], 'pl')
        self.assertEqual(result['translation_source_language'], 'en')
        self.assertEqual(result['source_revision'], 123)
        self.assertEqual(result['license'], 'CC-BY-SA-4.0')
        self.assertEqual(result['text'], 'Wstęp.\n\nDrugi akapit.')
        self.assertIn('Polish translation', result['attribution'])
        self.assertIsNone(translated_description(page, {'source_revision': 999, 'pl_text': 'Wstęp.'}))

    def test_translated_pl_common_names_requires_matching_revision(self):
        page = {'title': 'Aglaonema commutatum', 'revisions': [{'revid': 456}]}
        item = entity('Aglaonema commutatum')
        matching_entry = {'source_revision': 456, 'pl_common_names': ['Aglaonema zmienny', 'Aglaonema commutatum']}
        added = translated_pl_common_names(page, matching_entry, item, 'Aglaonema commutatum', [], {'aglaonema'})
        self.assertEqual([n['name'] for n in added], [])
        added_non_latin = translated_pl_common_names(page, {'source_revision': 456, 'pl_common_names': ['Chiński wieczniezielony']}, item, 'Aglaonema commutatum', [], {'aglaonema'})
        self.assertEqual([n['name'] for n in added_non_latin], ['Chiński wieczniezielony'])
        self.assertEqual(added_non_latin[0]['source_revision'], 456)
        stale_entry = {'source_revision': 455, 'pl_common_names': ['Chiński wieczniezielony']}
        self.assertEqual(translated_pl_common_names(page, stale_entry, item, 'Aglaonema commutatum', [], {'aglaonema'}), [])

    def test_offline_never_fetches_and_detects_tampered_cache(self):
        with tempfile.TemporaryDirectory() as tmp, patch('import_catalogue_300.urlopen') as network:
            target = Path(tmp) / 'snapshot.json'
            url = 'https://en.wikipedia.org/w/api.php'
            client = Client(offline=True)
            with self.assertRaisesRegex(ValueError, 'Missing offline'):
                client.request(url, target)
            target.write_bytes(b'{}')
            meta = {'url': url, 'sha256': hashlib.sha256(b'{}').hexdigest()}
            target.with_suffix('.json.meta.json').write_text(json.dumps(meta))
            self.assertEqual(client.request(url, target)[0], b'{}')
            target.write_bytes(b'{"changed": true}')
            with self.assertRaisesRegex(ValueError, 'integrity mismatch'):
                client.request(url, target)
            network.assert_not_called()

    def test_plantfolio_parser_handles_nested_synonyms_and_abbreviations(self):
        pb, sb, gen = parse_plantfolio_examples(
            "Heptapleurum actinophyllum (syn. Heptapleurum actinophyllum (syn. Schefflera actinophylla); Umbrella tree), "
            "H. arboricola (syn. S. arboricola; Dwarf umbrella tree)"
        )
        self.assertEqual(pb, ['heptapleurum actinophyllum', 'heptapleurum arboricola'])
        self.assertIn('schefflera actinophylla', sb)
        self.assertIn('schefflera arboricola', sb)
        self.assertIn('heptapleurum', gen)

    def test_plantfolio_matching_distinguishes_exact_synonym_genus_and_missing(self):
        entries = [
            {
                'id': 'swiss-cheese-plant',
                'typeName': 'Swiss Cheese Plant',
                'commonExamples': 'Monstera deliciosa (Swiss cheese plant), M. adansonii',
                'springInterval': 7, 'summerInterval': 7, 'fallInterval': 10, 'winterInterval': 14,
                'wateringMethod': 'topWatering', 'drainagePreference': 'wellDraining',
                'category': 'Houseplants - Aroids',
            },
            {
                'id': 'calathea-orbifolia',
                'typeName': 'Calathea Orbifolia',
                'commonExamples': 'Goeppertia orbifolia (syn. Calathea orbifolia)',
                'springInterval': 4, 'summerInterval': 4, 'fallInterval': 7, 'winterInterval': 10,
                'wateringMethod': 'topWatering', 'drainagePreference': 'moistureRetentive',
                'category': 'Houseplants - Prayer Plants',
            },
        ]
        parsed = {e['id']: parse_plantfolio_examples(e['commonExamples']) for e in entries}
        index = {
            'manifest': {'repository': 'https://github.com/Luminoid/plantfolio-common-plants', 'commit': 'bbb3645'},
            'dist_sha256': 'abc123',
            'by_id': {e['id']: e for e in entries},
            'by_primary': {'monstera deliciosa': [entries[0]], 'monstera adansonii': [entries[0]], 'goeppertia orbifolia': [entries[1]]},
            'by_syn': {'calathea orbifolia': [entries[1]]},
            'parsed': parsed,
        }
        exact = match_plantfolio_watering(
            {'scientific_name': 'Monstera deliciosa', 'common_names': {'en': []}, 'search_aliases': {'en': [], 'pl': []}, 'descriptions': {'en': {'text': ''}}},
            index,
        )
        self.assertEqual(exact['match_level'], 'species_exact')
        self.assertEqual(exact['intervals_days'], {'spring': 7, 'summer': 7, 'fall': 10, 'winter': 14})
        self.assertEqual(exact['source']['plantfolio_id'], 'swiss-cheese-plant')

        syn = match_plantfolio_watering(
            {'scientific_name': 'Calathea orbifolia', 'common_names': {'en': []}, 'search_aliases': {'en': [], 'pl': []}, 'descriptions': {'en': {'text': ''}}},
            index,
        )
        self.assertEqual(syn['match_level'], 'species_synonym')
        self.assertEqual(syn['source']['plantfolio_id'], 'calathea-orbifolia')

        genus_rep = match_plantfolio_watering(
            {'scientific_name': 'Monstera acuminata', 'common_names': {'en': []}, 'search_aliases': {'en': [], 'pl': []}, 'descriptions': {'en': {'text': ''}}},
            index,
        )
        self.assertEqual(genus_rep['match_level'], 'genus_representative')
        self.assertEqual(genus_rep['source']['plantfolio_id'], 'swiss-cheese-plant')

        missing = match_plantfolio_watering(
            {'scientific_name': 'Unknownus plantus', 'common_names': {'en': []}, 'search_aliases': {'en': [], 'pl': []}, 'descriptions': {'en': {'text': ''}}},
            index,
        )
        self.assertIsNone(missing)

        index['by_id']['bromeliads'] = {
            'id': 'bromeliads',
            'typeName': 'Bromeliads',
            'commonExamples': 'Guzmania, Tillandsia, Aechmea, Neoregelia',
            'springInterval': 7, 'summerInterval': 7, 'fallInterval': 10, 'winterInterval': 14,
            'wateringMethod': 'topWatering', 'drainagePreference': 'wellDraining',
            'category': 'Houseplants - Flowering',
        }
        bot_group = match_plantfolio_watering(
            {'scientific_name': 'Cryptanthus bivittatus', 'common_names': {'en': []}, 'search_aliases': {'en': [], 'pl': []}, 'descriptions': {'en': {'text': ''}}},
            index,
        )
        self.assertEqual(bot_group['match_level'], 'botanical_group_representative')
        self.assertEqual(bot_group['source']['plantfolio_id'], 'bromeliads')


if __name__ == '__main__':
    unittest.main()
