"""Controller-owned T163 PostgreSQL17 gate; private clusters, synthetic data only."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
BIN = Path('/opt/homebrew/opt/postgresql@17/bin')
PGTAP = Path('/private/tmp/pgtap-1.3.4/sql/pgtap.sql')
FIRST = '202611090005_registration_quotas.sql'
LEDGER = '202611090006_registration_ledger.sql'
RESERVE = '202611090008_quota_reservation.sql'
SECOND = '202611090009_quota_settlement.sql'
CAP_OWNER = '15800000-0000-4000-8000-000000000001'
A = '16300000-0000-4000-8000-000000000001'
B = '16300000-0000-4000-8000-000000000002'
K = '16300000-0000-4000-8000-000000000100'
NOW = '2026-11-15T10:20:00Z'
ANCHOR = '2026-10-31T10:20:00Z'


def job(i):
    return f'16300000-0000-4000-8000-{i:012d}'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--anchors', action='store_true')
    parser.add_argument('--legacy-guard', action='store_true')
    parser.add_argument('--cap-regression', action='store_true')
    parser.add_argument('--reserve', action='store_true')
    parser.add_argument('--accounting', action='store_true')
    parser.add_argument('--baseline', action='store_true', help='Negative control; expected product rejection is NOT acceptance')
    args = parser.parse_args()
    assert BIN.joinpath('initdb').is_file() and PGTAP.is_file(), 'PG17/pgTAP required'
    work = Path(tempfile.mkdtemp(prefix='narat-backend-quota-'))
    sock = work / 'socket'
    sock.mkdir()
    env = {k: v for k, v in os.environ.items() if not k.startswith('PG')}
    env.update(PGHOST=str(sock), PGPORT='55493', PGUSER='postgres',
               PGOPTIONS='-c statement_timeout=25000 -c lock_timeout=20000')
    base = [str(BIN / 'psql'), '-X', '-qAt', '-v', 'ON_ERROR_STOP=1']
    started = False

    def command(argv, stdin=None):
        result = subprocess.run(argv, input=stdin, text=True, capture_output=True, env=env, timeout=120)
        if result.returncode:
            raise RuntimeError((result.stderr or result.stdout)[-5000:])
        return result.stdout.strip()

    def sql(db, query):
        return command(base + ['-d', db], query)

    def check(db, expression, message):
        assert sql(db, 'SELECT (' + expression + ')::text;') == 'true', message
        print(f'PASS {db}: {message}', flush=True)

    def tap(db, path):
        assert path.is_file(), f'Developer regression suite required: {path}'
        result = sql(db, path.read_text())
        plans = re.findall(r'^1\.\.(\d+)$', result, re.M)
        assertions = re.findall(r'^(?:not )?ok \d+', result, re.M)
        assert len(plans) == 1 and len(assertions) == int(plans[0]) and assertions, 'Invalid TAP plan'
        assert not re.search(r'#\s*(?:SKIP|TODO)\b', result, re.I), 'No skip/TODO'
        path_out = work / (db + path.stem + '.tap')
        path_out.write_text(result + '\n')
        command(['prove', '--exec', 'cat', str(path_out)])
        print(f'PASS {db}: {path.name}, {len(assertions)} pgTAP assertions', flush=True)

    def snapshot(db):
        tables = sql(db, "SELECT tablename FROM pg_tables WHERE schemaname='public' ORDER BY tablename").splitlines()
        return {t: sql(db, f'''SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY to_jsonb(t)::text),'[]'::jsonb) FROM public."{t}" t''') for t in tables}

    def put_jobs(db, numbers, owner=A, mode='diagnosis'):
        values = ','.join(f"('{job(i)}','{owner}','{job(i)}','problem','scan','{mode}','{K}','fixture','{job(i)}','hash-{i}','en','none','not_applicable','{NOW}')" for i in numbers)
        sql(db, 'INSERT INTO public.analysis_jobs(id,owner_id,flow_id,intent,add_method,mode,kb_release_id,prompt_version,operation_id,payload_hash,locale,quota_kind,quota_state,created_at) VALUES ' + values + ';')

    def admit(db, i, owner=A):
        return json.loads(sql(db, f"SELECT public.admit_analysis_quota('diagnosis','{owner}',NULL,'{job(i)}','{NOW}');"))

    def accounting(db):
        check(db, "to_regclass('public.account_quota_anchors') IS NOT NULL", 'anchor table exists')
        # Exact UTC month clamping, rebound to original day, leap day and timezone invariance.
        windows = [('2026-01-31 10:20Z', '2026-02-28 10:20Z', '2026-02-28 10:20Z', '2026-03-31 10:20Z'),
                   ('2024-01-31 10:20Z', '2024-02-29 10:19Z', '2024-01-31 10:20Z', '2024-02-29 10:20Z'),
                   ('2024-02-29 10:20Z', '2025-02-28 10:20Z', '2025-02-28 10:20Z', '2025-03-29 10:20Z'),
                   ('2026-01-30 10:20Z', '2026-03-30 10:20Z', '2026-03-30 10:20Z', '2026-04-30 10:20Z')]
        for zone in ('UTC', 'America/New_York', 'Pacific/Auckland'):
            for anchor, now, start, end in windows:
                output = sql(db, f"SET TIME ZONE '{zone}'; SELECT (period_start='{start}'::timestamptz AND period_end='{end}'::timestamptz)::text FROM public.compute_paid_quota_window('{anchor}','{now}');")
                assert output == 'true', f'UTC month clamp failed {zone} {anchor} {now}: {output}'
        print(f'PASS {db}: 12 boundary/leap/timezone windows', flush=True)
        # Legacy profile cannot silently obtain a purchase-derived anchor.
        if db == 'upgrade':
            check(db, f"(SELECT registered_at IS NULL FROM public.account_quota_anchors WHERE owner_id='{A}')", 'unproven legacy registration remains explicit NULL')
            sql(db, f"SELECT public.set_registration_quota_anchor('{A}','{ANCHOR}','fixture verified permanent-registration event');")
            if args.anchors:
                return
            sql(db, f"SELECT public.reconcile_registration_quota('{A}');")
            check(db, f"(SELECT count(*)=2 FROM public.account_quota_usage WHERE owner_id='{A}')", 'two known legacy jobs imported once')
            before = sql(db, f"SELECT jsonb_agg(to_jsonb(t) ORDER BY job_id) FROM public.account_quota_usage t WHERE owner_id='{A}';")
            sql(db, f"SELECT public.reconcile_registration_quota('{A}'); SELECT public.set_registration_quota_anchor('{A}','{ANCHOR}','fixture retry');")
            assert sql(db, f"SELECT jsonb_agg(to_jsonb(t) ORDER BY job_id) FROM public.account_quota_usage t WHERE owner_id='{A}';") == before, 're-import changed/doubled usage'
            check(db, "EXISTS(SELECT 1 FROM public.quota_legacy_reconciliation WHERE unallocated_consumed>0)", 'unattributable aggregate spend retained explicitly')
        else:
            check(db, f"(SELECT registered_at='{ANCHOR}'::timestamptz FROM public.account_quota_anchors WHERE owner_id='{A}')", 'new permanent profile gets registration anchor')
        check(db, "NOT has_function_privilege('authenticated','public.set_registration_quota_anchor(uuid,timestamp with time zone,text)','EXECUTE')", 'client cannot set registration anchor')
        if not args.anchors:
            check(db, "NOT has_function_privilege('anon','public.reconcile_registration_quota(uuid)','EXECUTE')", 'anon cannot reconcile ledger')

    def cap_race(db, same):
        # Two instances before the race. The first call holds the profile lock;
        # pg_stat_activity must observe the second real connection waiting.
        op = '15800000-0000-4000-8000-000000000911'
        other = op if same else '15800000-0000-4000-8000-000000000912'
        payload = json.dumps({'plant_id': 'fixture_rooms_plant', 'display_name': 'Cap race'})
        query = f"SELECT public.execute_plant_create_command('{CAP_OWNER}', '{op}', '{payload}'::jsonb);"
        contender = f"SET application_name='t161_contender'; SELECT public.execute_plant_create_command('{CAP_OWNER}', '{other}', '{payload}'::jsonb);"
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
            assert sql(db, f"SELECT count(*) FROM public.plants WHERE owner_id='{CAP_OWNER}' AND deleted_at IS NULL") == '3'
            assert sql(db, f"SELECT count(*) FROM public.operation_receipts WHERE owner_id='{CAP_OWNER}' AND operation_id IN ('{op}','{other}')") == '1'
            # Remove only this runner's new row/receipt to restore the next race.
            sql(db, f"DELETE FROM public.operation_receipts WHERE owner_id='{CAP_OWNER}' AND operation_id='{op}'; DELETE FROM public.plants WHERE id='{response['plant_id']}';")
            print(f'PASS: {db} observed owner lock; concurrent {"same retry" if same else "distinct create"}; one plant/receipt', flush=True)
        finally:
            if first.poll() is None:
                first.kill()
                first.communicate(timeout=10)

    def legacy_guard(db):
        if db == 'upgrade':
            check(db, f"(SELECT registered_at IS NULL FROM public.account_quota_anchors WHERE owner_id='{B}')", 'legacy guard probe uses unresolved permanent owner')
        query = f"""CREATE FUNCTION pg_temp.probe_legacy_flip() RETURNS boolean LANGUAGE plpgsql AS $$
