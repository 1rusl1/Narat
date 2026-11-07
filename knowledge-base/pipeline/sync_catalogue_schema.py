"""Embed the canonical catalogue JSON Schema in its SQL migration; --check detects drift."""
import argparse
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCHEMA = ROOT / 'specs/001-plants-ios-mvp/contracts/catalogue-skeleton.schema.json'
MIGRATION = ROOT / 'supabase/migrations/202611050001_catalogue_skeleton.sql'

def check_keywords(schema):
    """Fail closed if a schema change requires extending the SQL interpreter."""
    supported = {'$schema', 'title', '$ref', 'definitions', 'type', 'properties',
                 'required', 'additionalProperties', 'items', 'enum', 'pattern',
                 'minimum', 'maximum', 'anyOf', 'allOf'}
    unknown = set(schema) - supported
    if unknown:
        raise SystemExit(f'Unsupported SQL schema keywords: {sorted(unknown)}')
    for key in ['definitions', 'properties']:
        for child in schema.get(key, {}).values():
            check_keywords(child)
    for key in ['anyOf', 'allOf']:
        for child in schema.get(key, []):
            check_keywords(child)
    for key in ['additionalProperties', 'items']:
        if isinstance(schema.get(key), dict):
            check_keywords(schema[key])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    value = json.loads(SCHEMA.read_text())
    check_keywords(value)
    sql = MIGRATION.read_text()
    pattern = r'(?<=SELECT \$json\$).*?(?=\$json\$::jsonb;)'
    match = re.search(pattern, sql, re.S)
    if match is None:
        raise SystemExit('Missing embedded catalogue schema')
    if args.check:
        if json.loads(match.group()) != value:
            raise SystemExit('Catalogue SQL/JSON schema drift; run sync_catalogue_schema.py')
        print('Catalogue SQL/JSON schema parity: PASS')
    else:
        replacement = json.dumps(value, ensure_ascii=False, separators=(',', ':'))
        MIGRATION.write_text(sql[:match.start()] + replacement + sql[match.end():])

if __name__ == '__main__':
    main()
