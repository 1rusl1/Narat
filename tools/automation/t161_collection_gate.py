"""T161: real PostgreSQL17 clean/upgrade, retained rows and owner-lock races.

Synthetic data only; never connects to Supabase or an existing database.
"""
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import argparse
import json
import os
import re
import shutil
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
BIN = Path('/opt/homebrew/opt/postgresql@17/bin')
PGTAP = Path('/private/tmp/pgtap-1.3.4/sql/pgtap.sql')
FIRST = '202611090003_collection_cap.sql'
OWNER = '15800000-0000-4000-8000-000000000001'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--slots', action='store_true')
    args = parser.parse_args()
    assert BIN.joinpath('initdb').is_file() and PGTAP.is_file(), 'PostgreSQL17/pgTAP required'
    work = Path(tempfile.mkdtemp(prefix='narat-t161-'))
    data = work / 'data'
    sock = work / 'socket'
    sock.mkdir()
    env = {k: v for k, v in os.environ.items() if not k.startswith('PG')}
    env.update(PGHOST=str(sock), PGPORT='55481', PGUSER='postgres',
               PGOPTIONS='-c statement_timeout=20000 -c lock_timeout=10000')
    base = [str(BIN / 'psql'), '-X', '-qAt', '-v', 'ON_ERROR_STOP=1']
    started = False

    def command(argv, stdin=None):
        p = subprocess.run(argv, input=stdin, text=True, capture_output=True, env=env, timeout=120)
        if p.returncode:
            raise RuntimeError(p.stderr[-3500:] or p.stdout[-3500:])
        return p.stdout.strip()

    def sql(db, query):
        return command(base + ['-d', db], query)

    def snapshot(db):
        return {t: sql(db, 'SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY to_jsonb(t)::text),\'[]\'::jsonb)::text FROM public."' + t + '" t')
                for t in sql(db, "SELECT tablename FROM pg_tables WHERE schemaname='public' ORDER BY tablename").splitlines()}

    def tap(db, path):
        result = sql(db, path.read_text())
        plans = re.findall(r'^1\.\.(\d+)$', result, re.M)
        assertions = re.findall(r'^(?:not )?ok \d+', result, re.M)
        assert len(plans) == 1 and len(assertions) == int(plans[0]) and assertions, 'Invalid TAP plan'
        assert not re.search(r'#\s*(?:SKIP|TODO)\b', result, re.I), 'No skips/TODO allowed'
        output = work / (db + '-' + path.stem + '.tap')
        output.write_text(result + '\n')
        command(['prove', '--exec', 'cat', str(output)])
        print(f'PASS: {db} {path.name}: {len(assertions)} pgTAP assertions', flush=True)

    def race(db, same):
        # Two instances before the race. The first call holds the profile lock;
        # pg_stat_activity must observe the second real connection waiting.
        op = '15800000-0000-4000-8000-000000000911'
        other = op if same else '15800000-0000-4000-8000-000000000912'
        payload = json.dumps({'plant_id': 'fixture_rooms_plant', 'display_name': 'Cap race'})
        query = f"SELECT public.execute_plant_create_command('{OWNER}', '{op}', '{payload}'::jsonb);"
        contender = f"SET application_name='t161_contender'; SELECT public.execute_plant_create_command('{OWNER}', '{other}', '{payload}'::jsonb);"
        first = subprocess.Popen(base + ['-d', db], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env)
        try:
            first.stdin.write('BEGIN;\n' + query + '\n\\echo READY\n')
            first.stdin.flush()
            response = None
            while True:
                line = first.stdout.readline().strip()
                if line == 'READY':
                    break
                if line.startswith('{'):
                    response = json.loads(line)
                if first.poll() is not None:
                    raise RuntimeError(first.stderr.read())
            with ThreadPoolExecutor(max_workers=1) as executor:
                pending = executor.submit(sql, db, contender)
                deadline = time.monotonic() + 8
                while sql(db, "SELECT count(*) FROM pg_stat_activity WHERE application_name='t161_contender' AND wait_event_type='Lock'") != '1':
                    if pending.done() or time.monotonic() > deadline:
                        raise AssertionError('Contender must wait for owner lock')
                    time.sleep(.02)
                first.stdin.write('COMMIT;\n\\q\n')
                first.stdin.flush()
                _, err = first.communicate(timeout=15)
                assert first.returncode == 0, err
                if same:
                    assert json.loads(pending.result(timeout=15)) == response, 'Concurrent replay differs'
                else:
                    try:
                        pending.result(timeout=15)
                    except RuntimeError as exc:
                        assert 'COLLECTION_LIMIT_REACHED' in str(exc), str(exc)
                    else:
                        raise AssertionError('Distinct concurrent create bypassed cap')
            assert sql(db, f"SELECT count(*) FROM public.plants WHERE owner_id='{OWNER}' AND deleted_at IS NULL") == '3'
            assert sql(db, f"SELECT count(*) FROM public.operation_receipts WHERE owner_id='{OWNER}' AND operation_id IN ('{op}','{other}')") == '1'
            # Remove only this runner's new row/receipt to restore the next race.
            sql(db, f"DELETE FROM public.operation_receipts WHERE owner_id='{OWNER}' AND operation_id='{op}'; DELETE FROM public.plants WHERE id='{response['plant_id']}';")
            print(f'PASS: {db} observed owner lock; concurrent {"same retry" if same else "distinct create"}; one plant/receipt', flush=True)
        finally:
            if first.poll() is None:
                first.kill()
                first.communicate(timeout=10)

    try:
        command([str(BIN / 'initdb'), '-D', str(data), '-A', 'trust', '-U', 'postgres', '--no-locale', '--encoding=UTF8'])
        command([str(BIN / 'pg_ctl'), '-D', str(data), '-l', str(work / 'postgres.log'), '-o', f'-h "" -k {sock} -p 55481', '-w', 'start'])
        started = True
        sql('postgres', 'CREATE ROLE anon; CREATE ROLE authenticated; CREATE ROLE service_role BYPASSRLS;')
        migrations = sorted((ROOT / 'supabase/migrations').glob('*.sql'))
        assert any(m.name == FIRST for m in migrations), 'New collection cap migration required'
        seed = (ROOT / 'supabase/tests/rooms_upgrade.seed.sql').read_text()
        # A has two instances before every race. Retain historical slot/receipt
        # rows so upgrade and projection checks exercise actual old data.
        seed += """
INSERT INTO public.plants(id,owner_id,plant_id,creation_source,display_name) VALUES
('15800000-0000-4000-8000-000000000203','15800000-0000-4000-8000-000000000001','fixture_rooms_plant','identification','Historical A2');
INSERT INTO public.basic_care_memberships(owner_id,plant_id,enabled,free_slot) VALUES
('15800000-0000-4000-8000-000000000001','15800000-0000-4000-8000-000000000201',true,2);
INSERT INTO public.operation_receipts(owner_id,operation_id,command_name,payload_hash,response_payload) VALUES
('15800000-0000-4000-8000-000000000001','15800000-0000-4000-8000-000000000821','free_care.select',encode(digest('{"selected_plant_ids": []}'::jsonb::text,'sha256'),'hex'),'{"legacy_selection": true}'::jsonb);
"""
        for case in ['clean', 'upgrade']:
            sql('postgres', f'CREATE DATABASE {case};')
            sql(case, "CREATE SCHEMA auth; CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$ SELECT NULLIF(current_setting('request.jwt.claim.sub', true), '')::uuid $$; GRANT USAGE ON SCHEMA auth TO PUBLIC; CREATE TABLE auth.users(id uuid PRIMARY KEY,is_anonymous boolean);")
            for migration in migrations:
                if case == 'upgrade' and migration.name >= FIRST:
                    continue
                sql(case, migration.read_text())
            sql(case, PGTAP.read_text())
            sql(case, seed)
            before = snapshot(case)
            if case == 'upgrade':
                for migration in migrations:
                    if migration.name >= FIRST:
                        sql(case, migration.read_text())
                assert snapshot(case) == before, 'Upgrade changed historical rows/spending/receipts'
            tap(case, ROOT / 'tools/automation/sql/t161_cap.sql')
            test = ROOT / 'supabase/tests/collection_cap.test.sql'
            assert test.is_file(), 'Developer regression suite required'
            tap(case, test)
            if args.slots:
                tap(case, ROOT / 'tools/automation/sql/t161_slots.sql')
                tap(case, ROOT / 'supabase/tests/free_care.test.sql')
            assert snapshot(case) == before, 'Tests must rollback all data changes'
            race(case, same=True)
            race(case, same=False)
        print('PASS: T161 clean/upgrade/races; fixtures only; positive guest transfer/live not accepted', flush=True)
    finally:
        if started:
            subprocess.run([str(BIN / 'pg_ctl'), '-D', str(data), '-m', 'fast', '-w', 'stop'], capture_output=True, timeout=30, check=True)
        shutil.rmtree(work)


if __name__ == '__main__':
    main()
