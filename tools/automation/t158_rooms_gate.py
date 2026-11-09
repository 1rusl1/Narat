"""Room retirement: exact SQL scope, real PostgreSQL clean/upgrade and retry race."""
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor
import hashlib, json, os, re, shutil, subprocess, sys, tempfile, time

ROOT = Path(__file__).resolve().parents[2]
BIN = Path('/opt/homebrew/opt/postgresql@17/bin')
PGTAP = Path('/private/tmp/pgtap-1.3.4/sql/pgtap.sql')
NAME = '202611090002_retire_rooms.sql'

def function(file, name):
    return re.search(r'CREATE OR REPLACE FUNCTION public\.' + name + r'\(.*?\n\$\$;', (ROOT/'supabase/migrations'/file).read_text(), re.S).group()

def guard(value):
    return "  IF " + value + " ?| ARRAY['room_id', 'new_room_name', 'create_room_name'] THEN\n    RAISE EXCEPTION 'ROOM_FIELDS_RETIRED' USING ERRCODE = '22023';\n  END IF;\n\n"

def expected_migration():
    create = function('202610200014_collection_commands.sql', 'execute_plant_create_command')
    create = create.replace('  v_room_id UUID := NULL;\n  v_new_room_name TEXT;\n', '')
    create = re.sub(r"  IF v_overrides \? 'room_id'.*?\n  END IF;\n\n", '', create, flags=re.S)
    create = create.replace('  v_creation_source :=', guard("COALESCE(p_payload, '{}'::jsonb)") + guard("COALESCE(p_payload->'overrides', '{}'::jsonb)") + '  v_creation_source :=', 1)
    create = create.replace('owner_id, room_id, taxon_id', 'owner_id, taxon_id').replace('p_owner_id, v_room_id, v_final_taxon_id', 'p_owner_id, v_final_taxon_id').replace("    'room_id', v_room_id,\n", '')
    prepare = function('202610200013_guest_claim.sql', 'prepare_guest_claim')
    prepare = prepare.replace('BEGIN\n', 'BEGIN\n' + guard("COALESCE(p_overrides, '{}'::jsonb)"), 1)
    commit = function('202610200013_guest_claim.sql', 'commit_guest_claim')
    commit = commit.replace('  v_room_id UUID := NULL;\n  v_new_room_name TEXT;\n', '')
    commit = commit.replace('  SELECT * INTO v_draft', guard("COALESCE(p_overrides, '{}'::jsonb)") + '  SELECT * INTO v_draft', 1)
    commit = re.sub(r'  -- Optional room selection or new room creation\n.*?\n  END IF;\n\n', guard('v_effective_overrides'), commit, flags=re.S)
    commit = commit.replace('owner_id, room_id, taxon_id', 'owner_id, taxon_id').replace('p_owner_id, v_room_id, v_final_taxon_id', 'p_owner_id, v_final_taxon_id').replace("    'room_id', v_room_id,\n", '')
    room = function('202610200014_collection_commands.sql', 'execute_room_command').split('AS $$')[0] + """AS $$
DECLARE
  v_cached JSONB;
BEGIN
  IF p_command_name IS NULL OR p_command_name NOT IN ('room.create', 'room.rename', 'room.delete') THEN
    RAISE EXCEPTION 'ROOM_COMMAND_RETIRED' USING ERRCODE = '22023';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = p_owner_id AND account_state = 'active') THEN
    RAISE EXCEPTION 'account_not_active' USING ERRCODE = '42501';
  END IF;
  v_cached := public.lookup_operation_receipt(
    p_owner_id, p_operation_id, p_command_name,
    encode(digest(p_command_name || ':' || COALESCE(p_payload::TEXT, '{}'), 'sha256'), 'hex')
  );
  IF v_cached IS NOT NULL THEN
    RETURN v_cached;
  END IF;
  RAISE EXCEPTION 'ROOM_COMMAND_RETIRED' USING ERRCODE = '22023';
END;
$$;"""
    protocol = (ROOT/'supabase/migrations/202610200010_command_protocol.sql').read_text()
    view = re.search(r'CREATE OR REPLACE VIEW public\.owner_sync_entries AS.*?FROM public.notification_claims nc;', protocol, re.S).group()
    view = re.sub(r'    -- 1\. rooms\n.*?    -- 2\. plants', '    -- Plants (historical rooms are no longer synchronized)\n', view, flags=re.S)
    view = view.replace("            'room_id', p.room_id,\n", '')
    return '\n\n'.join([create, prepare, commit, room, view]) + '\n'

if '--print-migration' in sys.argv:
    print(expected_migration(), end='')
    sys.exit(0)

actual = (ROOT/'supabase/migrations'/NAME).read_text()
# Allow explanatory SQL comments; every executable statement must match the narrow change.
strip = lambda s: re.sub(r'--[^\n]*', '', s).strip()
assert strip(actual) == strip(expected_migration()), 'Unexpected SQL scope: use --print-migration'
assert BIN.joinpath('initdb').is_file() and PGTAP.is_file(), 'PostgreSQL17 and real pgTAP required'
work = Path(tempfile.mkdtemp(prefix='narat-rooms-upgrade-'))
data = work/'data'; sock = work/'socket'; sock.mkdir(); started = False
clean_env = {k:v for k,v in os.environ.items() if not k.startswith('PG')}
clean_env.update(PGHOST=str(sock), PGPORT='55479', PGUSER='postgres', PGOPTIONS='-c statement_timeout=20000 -c lock_timeout=10000')

