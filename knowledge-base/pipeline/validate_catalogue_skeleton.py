"""Validate the downloaded catalogue independently of ingestion (no network)."""
from collections import Counter
import hashlib
import json
import re
from pathlib import Path
import sqlite3
from contextlib import closing

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / 'catalogue/releases/skeleton-300-v1'
PLANTFOLIO_DIR = ROOT / 'knowledge-base/references/personal/watering/plantfolio-common-plants'
WIKIDATA_P225_CORRECTIONS = {
    'Q137455': 'Heptapleurum arboricola',
    'Q15314417': 'Alocasia micholitziana',
}


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def check_snapshot(metadata):
    path = ROOT / metadata['snapshot']
    assert digest(path) == metadata['sha256'], path
    return json.loads(path.read_text())


def main():
    payload = json.loads((OUT / 'plants.json').read_text())
    plants = payload['plants']
    manifest = json.loads((OUT / 'manifest.json').read_text())
    record_count = manifest['records']
    assert record_count >= 300
    pf_manifest = json.loads((PLANTFOLIO_DIR / 'manifest.json').read_text())
    pf_dist_path = PLANTFOLIO_DIR / 'dist/common_plants.json'
    pf_dist_sha = digest(pf_dist_path)
    pf_expected_sha = next(f['sha256'] for f in pf_manifest['files'] if f['path'] == 'dist/common_plants.json')
    assert pf_dist_sha == pf_expected_sha
    pf_by_id = {p['id']: p for p in json.loads(pf_dist_path.read_text()) if 'id' in p}
    pl_translations_path = ROOT / 'knowledge-base/manifests/pl-description-translations.json'
    pl_translations = json.loads(pl_translations_path.read_text()) if pl_translations_path.exists() else {}
    assert len(plants) == record_count
    assert len({p['plant_id'] for p in plants}) == record_count
    assert len({p['wikidata_id'] for p in plants}) == record_count
    assert len({p['scientific_name'].casefold() for p in plants}) == record_count
    assert digest(OUT / 'plants.json') == manifest['plants_sha256']
    assert digest(OUT / 'coverage.json') == manifest['coverage_sha256']
    for prop in ('P846', 'P961', 'P5037'):
        external = [str(v) for p in plants for v in p.get('external_taxon_ids', {}).get(prop, [])]
        assert len(external) == len(set(external)), f'Duplicate external taxon ID: {prop}'
    media_manifest = {m['path']: m['sha256'] for m in manifest['media']}
    for plant in plants:
        source = check_snapshot(plant['name_source']['snapshot'])
        entity = source['entities'][plant['wikidata_id']]
        assert entity['lastrevid'] == plant['source_revision']
        names = [s['mainsnak'].get('datavalue', {}).get('value') for s in entity['claims']['P225'] if s.get('rank') != 'deprecated']
        expected_corrected = WIKIDATA_P225_CORRECTIONS.get(plant['wikidata_id'])
        assert plant['scientific_name'] in names or plant['scientific_name'] == expected_corrected
        assert plant['descriptions']['en']['text'].strip()
        normalized_intro = re.sub(r'\s+', ' ', plant['descriptions']['en']['text']).casefold()
        for name in plant['common_names']['en']:
            if name['source_property'] == 'wikipedia_intro':
                assert name['name'].casefold() in normalized_intro, name
                assert name['source_revision'] == plant['descriptions']['en']['source_revision']
        for language, description in plant['descriptions'].items():
            if not description:
                assert 'description_' + language in plant['gaps']
                continue
            assert description['language'] == language
            assert description['license'] == 'CC-BY-SA-4.0'
            assert description['source_revision']
            assert description['history_url'] and description['attribution']
            matching = []
            for meta in description['snapshots']:
                doc = check_snapshot(meta)
                matching.extend(p for p in doc['query']['pages'] if p.get('extract') and
                    p.get('revisions', [{}])[0].get('revid') == description['source_revision'])
            if description.get('translation_source_language') == 'en':
                assert language == 'pl'
                assert description['source_revision'] == plant['descriptions']['en']['source_revision']
                assert matching, plant['plant_id']
                pl_entry = pl_translations[plant['plant_id']]
                assert pl_entry['source_revision'] == description['source_revision']
                expected_pl = '\n\n'.join(s.strip() for s in pl_entry['pl_text'].split('\n') if s.strip())
                assert description['text'] == expected_pl, plant['plant_id']
            else:
                assert any('\n\n'.join(s.strip() for s in p['extract'].split('\n') if s.strip()) == description['text'] for p in matching), plant['plant_id']
        image = plant['hero_image']
        assert image['author'] and image['license_url'] and image['source_page']
        assert digest(ROOT / image['local_path']) == image['sha256'] == media_manifest[image['local_path']]
        check_snapshot(image['metadata_snapshot'])
        watering = plant.get('watering')
        if watering is None:
            assert 'watering' in plant['gaps']
        else:
            assert 'watering' not in plant['gaps']
            assert watering['match_level'] in (
                'species_exact',
                'species_synonym',
                'genus_representative',
                'botanical_group_representative',
            )
            assert watering['matched_on']
            src = watering['source']
            assert src['id'] == 'plantfolio_common_plants'
            assert src['commit'] == pf_manifest['commit']
            assert src['snapshot_sha256'] == pf_dist_sha
            pf_entry = pf_by_id[src['plantfolio_id']]
            assert watering['intervals_days'] == {
                'spring': pf_entry.get('springInterval'),
                'summer': pf_entry.get('summerInterval'),
                'fall': pf_entry.get('fallInterval'),
                'winter': pf_entry.get('winterInterval'),
            }
            for v in watering['intervals_days'].values():
                assert v is None or (isinstance(v, int) and 1 <= v <= 90)
            assert watering['watering_method'] == pf_entry.get('wateringMethod')
            assert watering['drainage_preference'] == pf_entry.get('drainagePreference')
        assert not plant['care_profile_available']
    with closing(sqlite3.connect(ROOT / 'knowledge-base/staging/catalogue-300.sqlite')) as db:
        assert db.execute('PRAGMA integrity_check').fetchone()[0] == 'ok'
        rows = {row[0]: json.loads(row[1]) for row in db.execute('SELECT plant_id,payload_json FROM catalogue_skeleton')}
        assert len(rows) == record_count
        assert all(rows[p['plant_id']] == p for p in plants)
    image_counts = Counter(p['hero_image']['sha256'] for p in plants)
    watering_counts = Counter((p.get('watering') or {}).get('match_level') or 'missing' for p in plants)
    report = {'records': record_count, 'unique_ids': record_count, 'external_taxon_id_duplicates': 'none', 'source_snapshot_hashes': 'pass',
        'text_matches_source_extracts': 'pass', 'local_media_hashes': 'pass',
        'plantfolio_watering_parity': 'pass',
        'watering_coverage': {
            'total_matched': record_count - watering_counts['missing'],
            'species_exact': watering_counts['species_exact'],
            'species_synonym': watering_counts['species_synonym'],
            'genus_representative': watering_counts['genus_representative'],
            'botanical_group_representative': watering_counts['botanical_group_representative'],
            'missing': watering_counts['missing'],
        },
        'sqlite_integrity': 'ok', 'sqlite_json_parity': 'pass',
        'unique_image_files': len(image_counts),
        'shared_images': [[p['plant_id'] for p in plants if p['hero_image']['sha256'] == key] for key, count in image_counts.items() if count > 1],
        'live_download': 'performed separately by importer',
        'live_app_api_storage_ui': 'not_tested', 'editorial_review': 'not_completed'}
    (OUT / 'validation.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
