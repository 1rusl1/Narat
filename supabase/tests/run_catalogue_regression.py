"""T147: isolated DB, unchanged migrations, real pgTAP, 606-record parity and two-session races.

Requires a running PostgreSQL >=15, psql, Deno and Perl prove. Auth roles must exist.
Pass --pgtap-sql only for the upstream built sql/pgtap.sql; otherwise CREATE EXTENSION is used.
All test data lives in a new database which is dropped on exit. PGHOST/PGPORT/PGUSER apply.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import json
import hashlib
import os
from pathlib import Path
import re
import subprocess
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]

def literal(value):
    return "'" + value.replace("'", "''") + "'"

def json_literal(value):
    return literal(json.dumps(value, ensure_ascii=False)) + '::jsonb'

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--psql', default='psql')
    parser.add_argument('--pgtap-sql', type=Path)
    parser.add_argument('--output-dir', type=Path)
    args = parser.parse_args()
    output = args.output_dir or Path(tempfile.mkdtemp(prefix='t147-regression-'))
    output.mkdir(parents=True, exist_ok=True)
    database = 't147_' + uuid.uuid4().hex
    env = dict(os.environ, PGOPTIONS='-c statement_timeout=20000 -c lock_timeout=10000')
    base = [args.psql, '-X', '-qAt', '-v', 'ON_ERROR_STOP=1']

    def sql(statement, db=database):
        result = subprocess.run(base + ['-d', db], input=statement, text=True,
                                capture_output=True, env=env, timeout=120)
        if result.returncode:
            raise RuntimeError(result.stderr)
        return result.stdout.strip()

    sql(f'CREATE DATABASE {database};', 'postgres')
    try:
        version = sql('SHOW server_version;')
        if int(version.split('.')[0]) < 15:
            raise RuntimeError('PostgreSQL >=15 required; no migration compatibility rewrites allowed')
        sql("CREATE SCHEMA auth; CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$ SELECT NULLIF(current_setting('request.jwt.claim.sub', true), '')::uuid $$; GRANT USAGE ON SCHEMA auth TO PUBLIC;")
        sql("CREATE TABLE auth.users (id uuid PRIMARY KEY, is_anonymous boolean);")
        migrations = sorted((ROOT / 'supabase/migrations').glob('*.sql'))
        with (output / 'migrations.log').open('w') as log:
            for migration in migrations:
                log.write(migration.name + '\n' + sql(migration.read_text()) + '\n')
        print(f'PostgreSQL {version}: {len(migrations)} unchanged migrations PASS', flush=True)
        sql(args.pgtap_sql.read_text() if args.pgtap_sql else 'CREATE EXTENSION pgtap;')
        tap = sql((ROOT / 'supabase/tests/catalogue_skeleton.test.sql').read_text()) + '\n'
        tap_path = output / 'catalogue.tap'
        tap_path.write_text(tap)
        plan = re.findall(r'^1\.\.(\d+)$', tap, re.M)
        assertions = re.findall(r'^(?:not )?ok \d+', tap, re.M)
        if len(plan) != 1 or int(plan[0]) != len(assertions):
            raise RuntimeError(f'TAP plan mismatch: {plan}, assertions={len(assertions)}')
        subprocess.run(['prove', '--exec', 'cat', str(tap_path)], check=True, timeout=30)
        print(f'Real pgTAP: {len(assertions)}/{plan[0]} PASS', flush=True)

        bundle = json.loads((ROOT / 'catalogue/releases/skeleton-300-v1/plants.json').read_text())
        v1, v2 = str(uuid.uuid4()), str(uuid.uuid4())
        sql(f"INSERT INTO catalogue_releases(id,version) VALUES ('{v1}','regression_v1'),('{v2}','regression_v2');")
        def upsert(release, record):
            return f"SELECT upsert_catalogue_skeleton_species('{release}',{json_literal(record)},true);"
        sql('BEGIN;\n' + '\n'.join(upsert(v1, p) for p in bundle['plants']) + f"\nSELECT publish_catalogue_release('{v1}'); COMMIT;")
        for locale in ['en', 'pl']:
            cards = sql(f"SELECT jsonb_agg(get_catalogue_species_card(plant_id,'{locale}') ORDER BY plant_id) FROM catalogue_taxa WHERE release_id='{v1}' AND status='published';")
            (output / f'sql-cards-{locale}.json').write_text(cards)
        subprocess.run(['deno', 'run', '--config', str(ROOT / 'supabase/functions/deno.json'),
                        '--allow-read', str(ROOT / 'supabase/tests/validate_catalogue_cards.ts'), str(output)],
                       check=True, cwd=ROOT, timeout=120)
        plant = bundle['plants'][0]
        new = dict(plant, scientific_name='Regression v2')
        stale = dict(plant, scientific_name='Regression stale v1')
        sql(upsert(v2, new))

        def race(first_sql, second_sql, label):
            # Keep the first transaction open until pg_locks proves the contender is blocked.
            first = subprocess.Popen(base + ['-d', database], stdin=subprocess.PIPE,
                                     stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env)
            try:
                first.stdin.write('BEGIN;\n' + first_sql + '\n\\echo READY\n')
                first.stdin.flush()
                while first.stdout.readline().strip() != 'READY':
                    if first.poll() is not None:
                        raise RuntimeError(first.stderr.read())
                with ThreadPoolExecutor(max_workers=1) as executor:
                    pending = executor.submit(sql, f"SET application_name='t147_contender'; {second_sql}")
                    deadline = time.monotonic() + 5
                    while sql("SELECT count(*) FROM pg_stat_activity a JOIN pg_locks l ON l.pid=a.pid WHERE a.application_name='t147_contender' AND l.locktype='advisory' AND NOT l.granted;") != '1':
                        if pending.done() or time.monotonic() > deadline:
                            raise RuntimeError(f'{label}: contender did not wait for catalogue mutex')
                        time.sleep(.02)
                    first.stdin.write('COMMIT;\n\\q\n')
                    first.stdin.flush()
                    stdout, stderr = first.communicate(timeout=15)
                    if first.returncode:
                        raise RuntimeError(stderr)
                    pending.result(timeout=15)
                row = json.loads(sql(f"SELECT get_catalogue_species_card('{plant['plant_id']}');"))
                if not row or row['scientific_name'] != 'Regression v2':
                    raise RuntimeError(f'{label}: active card corrupted: {row}')
                if sql(f"SELECT release_id='{v2}'::uuid FROM catalogue_taxa WHERE plant_id='{plant['plant_id']}';") != 't':
                    raise RuntimeError(f'{label}: active row release mismatch')
                print(f'{label}: mutex wait + visible v2 card PASS', flush=True)
            finally:
                if first.poll() is None:
                    first.kill()
                    first.communicate()

        race(f"SELECT publish_catalogue_release('{v2}');", upsert(v1, stale), 'publish before stale import')
        sql(f"SELECT publish_catalogue_release('{v1}');")
        race(upsert(v1, stale), f"SELECT publish_catalogue_release('{v2}');", 'import before publish')
        sql(f"SELECT publish_catalogue_release('{v1}');")
        race(f"UPDATE catalogue_releases SET state='retired' WHERE id='{v1}'; UPDATE catalogue_releases SET state='published' WHERE id='{v2}';",
             upsert(v1, stale), 'direct release update before stale import')
        subprocess.run(['python3', str(ROOT / 'knowledge-base/pipeline/sync_catalogue_schema.py'), '--check'], check=True)
        summary = {
            'postgresql': version, 'pgtap': sql('SELECT pgtap_version();'),
            'migrations': {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in migrations},
            'tap_plan': int(plan[0]), 'tap_assertions': len(assertions), 'tap_result': 'PASS',
            'real_bundle_records': len(bundle['plants']), 'sql_ts_cards_checked': len(bundle['plants']) * 2,
            'concurrent_scenarios': ['publish before stale import', 'import before publish',
                                     'direct release update before stale import'],
            'live_supabase_storage_http_ios': 'not_tested',
        }
        (output / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
        print(f'T147 regression PASS; evidence: {output}', flush=True)
    finally:
        sql(f'DROP DATABASE {database} WITH (FORCE);', 'postgres')

if __name__ == '__main__':
    main()