def command(argv, stdin=None):
    p = subprocess.run(argv, input=stdin, text=True, capture_output=True, env=clean_env, timeout=120)
    if p.returncode: raise RuntimeError(p.stderr[-2200:] or p.stdout[-2200:])
    return p.stdout.strip()
base = [str(BIN/'psql'), '-X', '-qAt', '-v', 'ON_ERROR_STOP=1']
def sql(db, text): return command(base + ['-d', db], text)
def snapshot(db):
    return {t: sql(db, 'SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY to_jsonb(t)::text),\'[]\'::jsonb)::text FROM public."' + t + '" t') for t in sql(db, "SELECT tablename FROM pg_tables WHERE schemaname='public' ORDER BY tablename").splitlines()}

def retry_race(db):
    owner = '15800000-0000-4000-8000-000000000001'
    operation = '15800000-0000-4000-8000-000000000901'
    query = f"SELECT public.execute_plant_create_command('{owner}', '{operation}', '{{\"plant_id\":\"fixture_rooms_plant\",\"display_name\":\"Concurrent\"}}'::jsonb);"
    first = subprocess.Popen(base + ['-d', db], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=clean_env)
    try:
        first.stdin.write('BEGIN;\n' + query + '\n\\echo READY\n'); first.stdin.flush()
        response = None
        while True:
            line = first.stdout.readline().strip()
            if line == 'READY': break
            if line.startswith('{'): response = json.loads(line)
            if first.poll() is not None: raise RuntimeError(first.stderr.read())
        with ThreadPoolExecutor(max_workers=1) as executor:
            pending = executor.submit(sql, db, "SET application_name='t158_contender'; " + query)
            deadline = time.monotonic() + 8
            while sql(db, "SELECT count(*) FROM pg_stat_activity WHERE application_name='t158_contender' AND wait_event_type='Lock'") != '1':
                if pending.done() or time.monotonic() > deadline: raise RuntimeError('Retry did not wait for owner lock')
                time.sleep(.02)
            first.stdin.write('COMMIT;\n\\q\n'); first.stdin.flush()
            _, err = first.communicate(timeout=15)
            assert first.returncode == 0, err
            assert json.loads(pending.result(timeout=15)) == response, 'Concurrent retry response differs'
        assert sql(db, f"SELECT count(*) FROM public.operation_receipts WHERE owner_id='{owner}' AND operation_id='{operation}'") == '1'
        assert sql(db, "SELECT count(*) FROM public.plants WHERE personal_name='Concurrent'") == '1'
        assert 'room_id' not in response
        print(f'PASS: {db} actual owner-lock wait, concurrent identical create, one plant/receipt', flush=True)
    finally:
        if first.poll() is None: first.kill(); first.communicate(timeout=10)

try:
    command([str(BIN/'initdb'), '-D', str(data), '-A', 'trust', '-U', 'postgres', '--no-locale', '--encoding=UTF8'])
    command([str(BIN/'pg_ctl'), '-D', str(data), '-l', str(work/'postgres.log'), '-o', f'-h "" -k {sock} -p 55479', '-w', 'start']); started = True
    sql('postgres', 'CREATE ROLE anon; CREATE ROLE authenticated; CREATE ROLE service_role BYPASSRLS;')
    migrations = sorted((ROOT/'supabase/migrations').glob('*.sql'))
    seed = (ROOT/'supabase/tests/rooms_upgrade.seed.sql').read_text()
    test = (ROOT/'supabase/tests/rooms_retirement.test.sql').read_text()
    for case in ['clean', 'upgrade']:
        sql('postgres', f'CREATE DATABASE {case};')
        sql(case, "CREATE SCHEMA auth; CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$ SELECT NULLIF(current_setting('request.jwt.claim.sub', true), '')::uuid $$; GRANT USAGE ON SCHEMA auth TO PUBLIC; CREATE TABLE auth.users(id uuid PRIMARY KEY,is_anonymous boolean);")
        for migration in migrations:
            if case == 'upgrade' and migration.name >= NAME: continue
            sql(case, migration.read_text())
        sql(case, PGTAP.read_text()); sql(case, seed)
        before = snapshot(case)
        if case == 'upgrade':
            for migration in migrations:
                if migration.name >= NAME: sql(case, migration.read_text())
            assert snapshot(case) == before, 'Upgrade changed historical table rows'
        tap = sql(case, test)
        plans = re.findall(r'^1\.\.(\d+)$', tap, re.M); assertions = re.findall(r'^(?:not )?ok \d+', tap, re.M)
        assert len(plans) == 1 and len(assertions) == int(plans[0]) and len(assertions) > 0, 'Invalid TAP plan'
        assert not re.search(r'#\s*(?:SKIP|TODO)\b', tap, re.I), 'Skipped/TODO assertions forbidden'
        tap_path = work/(case+'.tap'); tap_path.write_text(tap+'\n'); command(['prove', '--exec', 'cat', str(tap_path)])
        assert snapshot(case) == before, 'Tests must rollback changes'
        print(f'PASS: {case}, {len(assertions)} real pgTAP assertions; history/rows unchanged', flush=True)
        retry_race(case)
    print('PASS: exact room retirement, clean+upgrade PostgreSQL17; no live deployment', flush=True)
finally:
    if started: subprocess.run([str(BIN/'pg_ctl'), '-D', str(data), '-m', 'fast', '-w', 'stop'], capture_output=True, timeout=30, check=True)
    shutil.rmtree(work)
