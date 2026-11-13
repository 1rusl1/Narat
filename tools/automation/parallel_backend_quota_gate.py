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
BIND = '202611090010_installation_quota_bind.sql'
INSTALLATIONS = '202611090011_installation_access_api.sql'
ACCESS = '202611090012_analysis_access_snapshot.sql'
CARE_JOURNAL = '202611110016_manual_care_journal.sql'
CARE_PROFILE_READ = '202611110017_plant_care_profile_read.sql'
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
    parser.add_argument('--bind', action='store_true')
    parser.add_argument('--installations', action='store_true')
    parser.add_argument('--access', action='store_true')
    parser.add_argument('--diagnosis-upload', action='store_true')
    parser.add_argument('--diagnosis-jobs', action='store_true')
    parser.add_argument('--accounting', action='store_true')
    parser.add_argument('--baseline', action='store_true', help='Negative control; expected product rejection is NOT acceptance')
    args = parser.parse_args()
    assert not args.installations or args.bind, '--installations requires --bind'
    assert not args.access or args.installations, '--access requires --installations'
    assert not args.diagnosis_jobs or args.diagnosis_upload, '--diagnosis-jobs requires --diagnosis-upload'
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
        try:
            command(['prove', '--exec', 'cat', str(path_out)])
        except RuntimeError as error:
            diagnostics = '\n'.join(line for line in result.splitlines()
                                    if line.startswith(('not ok', '#')))
            raise RuntimeError(str(error) + '\nTAP diagnostics:\n' + diagnostics[-5000:]) from error
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

    def guest_settlement_bind_race(db, release, timed_out):
        offset = 600 if timed_out else 610
        guest, target = job(offset), job(offset + 1)
        secret_hash = ('1' if timed_out else '2') * 64
        sql(db, f"INSERT INTO public.profiles(id,anonymous) VALUES('{guest}',true),('{target}',false);")
        installation = sql(db, f"SELECT public.register_installation_access('{secret_hash}','{guest}')->>'installation_id';")
        photo = sql(db, f"SELECT public.create_bound_photo_upload('{guest}','{job(offset+2)}','image/jpeg',4,repeat('a',64),'{secret_hash}')->>'photo_asset_id';")
        sql(db, f"SELECT public.mark_diagnosis_upload_ready('{guest}','{photo}',repeat('a',64));")
        leased_job = sql(db, f"SELECT public.create_bound_photo_analysis_job('{guest}','{job(offset+3)}','{photo}',NULL,'en',true,'identification','{secret_hash}')->'job'->>'job_id';")
        lease_token = sql(db, f"SELECT public.lease_diagnosis_job('{leased_job}')->>'lease_token';")
        assert sql(db, f"SELECT public.start_diagnosis_provider('{leased_job}','{lease_token}')->>'allowed';") == 'true'
        if timed_out:
            sql(db, f"UPDATE public.analysis_jobs SET deadline_at=clock_timestamp()-interval '1 second' WHERE id='{leased_job}';")
            settle = f"SELECT public.read_diagnosis_job('{guest}','{leased_job}')->>'status';"
            expected = 'expired'
            quota = 'released'
        else:
            result = json.dumps({
                'schema_version': '1.0', 'mode': 'identification', 'job_id': leased_job,
                'catalogue_release_id': release, 'identification_status': 'unknown',
                'plant_id': None, 'plant_display_name': None,
            })
            settle = f"SELECT public.finish_diagnosis_job('{leased_job}','{lease_token}',$result${result}$result$::jsonb,false,NULL)->>'outcome';"
            expected = 'succeeded'
            quota = 'consumed'
        application = f'guest_bind_settle_{offset}'
        blocker = subprocess.Popen(base + ['-d', db], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, text=True, env=env)
        try:
            blocker.stdin.write(f"BEGIN; SELECT id FROM public.installation_access WHERE id='{installation}' FOR UPDATE;\n\\echo READY\n")
            blocker.stdin.flush()
            while blocker.stdout.readline().strip() != 'READY':
                if blocker.poll() is not None:
                    raise RuntimeError(blocker.stderr.read())
            with ThreadPoolExecutor(max_workers=1) as pool:
                future = pool.submit(sql, db, f"SET application_name='{application}'; " + settle)
                deadline = time.monotonic() + 10
                while sql(db, f"SELECT count(*) FROM pg_stat_activity WHERE application_name='{application}' AND wait_event_type='Lock'") != '1':
                    assert not future.done(), 'Guest settlement did not wait for installation'
                    assert time.monotonic() < deadline, 'Did not observe a real settlement waiter'
                    time.sleep(.03)
                try:
                    # The pending settlement must not already hold the guest job.
                    assert sql(db, f"SELECT id FROM public.analysis_jobs WHERE id='{leased_job}' FOR UPDATE NOWAIT;") == leased_job
                    blocker.stdin.write(f"SELECT public.bind_installation_credential('{installation}','{target}','{secret_hash}'); COMMIT;\n\\q\n")
                    blocker.stdin.flush()
                    _, error = blocker.communicate(timeout=15)
                    assert blocker.returncode == 0, error
                    assert future.result(timeout=15) == expected
                finally:
                    if blocker.poll() is None:
                        blocker.kill()
                        blocker.communicate(timeout=10)
        finally:
            if blocker.poll() is None:
                blocker.kill()
                blocker.communicate(timeout=10)
        check(db, f"(SELECT quota_state='{quota}' FROM public.analysis_jobs WHERE id='{leased_job}')",
              f'guest bind and {expected} settlement keep the correct original quota')

    def first_aid_race_fixture(db, offset, with_photo):
        owner, plant, diagnosis, entry, control, observe_op, undo_op = map(job, range(offset, offset + 7))
        sql(db, f"""
            INSERT INTO public.profiles(id,anonymous) VALUES('{owner}',false);
            INSERT INTO public.entitlements(owner_id,product_id,state,offer_kind,valid_until)
            VALUES('{owner}','app.narat.plants.pro.monthly','active','paid',clock_timestamp()+interval '5 minutes');
            INSERT INTO public.plants(id,owner_id,plant_id,creation_source,display_name)
            VALUES('{plant}','{owner}','monstera_deliciosa','identification','Observation race fixture');
            INSERT INTO public.analysis_jobs(id,owner_id,flow_id,intent,add_method,plant_id,mode,kb_release_id,
                prompt_version,operation_id,payload_hash,locale,quota_kind,quota_state,state)
            VALUES('{diagnosis}','{owner}',gen_random_uuid(),'problem','scan','{plant}','diagnosis','{K}',
                'observation-race-fixture',gen_random_uuid(),'fixture','en','none','not_applicable','succeeded');
            INSERT INTO public.care_entries(id,owner_id,plant_id,action_code,occurred_at,occurred_local_date,
                timezone,operation_id,first_aid_job_id)
            VALUES('{entry}','{owner}','{plant}','check_soil',now(),current_date,'UTC',gen_random_uuid(),'{diagnosis}');
            INSERT INTO public.first_aid_followups(id,owner_id,plant_id,origin_analysis_id,kb_release_id,
                action_code,first_action_snapshot,check_policy_snapshot,action_entry_id)
            VALUES('{control}','{owner}','{plant}',gen_random_uuid(),'{K}','check_soil','{{}}','{{"fixture":true}}','{entry}');
        """)
        payload = f"jsonb_build_object('control_id','{control}','status_code','unknown')"
        if with_photo:
            asset = sql(db, f"SELECT public.create_first_aid_photo_upload('{owner}','{job(offset+7)}',"
                        f"'{plant}','{control}','image/jpeg',4,repeat('a',64))->>'photo_asset_id';")
            assert sql(db, f"SELECT public.mark_first_aid_photo_ready('{owner}','{asset}',repeat('a',64))->>'state';") == 'ready'
            payload += f" || jsonb_build_object('photo_id','{asset}')"
        observe = (f"SELECT public.complete_first_aid_control('{owner}','{observe_op}','{plant}',"
                   f"{payload})->>'state';")
        return owner, plant, diagnosis, entry, control, observe_op, undo_op, observe, asset if with_photo else None

    def first_aid_observation_race(db, winner, offset, with_photo=False):
        owner, plant, diagnosis, entry, control, observe_op, undo_op, observe, asset = first_aid_race_fixture(
            db, offset, with_photo)
        undo = (f"SELECT public.execute_manual_care_command('{owner}','{undo_op}','{plant}','care.undo',"
                f"jsonb_build_object('entry_id','{entry}'))->>'state';")
        expire = f"UPDATE public.entitlements SET valid_until=clock_timestamp() WHERE owner_id='{owner}';"
        first = {'observe': observe, 'undo': undo, 'expiry': expire}[winner]
        second = undo if winner == 'observe' else observe
        expected = {'observe': 'voided', 'undo': 'FIRST_AID_CONTROL_INACTIVE',
                    'expiry': 'FIRST_AID_CONTROL_EXPIRED'}[winner]
        lock = f"SELECT id FROM public.profiles WHERE id='{owner}' FOR UPDATE;"
        application = f'first_aid_observe_{winner}'
        blocker = subprocess.Popen(base + ['-d', db], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, text=True, env=env)

        def compete():
            try:
                return sql(db, f"SET application_name='{application}';\n{second}")
            except RuntimeError as error:
                match = re.search(r'ERROR:\s+(FIRST_AID_CONTROL_[A-Z_]+)', str(error))
                if match:
                    return match.group(1)
                raise

        def stop_blocker():
            if blocker.poll() is None:
                blocker.kill()
                blocker.communicate(timeout=10)

        try:
            blocker.stdin.write(f"BEGIN; {lock}\n\\echo READY\n")
            blocker.stdin.flush()
            assert blocker.stdout.readline().strip() == owner and blocker.stdout.readline().strip() == 'READY'
            with ThreadPoolExecutor(max_workers=1) as pool:
                future = pool.submit(compete)
                try:
                    deadline = time.monotonic() + 10
                    while sql(db, f"SELECT count(*) FROM pg_stat_activity WHERE application_name='{application}' AND wait_event_type='Lock'") != '1':
                        assert not future.done(), 'Competing care command did not wait for owner lock'
                        assert time.monotonic() < deadline, 'Did not observe a real care command waiter'
                        time.sleep(.03)
                    blocker.stdin.write(f"{first} COMMIT;\n\\q\n")
                    blocker.stdin.flush()
                    output, error = blocker.communicate(timeout=15)
                    assert blocker.returncode == 0, error
                    assert output.strip() == {'observe': 'completed', 'undo': 'voided', 'expiry': ''}[winner]
                    assert future.result(timeout=15) == expected
                finally:
                    stop_blocker()
        finally:
            stop_blocker()
        state = {'observe': 'completed', 'undo': 'undone', 'expiry': 'active'}[winner]
        count = int(winner == 'observe')
        check(db, f"""(SELECT state='{state}' FROM public.first_aid_followups WHERE id='{control}')
            AND (SELECT count(*)={count} FROM public.care_observations WHERE first_aid_control_id='{control}')
            AND (SELECT count(*)={count} FROM public.operation_receipts WHERE owner_id='{owner}' AND operation_id='{observe_op}')
            AND (SELECT count(*)=1 FROM public.analysis_jobs WHERE owner_id='{owner}' AND quota_state='not_applicable')
            AND NOT EXISTS (SELECT 1 FROM public.analysis_jobs WHERE owner_id='{owner}' AND id<>'{diagnosis}')
            AND NOT EXISTS (SELECT 1 FROM public.account_quota_usage WHERE owner_id='{owner}')""",
              f'first-aid {winner} wins the real owner-lock race with no new job or quota spend')
        if with_photo:
            attached = f"plant_id='{plant}'" if winner == 'observe' else 'plant_id IS NULL'
            check(db, f"(SELECT {attached} FROM public.photo_assets WHERE id='{asset}') "
                  f"AND (SELECT count(*)={count} FROM public.care_observations WHERE photo_id='{asset}')",
                  f'photo attachment is atomic when {winner} wins')

    def first_aid_cleanup_race(db, cleanup_first, offset):
        owner, plant, _, _, control, observe_op, _, observe, asset = first_aid_race_fixture(db, offset, True)
        sql(db, f"UPDATE public.first_aid_photo_upload_tickets SET expires_at=clock_timestamp()-interval '1 second' WHERE photo_asset_id='{asset}';")
        claim = f"SELECT public.claim_first_aid_photo_cleanup('{asset}');"
        first = claim if cleanup_first else observe
        blocker = subprocess.Popen(base + ['-d', db], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, text=True, env=env)
        application = 'observe_after_cleanup_claim'

        def stop_blocker():
            if blocker.poll() is None:
                blocker.kill()
                blocker.communicate(timeout=10)

        def commit_blocker():
            blocker.stdin.write('COMMIT;\n\\q\n')
            blocker.stdin.flush()
            _, error = blocker.communicate(timeout=15)
            assert blocker.returncode == 0, error

        try:
            blocker.stdin.write(f"BEGIN; {first}\n\\echo READY\n")
            blocker.stdin.flush()
            result = blocker.stdout.readline().strip()
            assert blocker.stdout.readline().strip() == 'READY'
            if cleanup_first:
                assert json.loads(result)[0]['photo_id'] == asset
                with ThreadPoolExecutor(max_workers=1) as pool:
                    future = pool.submit(sql, db, f"SET application_name='{application}';\n{observe}")
                    try:
                        deadline = time.monotonic() + 10
                        while sql(db, f"SELECT count(*) FROM pg_stat_activity WHERE application_name='{application}' AND wait_event_type='Lock'") != '1':
                            assert not future.done(), 'Attach did not wait for the cleanup asset lock'
                            assert time.monotonic() < deadline, 'Did not observe the competing attach'
                            time.sleep(.03)
                        commit_blocker()
                        try:
                            future.result(timeout=15)
                        except RuntimeError as error:
                            assert 'PHOTO_NOT_READY' in str(error), error
                        else:
                            raise AssertionError('Attach succeeded after the cleanup claim')
                    finally:
                        stop_blocker()
                check(db, f"(SELECT state='deleting' AND plant_id IS NULL FROM public.photo_assets WHERE id='{asset}') "
                      f"AND (SELECT state='active' FROM public.first_aid_followups WHERE id='{control}') "
                      f"AND NOT EXISTS (SELECT 1 FROM public.operation_receipts WHERE owner_id='{owner}' AND operation_id='{observe_op}')",
                      'cleanup wins the asset lock and leaves observation uncommitted')
            else:
                assert result == 'completed'
                assert sql(db, claim) == '[]', 'cleanup must skip the asset locked by an uncommitted attach'
                commit_blocker()
                assert sql(db, claim) == '[]', 'cleanup must preserve the committed attachment'
                check(db, f"(SELECT state='ready' AND plant_id='{plant}' FROM public.photo_assets WHERE id='{asset}') "
                      f"AND EXISTS (SELECT 1 FROM public.care_observations WHERE photo_id='{asset}' AND first_aid_control_id='{control}')",
                      'attach wins the asset lock and preserves the photo')
        finally:
            stop_blocker()

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

    def bound_repeat_last_attempt(db):
        owner, plant, flow, winner, distinct, retry = map(job, range(960, 966))
        sql(db, f"""
            INSERT INTO auth.users(id,is_anonymous) VALUES('{owner}',false);
            INSERT INTO public.plants(id,owner_id,plant_id,creation_source,display_name)
            VALUES('{plant}','{owner}','monstera_deliciosa','identification','V05 fixture');
        """)

        def ready_photo():
            asset = sql(db, f"SELECT public.create_diagnosis_upload('{owner}',gen_random_uuid(),"
                        "'image/jpeg',4,repeat('a',64))->>'photo_asset_id';")
            assert sql(db, f"SELECT public.mark_diagnosis_upload_ready('{owner}','{asset}',repeat('a',64))->>'state';") == 'ready'
            return asset

        def admission(operation, asset, can_dispatch=True):
            return (f"SELECT public.create_plant_diagnosis_job('{owner}',{operation},'{asset}',"
                    f"'{flow}','en',{str(can_dispatch).lower()},'{plant}');")

        def read_job(job_id):
            return json.loads(sql(db, f"SELECT public.read_diagnosis_job('{owner}','{job_id}');"))

        def settle(job_id, succeeded):
            lease = json.loads(sql(db, f"SELECT public.lease_diagnosis_job('{job_id}');"))
            assert lease and lease['job_id'] == job_id
            assert sql(db, f"SELECT public.start_diagnosis_provider('{job_id}','{lease['lease_token']}')->>'allowed';") == 'true'
            result = (f"jsonb_build_object('job_id','{job_id}','mode','diagnosis',"
                      f"'kb_release_id','{lease['kb_release_id']}')") if succeeded else 'NULL'
            error = 'NULL' if succeeded else "'PROVIDER_FAILURE_FIXTURE'"
            return sql(db, f"SELECT public.finish_diagnosis_job('{job_id}','{lease['lease_token']}',"
                       f"{result},{str(not succeeded).lower()},{error})->>'quota_state';")

        # Consume the starter and the first two monthly attempts through real admission and settlement.
        for quota in ('starter_diagnosis', 'free_monthly', 'free_monthly'):
            seeded = json.loads(sql(db, admission('gen_random_uuid()', ready_photo())))['job']
            assert seeded['quota_kind'] == quota and settle(seeded['job_id'], True) == 'consumed'

        original_photo, other_photo = ready_photo(), ready_photo()
        create = admission(f"'{winner}'", original_photo)
        replay = admission(f"'{winner}'", original_photo, can_dispatch=False)
        competing = '\\set VERBOSITY verbose\n' + admission(f"'{distinct}'", other_photo)

        def expect_exhausted(action):
            try:
                action()
            except RuntimeError as error:
                failure = re.search(r'ERROR:\s+(P0001): (QUOTA_DENIED).*?DETAIL:\s+(free_monthly_exhausted)',
                                    str(error), re.S)
                assert failure, error
                code, message, details = failure.groups()
                return {'code': code, 'message': message, 'details': details}
            else:
                raise AssertionError('A distinct request bypassed the last-attempt limit')

        first = subprocess.Popen(base + ['-d', db], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                 stderr=subprocess.PIPE, text=True, env=env)

        def stop_first():
            if first.poll() is None:
                first.kill()
                first.communicate(timeout=10)

        try:
            first.stdin.write(f"BEGIN; {create}\n\\echo READY\n")
            first.stdin.flush()
            accepted = json.loads(first.stdout.readline())
            assert first.stdout.readline().strip() == 'READY' and accepted['replayed'] is False
            with ThreadPoolExecutor(max_workers=2) as pool:
                exact = pool.submit(sql, db, "SET application_name='v05_exact'; " + replay)
                different = pool.submit(sql, db, "SET application_name='v05_distinct';\n" + competing)
                try:
                    deadline = time.monotonic() + 10
                    while sql(db, "SELECT count(*) FROM pg_stat_activity WHERE application_name IN ('v05_exact','v05_distinct') AND wait_event_type='Lock';") != '2':
                        assert not exact.done() and not different.done(), 'V05 contenders bypassed the owner lock'
                        assert time.monotonic() < deadline, 'V05 contenders never overlapped'
                        time.sleep(.03)
                    first.stdin.write('COMMIT;\n\\q\n')
                    first.stdin.flush()
                    _, error = first.communicate(timeout=15)
                    assert first.returncode == 0, error
                    concurrent_replay = json.loads(exact.result(timeout=15))
                    assert concurrent_replay == {**accepted, 'replayed': True}
                    concurrent_denial = expect_exhausted(lambda: different.result(timeout=15))
                finally:
                    stop_first()
        finally:
            stop_first()

        receipt = accepted['job']
        failed_job = receipt['job_id']
        assert receipt['quota_kind'] == 'free_monthly' and receipt['quota_state'] == 'reserved'
        assert receipt['target_plant_id'] == plant and receipt['photo_asset_id'] == original_photo
        check(db, f"""(SELECT count(*)=3 AND count(*) FILTER (WHERE quota_state='consumed')=2
                 AND count(*) FILTER (WHERE quota_state='reserved' AND job_id='{failed_job}')=1
                 FROM public.account_quota_usage WHERE owner_id='{owner}')""",
              'V05 concurrent requests leave exactly one reservation on the winning job')
        assert settle(failed_job, False) == 'released'
        failed = read_job(failed_job)
        assert failed['status'] == 'failed' and failed['quota_state'] == 'released'
        failed_replay = json.loads(sql(db, replay))
        assert failed_replay == concurrent_replay

        retried = json.loads(sql(db, admission(f"'{retry}'", original_photo)))
        replacement = retried['job']
        assert retried['replayed'] is False and replacement['job_id'] != failed_job
        assert replacement['target_plant_id'] == plant and replacement['photo_asset_id'] == original_photo
        assert replacement['quota_kind'] == 'free_monthly' and settle(replacement['job_id'], True) == 'consumed'
        terminal = read_job(replacement['job_id'])
        assert terminal['status'] == 'succeeded' and terminal['quota_state'] == 'consumed'
        terminal_denial = expect_exhausted(lambda: sql(db, competing))
        terminal_replay = json.loads(sql(db, admission(f"'{retry}'", original_photo, False)))
        assert terminal_replay == {**retried, 'replayed': True}
        assert read_job(failed_job) == failed and read_job(replacement['job_id']) == terminal
        check(db, f"""(SELECT count(*)=5 FROM public.analysis_jobs WHERE owner_id='{owner}')
            AND (SELECT count(*)=5 FROM public.operation_receipts WHERE owner_id='{owner}' AND command_name='analysis.job.create')
            AND NOT EXISTS (SELECT 1 FROM public.operation_receipts WHERE owner_id='{owner}' AND operation_id='{distinct}')
            AND (SELECT count(*)=4 AND count(*) FILTER (WHERE quota_state='consumed')=3
                 AND count(*) FILTER (WHERE quota_state='released')=1
                 FROM public.account_quota_usage WHERE owner_id='{owner}')""",
              'V05 bound repeat: concurrent last Free attempt, immutable replay, release and one successful retry')
        wire = dict(owner=owner, plant=plant, flow=flow, winner=winner, distinct=distinct, retry=retry,
                    original_photo=original_photo, other_photo=other_photo, accepted=accepted,
                    concurrent_replay=concurrent_replay, concurrent_denial=concurrent_denial,
                    failed=failed, failed_replay=failed_replay, retried=retried, terminal=terminal,
                    terminal_denial=terminal_denial, terminal_replay=terminal_replay)
        command(['deno', 'run', '-A', '--config', str(ROOT/'supabase/functions/deno.json'),
                 str(ROOT/'tools/automation/v05_bound_repeat_wire.ts')], json.dumps(wire))
        print(f'PASS {db}: V05 202/200/429 and terminal GET through production Edge using real SQL outcomes', flush=True)

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
                assert any(m.name == SECOND for m in selected), 'Settlement migration required'
            if args.bind:
                assert any(m.name == BIND for m in selected), 'Binding migration required'
            if args.installations:
                assert any(m.name == INSTALLATIONS for m in selected), 'Credential API migration required'
            if args.access:
                assert any(m.name == ACCESS for m in selected), 'Access snapshot migration required'
        for case in ('clean','upgrade'):
            sql('postgres', f'CREATE DATABASE {case};')
            sql(case, "CREATE SCHEMA auth; CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$ SELECT NULLIF(current_setting('request.jwt.claim.sub',true),'')::uuid $$; GRANT USAGE ON SCHEMA auth TO PUBLIC; CREATE TABLE auth.users(id uuid PRIMARY KEY,is_anonymous boolean,created_at timestamptz NOT NULL DEFAULT clock_timestamp());")
            if args.diagnosis_upload or any(m.name == '202611130035_plant_delete_storage.sql' for m in selected):
                sql(case, 'CREATE SCHEMA storage; CREATE TABLE storage.buckets(id text PRIMARY KEY, name text NOT NULL, public boolean, file_size_limit bigint, allowed_mime_types text[]); CREATE TABLE storage.objects(bucket_id text, name text, PRIMARY KEY(bucket_id,name));')
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
                if any(m.name == '202611120023_retire_notification_claim_writes.sql' for m in selected):
                    sql(case, f"INSERT INTO public.installation_access(id,credential_hash) VALUES('{job(890)}',repeat('f',64)); "
                        f"INSERT INTO public.notification_claims(id,owner_id,kind,period_key,installation_id,scheduled_at,state,updated_at) "
                        f"VALUES('{job(891)}','{A}','progress_report','2026-11','{job(890)}','2026-11-01','scheduled','2026-11-01'); "
                        f"INSERT INTO public.operation_receipts(owner_id,operation_id,command_name,payload_hash,response_payload) "
                        f"VALUES('{A}','{job(892)}','notification.claim','historical',jsonb_build_object('granted',true));")
                if any(m.name == '202611120024_retire_notification_sync_projection.sql' for m in selected):
                    sql(case, f"UPDATE public.profiles SET report_notifications_enabled=true,trial_reminder_enabled=true WHERE id='{A}';")
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
            if args.access and any(m.name == '202611120022_auth_registration_profile.sql' for m in selected):
                tap(case, ROOT/'supabase/tests/auth_registration_profile.test.sql')
            if args.access and any(m.name == '202611120023_retire_notification_claim_writes.sql' for m in selected):
                tap(case, ROOT/'supabase/tests/notification_claim_retirement.test.sql')
            if args.access and any(m.name == '202611120024_retire_notification_sync_projection.sql' for m in selected):
                tap(case, ROOT/'supabase/tests/notification_sync_retirement.test.sql')
            if args.diagnosis_upload:
                tap(case, ROOT/'supabase/tests/diagnosis_upload.test.sql')
            if args.diagnosis_jobs:
                catalogue = json.loads((ROOT/'catalogue/releases/skeleton-300-v1/plants.json').read_text())
                plant = next(x for x in catalogue['plants'] if x['plant_id'] == 'monstera_deliciosa')
                encoded = json.dumps(plant, ensure_ascii=False)
                assert '$fixture$' not in encoded
                release = job(880)
                sql(case, f"INSERT INTO public.catalogue_releases(id, version) VALUES('{release}', 'diagnosis-gate'); "
                    f"SELECT public.upsert_catalogue_skeleton_species('{release}', $fixture${encoded}$fixture$::jsonb, true); "
                    f"SELECT public.publish_catalogue_release('{release}');")
                tap(case, ROOT/'supabase/tests/diagnosis_jobs.test.sql')
                if any(migration.name == '202611120025_repeat_plant_diagnosis.sql' for migration in selected):
                    tap(case, ROOT/'supabase/tests/repeat_plant_diagnosis.test.sql')
                    bound_repeat_last_attempt(case)
                if any(migration.name == '202611120021_guest_photo_claim.sql' for migration in selected):
                    guest_settlement_bind_race(case, release, timed_out=False)
                    guest_settlement_bind_race(case, release, timed_out=True)
                if any(migration.name == CARE_JOURNAL for migration in selected):
                    tap(case, ROOT/'supabase/tests/manual_care_journal.test.sql')
                if any(migration.name == '202611120026_manual_care_date_correction.sql' for migration in selected):
                    tap(case, ROOT/'supabase/tests/manual_care_date_correction.test.sql')
                if any(migration.name == CARE_PROFILE_READ for migration in selected):
                    tap(case, ROOT/'supabase/tests/plant_care_profile_read.test.sql')
                if any(migration.name == '202611120027_plant_next_check.sql' for migration in selected):
                    tap(case, ROOT/'supabase/tests/plant_next_check.test.sql')
                if any(migration.name == '202611120028_first_aid_control.sql' for migration in selected):
                    tap(case, ROOT/'supabase/tests/first_aid_control.test.sql')
                if any(migration.name == '202611120030_first_aid_observation.sql' for migration in selected):
                    tap(case, ROOT/'supabase/tests/first_aid_observation.test.sql')
                    with_photo = any(migration.name == '202611120031_first_aid_observation_photo.sql' for migration in selected)
                    if with_photo:
                        tap(case, ROOT/'supabase/tests/first_aid_observation_photo.test.sql')
                    for offset, winner in enumerate(('observe', 'undo', 'expiry'), start=1):
                        first_aid_observation_race(case, winner, 900 + offset * 10, with_photo)
                if any(migration.name == '202611120032_first_aid_photo_cleanup.sql' for migration in selected):
                    tap(case, ROOT/'supabase/tests/first_aid_photo_cleanup.test.sql')
                    first_aid_cleanup_race(case, cleanup_first=True, offset=940)
                    first_aid_cleanup_race(case, cleanup_first=False, offset=950)
                if any(migration.name == '202611120033_plant_delete_core.sql' for migration in selected):
                    tap(case, ROOT/'supabase/tests/plant_delete_core.test.sql')
                if any(migration.name == '202611130034_plant_delete_access.sql' for migration in selected):
                    tap(case, ROOT/'supabase/tests/plant_delete_access.test.sql')
                if any(migration.name == '202611130035_plant_delete_storage.sql' for migration in selected):
                    tap(case, ROOT/'supabase/tests/plant_delete_storage.test.sql')
                if any(migration.name == '202611130036_plant_delete_analysis_data.sql' for migration in selected):
                    tap(case, ROOT/'supabase/tests/plant_delete_analysis_data.test.sql')
                if any(migration.name == '202611130037_plant_delete_expired_lease.sql' for migration in selected):
                    tap(case, ROOT/'supabase/tests/plant_delete_expired_lease.test.sql')
            if not args.accounting and not args.anchors:
                tap(case, ROOT/'supabase/tests/registration_reservation.test.sql')
                if not args.reserve:
                    tap(case, ROOT/'supabase/tests/registration_admission.test.sql')
                if args.bind:
                    tap(case, ROOT/'supabase/tests/registration_bind.test.sql')
                if args.installations:
                    tap(case, ROOT/'supabase/tests/registration_installations.test.sql')
                if args.access:
                    tap(case, ROOT/'supabase/tests/registration_access.test.sql')
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
