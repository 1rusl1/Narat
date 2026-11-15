"""Rehearse the exact T149 cutover and rollback against an isolated local PG database."""

import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import uuid


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools/automation"))
from publish_staging_catalogue import (
    BUCKET, CARE_KB, PILOT_PLANTS, PILOT_TAXA, PRIOR_RELEASE, RELEASE, VERSION,
    load_release, render_sql, sql_json,
)

OLD_KB = "3ed50000-0000-4000-8000-000000000011"
OWNERS = ("14900000-0000-4000-8000-000000000001", "14900000-0000-4000-8000-000000000002")
JOB = "14900000-0000-4000-8000-000000000003"
ENTRY = "14900000-0000-4000-8000-000000000004"
DUMMY = "14900000-0000-4000-8000-000000000005"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--psql", default="psql")
    args = parser.parse_args()
    pg_host = os.environ.get("PGHOST", "")
    if not pg_host.startswith("/") or not Path(pg_host).is_dir():
        parser.error("Use a disposable local PostgreSQL cluster with a Unix socket PGHOST.")
    db = "narat_t149_" + uuid.uuid4().hex
    base = [args.psql, "-X", "-qAt", "-v", "ON_ERROR_STOP=1", "-h", pg_host]

    def sql(statement, database=db, error=None):
        result = subprocess.run(base + ["-d", database], input=statement, text=True,
                                capture_output=True, timeout=150, check=False)
        if error:
            assert result.returncode and error in result.stderr, result.stderr
            return
        if result.returncode:
            raise RuntimeError(result.stderr)
        return result.stdout.strip()

    records, assets, sources = load_release()
    by_slug = {record["plant_id"]: record for record in records}
    sql(f"CREATE DATABASE {db}", "postgres")
    try:
        sql("""
CREATE SCHEMA auth;
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS
  $$ SELECT NULLIF(current_setting('request.jwt.claim.sub', true), '')::uuid $$;
GRANT USAGE ON SCHEMA auth TO PUBLIC;
CREATE TABLE auth.users (id uuid PRIMARY KEY, is_anonymous boolean);
CREATE SCHEMA storage;
CREATE TABLE storage.buckets (
  id text PRIMARY KEY, name text, public boolean, file_size_limit bigint, allowed_mime_types text[]);
CREATE TABLE storage.objects (
  id uuid DEFAULT gen_random_uuid(), bucket_id text, name text, metadata jsonb,
  UNIQUE(bucket_id,name));
""")
        migrations = sorted((ROOT / "supabase/migrations").glob("*.sql"))
        target = migrations[-1]
        assert target.name == "202611120018_catalogue_pl_description_fallback.sql"
        for migration in migrations[:-1]:
            sql(migration.read_text())

        pilot = [by_slug[key] for key in PILOT_TAXA]
        sql(f"INSERT INTO public.catalogue_releases(id,version) VALUES ('{PRIOR_RELEASE}','staging-smoke-20261106');")
        for record in pilot:
            slug = record["plant_id"]
            sql(f"""INSERT INTO public.catalogue_taxa(id,plant_id,accepted_scientific_name)
                    SELECT '{PILOT_TAXA[slug]}', item->>'plant_id', item->>'scientific_name'
                    FROM (SELECT {sql_json(record)} AS item) q;
                    SELECT public.upsert_catalogue_skeleton_species('{PRIOR_RELEASE}',{sql_json(record)},true);""")
        sql(f"SELECT public.publish_catalogue_release('{PRIOR_RELEASE}')")
        profile = json.loads((ROOT / "knowledge-base/releases/staging-monstera-care-v2/monstera-watering.json").read_text())
        sql(f"""
INSERT INTO public.kb_releases(id,version,state)
VALUES ('{OLD_KB}','staging-diagnosis-monstera-v1','retired'),
       ('{CARE_KB}','staging-monstera-care-v2','published');
INSERT INTO public.care_profiles(kb_release_id,taxon_id,version,profile,field_evidence,state)
VALUES ('{CARE_KB}','{PILOT_TAXA["monstera_deliciosa"]}','1',{sql_json(profile)},'{{}}','published');
INSERT INTO public.profiles(id,anonymous) VALUES ('{OWNERS[0]}',false),('{OWNERS[1]}',false);
INSERT INTO public.plants(id,owner_id,taxon_id,display_name)
VALUES ('{PILOT_PLANTS[0]}','{OWNERS[0]}','{PILOT_TAXA["monstera_deliciosa"]}','Fixture Monstera A'),
       ('{PILOT_PLANTS[1]}','{OWNERS[1]}','{PILOT_TAXA["monstera_deliciosa"]}','Fixture Monstera B');
INSERT INTO public.care_entries(id,owner_id,plant_id,action_code,occurred_at,occurred_local_date,timezone,state,operation_id)
VALUES ('{ENTRY}','{OWNERS[0]}','{PILOT_PLANTS[0]}','water','2026-11-11T12:00Z','2026-11-11','UTC','voided',gen_random_uuid());
INSERT INTO public.care_reversals(owner_id,entry_id,operation_id)
VALUES ('{OWNERS[0]}','{ENTRY}',gen_random_uuid());
INSERT INTO public.analysis_jobs(id,owner_id,flow_id,intent,add_method,mode,kb_release_id,prompt_version,
    operation_id,payload_hash,locale,quota_kind,quota_state,state)
VALUES ('{JOB}','{OWNERS[0]}',gen_random_uuid(),'problem','scan','diagnosis','{OLD_KB}','3.0',
    gen_random_uuid(),repeat('a',64),'en','starter_diagnosis','consumed','succeeded');
INSERT INTO public.diagnosis_job_runtime(job_id,catalogue_release_id,projection)
VALUES ('{JOB}','{PRIOR_RELEASE}',jsonb_build_object('kb_release_id','{OLD_KB}','fixture',true));
""")
        begonia = sql_json(by_slug["begonia_maculata"])
        validation = f"SELECT public.validate_catalogue_skeleton_species_record({begonia});"
        sql(validation, error="invalid_catalogue_species_schema")
        sql(target.read_text())
        sql(validation)
        print("018 upgrade: explicit Polish gap accepted, English retained", flush=True)

        with tempfile.TemporaryDirectory(prefix="narat-t149-sql-") as temp:
            output = Path(temp) / "release"
            render_sql(output, records, assets, sources)
            apply = lambda name, **kw: sql((output / name).read_text(), **kw)
            apply("00-bucket.sql")
            apply("01-draft.sql")
            for batch in sorted(output.glob("draft-*.sql")):
                apply(batch.name)
            apply("draft-01.sql")
            assert sql("SELECT public.search_catalogue_species('', 'en', 1, 0)->>'total'") == "3"

            apply("99-activate.sql", error="catalogue_media_is_missing_or_invalid")
            objects = [{"key": a.key, "size": str(a.size), "mimetype": a.mime} for a in assets]
            sql(f"""INSERT INTO storage.objects(bucket_id,name,metadata)
                    SELECT '{BUCKET}',item->>'key',item-'key'
                    FROM jsonb_array_elements({sql_json(objects)}) item;""")
            sql(f"""INSERT INTO public.catalogue_taxa(id,plant_id,accepted_scientific_name)
                    VALUES ('{DUMMY}','fixture_wrong_taxon','Fixture wrong taxon');
                    UPDATE public.catalogue_release_species SET taxon_id='{DUMMY}'
                    WHERE release_id='{RELEASE}' AND plant_id='monstera_deliciosa';""")
            apply("99-activate.sql", error="protected_pilot_identity_or_history_unavailable")
            assert sql("SELECT public.search_catalogue_species('', 'en', 1, 0)->>'total'") == "3"
            sql(f"""UPDATE public.catalogue_release_species SET taxon_id='{PILOT_TAXA["monstera_deliciosa"]}'
                    WHERE release_id='{RELEASE}' AND plant_id='monstera_deliciosa';""")
            apply("99-activate.sql")
            apply("99-activate.sql")
            assert sql("SET ROLE anon; SELECT public.search_catalogue_species('', 'en', 1, 0)->>'total'") == "606"
            assert sql("""SET ROLE anon; SELECT public.get_catalogue_species_card('begonia_maculata','pl')
                           ->'description'->>'language'""") == "en"
            assert sql(f"SELECT public.read_diagnosis_job('{OWNERS[0]}','{JOB}')->'result'->>'kb_release_id'") == OLD_KB
            apply("rollback.sql")
            assert sql("SELECT public.search_catalogue_species('', 'en', 1, 0)->>'total'") == "3"
            apply("99-activate.sql")
            assert sql(f"SELECT version FROM public.catalogue_releases WHERE id='{RELEASE}' AND state='published'") == VERSION
        print("T149 rehearsal PASS: 606 records, pilot UUID/advice/journal/diagnoses, "
              "missing-media and UUID-mismatch rejection, activation replay, rollback and reactivation", flush=True)
    finally:
        sql(f"DROP DATABASE {db} WITH (FORCE)", "postgres")


if __name__ == "__main__":
    main()