BEGIN
 UPDATE public.profiles SET anonymous=true WHERE id='{B}';
 RETURN false;
EXCEPTION WHEN SQLSTATE '55000' THEN RETURN true;
END; $$;
SELECT pg_temp.probe_legacy_flip()::text;"""
        assert sql(db, query) == 'true', 'Permanent legacy owner can re-register to evade unresolved anchor'
        print(f'PASS {db}: trusted permanent-to-guest reversal rejected', flush=True)

    def concurrency(db, same=False, outcome='succeeded'):
        # Fresh owner with exactly one remaining paid slot; 20 independent psql
        # processes all MUST be visible blocked on a held owner lock before release.
        owner = job(50 + (1 if same else 0) + (2 if outcome == 'failed' else 0))
        sql(db, f"INSERT INTO public.profiles(id,anonymous,created_at,starter_diagnosis_consumed,starter_identification_consumed) VALUES('{owner}',false,'{ANCHOR}',true,true); INSERT INTO public.entitlements(owner_id,product_id,state,offer_kind,valid_until) VALUES('{owner}','app.narat.plants.pro.monthly','active','paid','2027-12-01');")
        existing = list(range(2000, 2099))
        put_jobs(db, existing, owner)
        if args.reserve:
            # Partial reserve-only slice: historical consumed fixture. This is NOT
            # final T163 acceptance. The default gate below still performs 99
            # actual admissions/finalizations for all six complete race rounds.
            sql(db, f"UPDATE public.analysis_jobs SET quota_kind='paid_monthly',quota_state='consumed',state='succeeded' WHERE owner_id='{owner}'; INSERT INTO public.account_quota_usage(job_id,owner_id,period_start,period_end,quota_state) SELECT j.id,j.owner_id,w.period_start,w.period_end,'consumed' FROM public.analysis_jobs j CROSS JOIN public.compute_paid_quota_window('{ANCHOR}','{NOW}') w WHERE j.owner_id='{owner}';")
        else:
            # 99 genuine successful admissions, not a synthetic aggregate/stub.
            for i in existing:
                sql(db, f"SELECT public.admit_analysis_quota('diagnosis','{owner}',NULL,'{job(i)}','{NOW}'); SELECT public.finalize_analysis_quota('{job(i)}','succeeded',false,'{NOW}');")
        candidates = [3000] if same else list(range(3000, 3020))
        put_jobs(db, candidates, owner)
        blocker = subprocess.Popen(base + ['-d', db], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env)
        try:
            blocker.stdin.write(f"BEGIN; SELECT id FROM public.profiles WHERE id='{owner}' FOR UPDATE;\n\\echo READY\n")
            blocker.stdin.flush()
            while blocker.stdout.readline().strip() != 'READY':
                if blocker.poll() is not None:
                    raise RuntimeError(blocker.stderr.read())
            prefix = 'b163_same' if same else 'b163_distinct'
            def contender(i):
                n = 3000 if same else 3000 + i
                return json.loads(sql(db, f"SET application_name='{prefix}_{i}'; SELECT public.admit_analysis_quota('diagnosis','{owner}',NULL,'{job(n)}','{NOW}');"))
            with ThreadPoolExecutor(max_workers=20) as pool:
                futures = [pool.submit(contender, i) for i in range(20)]
                deadline = time.monotonic() + 15
                while sql(db, f"SELECT count(*) FROM pg_stat_activity WHERE application_name LIKE '{prefix}_%' AND wait_event_type='Lock'") != '20':
                    assert not any(f.done() for f in futures), 'Admission bypassed owner lock'
                    assert time.monotonic() < deadline, 'Did not observe 20 simultaneous real connections'
                    time.sleep(.03)
                blocker.stdin.write('COMMIT;\n\\q\n')
                blocker.stdin.flush()
                _, err = blocker.communicate(timeout=15)
                assert blocker.returncode == 0, err
                results = [f.result(timeout=30) for f in futures]
            admitted = [i for i, result in enumerate(results) if result.get('admitted') is True]
            assert len(admitted) == (20 if same else 1), results
            if not same:
                assert all(r.get('reason') == 'paid_monthly_exhausted' for r in results if not r.get('admitted')), results
            winner = 3000 if same else 3000 + admitted[0]
            check(db, f"(SELECT count(*)=1 FROM public.account_quota_usage WHERE owner_id='{owner}' AND quota_state='reserved')", 'race reserves exactly one ledger row')
            before = sql(db, f"SELECT count(*) FROM public.account_quota_usage WHERE owner_id='{owner}'")
            assert admit(db, winner, owner).get('admitted') is True
            assert sql(db, f"SELECT count(*) FROM public.account_quota_usage WHERE owner_id='{owner}'") == before
            if args.reserve:
                sql(db, f"DELETE FROM public.profiles WHERE id='{owner}';")
                print(f'PASS {db}: reserve-only 20 observed connections; same={same}; settlement NOT tested', flush=True)
                return
            sql(db, f"SELECT public.finalize_analysis_quota('{job(winner)}','{outcome}',false,'{NOW}'); SELECT public.finalize_analysis_quota('{job(winner)}','succeeded',false,'{NOW}');")
            expected = 'released' if outcome == 'failed' else 'consumed'
            check(db, f"(SELECT quota_state='{expected}' FROM public.account_quota_usage WHERE job_id='{job(winner)}')", 'terminal settlement is exactly once')
            terminal_before = sql(db, f"SELECT to_jsonb(t) FROM public.account_quota_usage t WHERE job_id='{job(winner)}'")
            admit(db, winner, owner)
            assert sql(db, f"SELECT to_jsonb(t) FROM public.account_quota_usage t WHERE job_id='{job(winner)}'") == terminal_before, 'terminal admission refilled quota'
            # Reuse job IDs safely only after deleting this isolated race owner.
            sql(db, f"DELETE FROM public.profiles WHERE id='{owner}';")
            print(f'PASS {db}: 20 observed simultaneous connections; same={same}; terminal={expected}; replay unchanged', flush=True)
        finally:
            if blocker.poll() is None:
                blocker.kill()
                blocker.communicate(timeout=10)

    try:
        command([str(BIN/'initdb'), '-D', str(work/'data'), '-A', 'trust', '-U', 'postgres', '--no-locale', '--encoding=UTF8'])
        command([str(BIN/'pg_ctl'), '-D', str(work/'data'), '-l', str(work/'postgres.log'), '-o', f'-h "" -k {sock} -p 55493', '-w', 'start'])
        started = True
        sql('postgres', 'CREATE ROLE anon; CREATE ROLE authenticated; CREATE ROLE service_role BYPASSRLS;')
        migrations = sorted((ROOT/'supabase/migrations').glob('*.sql'))
        ceiling = '999999999999' if args.legacy_guard else LEDGER if args.anchors else RESERVE if args.accounting else SECOND if args.reserve else '999999999999'
        selected = [m for m in migrations if m.name < FIRST or not args.baseline and m.name < ceiling]
        if not args.baseline:
            assert any(m.name == FIRST for m in selected), 'Registration migration required'
            if args.reserve:
                assert any(m.name == RESERVE for m in selected), 'Reservation migration required'
            elif not args.accounting and not args.anchors:
                assert any(m.name == SECOND for m in selected), 'Admission migration required'
        for case in ('clean','upgrade'):
            sql('postgres', f'CREATE DATABASE {case};')
            sql(case, "CREATE SCHEMA auth; CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$ SELECT NULLIF(current_setting('request.jwt.claim.sub',true),'')::uuid $$; GRANT USAGE ON SCHEMA auth TO PUBLIC; CREATE TABLE auth.users(id uuid PRIMARY KEY,is_anonymous boolean);")
            for migration in selected:
                if case == 'clean' or migration.name < FIRST:
                    sql(case, migration.read_text())
            sql(case, PGTAP.read_text())
            sql(case, f"INSERT INTO public.profiles(id,anonymous,created_at,starter_identification_consumed,starter_diagnosis_consumed) VALUES('{A}',false,'{ANCHOR}',true,true),('{B}',false,'{ANCHOR}',false,false); INSERT INTO public.kb_releases(id,version,state,manifest_sha256,published_at) VALUES('{K}','b163-fixture','published',repeat('a',64),'{NOW}');")
            if args.cap_regression:
                # Both suites require one published release; the generic quota FK fixture
                # is draft in this mode, the unmodified T161 catalogue fixture is published.
                sql(case, f"UPDATE public.kb_releases SET state='draft' WHERE id='{K}';")
                cap_seed = (ROOT/'supabase/tests/rooms_upgrade.seed.sql').read_text() + '\nINSERT INTO public.plants(id,owner_id,plant_id,creation_source,display_name) VALUES\n(\'15800000-0000-4000-8000-000000000203\',\'15800000-0000-4000-8000-000000000001\',\'fixture_rooms_plant\',\'identification\',\'Historical A2\');\nINSERT INTO public.basic_care_memberships(owner_id,plant_id,enabled,free_slot) VALUES\n(\'15800000-0000-4000-8000-000000000001\',\'15800000-0000-4000-8000-000000000201\',true,2);\nINSERT INTO public.operation_receipts(owner_id,operation_id,command_name,payload_hash,response_payload) VALUES\n(\'15800000-0000-4000-8000-000000000001\',\'15800000-0000-4000-8000-000000000821\',\'free_care.select\',encode(digest(\'{"selected_plant_ids": []}\'::jsonb::text,\'sha256\'),\'hex\'),\'{"legacy_selection": true}\'::jsonb);\n'
                sql(case, cap_seed)
            if case == 'upgrade':
                # Existing paid counters deliberately contain unattributable spend;
                # known consumed/reserved jobs must not be added twice.
                sql(case, f"INSERT INTO public.monthly_quotas(id,owner_id,quota_kind,period_start,period_end,limit_count,consumed_count,reserved_count) VALUES('{job(400)}','{A}','paid_monthly','2026-10-20','2026-11-20',100,7,1);")
                put_jobs(case, [401,402])
                sql(case, f"UPDATE public.analysis_jobs SET quota_kind='paid_monthly',quota_state=CASE WHEN id='{job(401)}' THEN 'consumed' ELSE 'reserved' END,monthly_quota_id='{job(400)}',state=CASE WHEN id='{job(401)}' THEN 'succeeded' ELSE 'running' END,lease_token='{job(500)}',provider_started_at='{NOW}';")
                before = snapshot(case)
                for migration in selected:
                    if migration.name >= FIRST:
                        sql(case, migration.read_text())
                after = snapshot(case)
                assert all(after[t] == value for t,value in before.items()), 'Forward upgrade changed legacy rows/owners/leases/counters/receipts'
                print('PASS upgrade: every preexisting public row retained byte-for-byte', flush=True)
            if args.baseline:
                sql(case, f"UPDATE public.profiles SET first_starter_success_at='2026-10-01' WHERE id='{A}'; INSERT INTO public.installation_access(id,credential_hash,starter_identification_consumed,starter_diagnosis_consumed) VALUES('{job(101)}','baseline-fixture',true,true);")
                old = json.loads(sql(case, f"SELECT public.admit_analysis_quota('diagnosis','{A}','{job(101)}','{job(901)}','{NOW}');"))
                assert old.get('remaining_after_reserve') == 2, f"OLD RULE REJECTED: Free must reserve from 3 immediately in registration window, got {old}"
                raise AssertionError('Baseline unexpectedly passed product rule; investigate negative control')
            accounting(case)
            if args.legacy_guard:
                legacy_guard(case)
            tap(case, ROOT/'supabase/tests/registration_anchors.test.sql')
            if args.cap_regression:
                for path in ('tools/automation/sql/t161_cap.sql', 'supabase/tests/collection_cap.test.sql', 'tools/automation/sql/t161_slots.sql', 'supabase/tests/free_care.test.sql'):
                    tap(case, ROOT/path)
                cap_race(case, same=True)
                cap_race(case, same=False)
            if not args.anchors:
                tap(case, ROOT/'supabase/tests/registration_quotas.test.sql')
            if not args.accounting and not args.anchors:
                tap(case, ROOT/('supabase/tests/registration_reservation.test.sql' if args.reserve else 'supabase/tests/registration_admission.test.sql'))
                concurrency(case, same=False)
                concurrency(case, same=True)
                if not args.reserve:
                    concurrency(case, same=False, outcome='failed')
        print('PASS T163 reserve-only; historical fixture; settlement NOT accepted' if args.reserve else 'PASS T163 anchors' if args.anchors else 'PASS T163 accounting' if args.accounting else 'PASS T163 accounting/admission/20-connection races; fixtures only', flush=True)
    finally:
        if started:
            subprocess.run([str(BIN/'pg_ctl'), '-D', str(work/'data'), '-m', 'fast', '-w', 'stop'], capture_output=True, timeout=30, check=True)
        shutil.rmtree(work)


if __name__ == '__main__':
    main()
