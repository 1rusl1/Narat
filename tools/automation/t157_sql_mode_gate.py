"""Isolated PostgreSQL 17 clean/upgrade acceptance for the analysis-mode guard."""
from pathlib import Path
import hashlib,json,os,re,shutil,subprocess,tempfile

ROOT=Path(__file__).resolve().parents[2]
BIN=Path('/opt/homebrew/opt/postgresql@17/bin')
PGTAP=Path('/private/tmp/pgtap-1.3.4/sql/pgtap.sql')
NAME='202611090001_analysis_mode_guard.sql'
base=(ROOT/'supabase/migrations/202610200012_quota_operations.sql').read_text()
pattern=r'CREATE OR REPLACE FUNCTION public.admit_analysis_quota\(.*?\n\$\$;'
original=re.search(pattern,base,re.S).group()
expected=original.replace("IF p_mode NOT IN ('identification', 'diagnosis', 'follow_up') THEN", "IF p_mode IS NULL OR p_mode NOT IN ('identification', 'diagnosis') THEN")
obsolete="""  IF p_mode = 'follow_up' AND NOT v_has_paid THEN
    RETURN jsonb_build_object(
      'admitted', FALSE,
      'reason', 'paid_subscription_required_for_follow_up'
    );
  END IF;

"""
assert obsolete in expected
expected=expected.replace(obsolete,'')
new=(ROOT/'supabase/migrations'/NAME).read_text()
match=re.search(pattern,new,re.S)
assert match and match.group().strip()==expected.strip(),'Migration must change only mode guard and removed paid-only branch'
rest=new[:match.start()]+new[match.end():]
assert not re.sub(r'--[^\n]*','',rest).strip(),'Unexpected migration statements'
assert BIN.joinpath('initdb').is_file() and PGTAP.is_file(),'PostgreSQL17/cached real pgTAP required'
work=Path(tempfile.mkdtemp(prefix='narat-mode-upgrade-'));data=work/'data';sock=work/'socket';sock.mkdir();started=False
clean_env={k:v for k,v in os.environ.items() if not k.startswith('PG')}
clean_env.update(PGHOST=str(sock),PGPORT='55479',PGUSER='postgres')
def command(argv,stdin=None):
    p=subprocess.run(argv,input=stdin,text=True,capture_output=True,env=clean_env,timeout=120)
    if p.returncode:raise RuntimeError(p.stderr[-1800:] or p.stdout[-1800:])
    return p.stdout.strip()
def sql(db,text):return command([str(BIN/'psql'),'-X','-qAt','-v','ON_ERROR_STOP=1','-d',db],text)
def snapshot(db):
    tables=sql(db,"SELECT tablename FROM pg_tables WHERE schemaname='public' ORDER BY tablename").splitlines()
    return {t:sql(db,'SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY to_jsonb(t)::text),\'[]\'::jsonb)::text FROM public.\"'+t+'\" t') for t in tables}
try:
    command([str(BIN/'initdb'),'-D',str(data),'-A','trust','-U','postgres','--no-locale','--encoding=UTF8'])
    command([str(BIN/'pg_ctl'),'-D',str(data),'-l',str(work/'postgres.log'),'-o',f'-h "" -k {sock} -p 55479','-w','start']);started=True
    sql('postgres','CREATE ROLE anon; CREATE ROLE authenticated; CREATE ROLE service_role BYPASSRLS;')
    migrations=sorted((ROOT/'supabase/migrations').glob('*.sql'));seed=(ROOT/'supabase/tests/analysis_mode_upgrade.seed.sql').read_text();test=(ROOT/'supabase/tests/analysis_mode_guard.test.sql').read_text()
    for case in ['clean','upgrade']:
        sql('postgres',f'CREATE DATABASE {case};')
        sql(case,"CREATE SCHEMA auth; CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$ SELECT NULLIF(current_setting('request.jwt.claim.sub', true), '')::uuid $$; GRANT USAGE ON SCHEMA auth TO PUBLIC; CREATE TABLE auth.users(id uuid PRIMARY KEY,is_anonymous boolean);")
        for migration in migrations:
            if case=='upgrade' and migration.name>=NAME:continue
            sql(case,migration.read_text())
        sql(case,PGTAP.read_text());sql(case,seed)
        before=snapshot(case)
        if case=='upgrade':
            for migration in migrations:
                if migration.name>=NAME:sql(case,migration.read_text())
            assert snapshot(case)==before,'Upgrade changed historical table data'
        expected_body=expected.split('AS $$\n',1)[1].rsplit('\n$$;',1)[0]
        assert sql(case,"SELECT prosrc FROM pg_proc WHERE oid='public.admit_analysis_quota(text,uuid,uuid,uuid,timestamptz)'::regprocedure").strip()==expected_body.strip(),'Seed changed admission function'
        tap=sql(case,test)
        plan=re.findall(r'^1\.\.(\d+)$',tap,re.M);assertions=re.findall(r'^(?:not )?ok \d+',tap,re.M)
        assert len(plan)==1 and len(assertions)==int(plan[0]) and len(assertions)>0,'Invalid TAP plan'
        assert not re.search(r'#\s*(?:SKIP|TODO)\b',tap,re.I),'Skipped/TODO acceptance is forbidden'
        tap_path=work/(case+'.tap');tap_path.write_text(tap+'\n');command(['prove','--exec','cat',str(tap_path)])
        assert snapshot(case)==before,'Tests did not rollback table changes'
        print(f'PASS: {case}, {len(assertions)} real pgTAP assertions; historical rows unchanged',flush=True)
    print('PASS: exact forward migration, clean+upgrade PostgreSQL17; fixture DB only, no live deployment')
finally:
    if started:subprocess.run([str(BIN/'pg_ctl'),'-D',str(data),'-m','fast','-w','stop'],capture_output=True,timeout=30,check=True)
    shutil.rmtree(work)
