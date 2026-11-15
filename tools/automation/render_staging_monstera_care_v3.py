"""Render the exact, staging-only activation of the reviewed Monstera v3 data."""
import hashlib
import json
from pathlib import Path
import sys


V2_ID = "3ed50000-0000-4000-8000-000000000012"
V3_ID = "3ed50000-0000-4000-8000-000000000013"
V2_MANIFEST = "7349299f74a36747e0c6042e581e706e36cb844002e19395fd8edc6448978d80"
TAXON = "83f27806-3577-4bdc-9b18-222bedcf06d7"
CATALOGUE = "skeleton-300-v1-en-85fcaba4"
ACTION = "check_monstera_mix_before_watering"
ROOT = Path(__file__).resolve().parents[2]


def canonical(value):
    return json.dumps(value, sort_keys=True, ensure_ascii=False, separators=(",", ":"))


def literal(value):
    data = canonical(value)
    tag = "$narat_v3$"
    if tag in data or "$activation$" in data:
        raise ValueError("Unexpected SQL dollar-quote delimiter")
    return f"{tag}{data}{tag}::jsonb"


def render(root):
    releases = root / "knowledge-base/releases"
    prior = json.loads((releases / "staging-monstera-care-v2/monstera-watering.json").read_text())
    condition_v1 = json.loads((releases / "staging-diagnosis-v1/monstera-overwatering.json").read_text())
    prior_condition = {**condition_v1, "kb_release_id": V2_ID}
    next_condition = {**prior_condition, "kb_release_id": V3_ID}
    previous_manifest = hashlib.sha256(canonical({"plant": prior, "condition": prior_condition}).encode()).hexdigest()
    if previous_manifest != V2_MANIFEST:
        raise ValueError("Unexpected content in the source release")

    release = releases / "staging-monstera-care-v3"
    care = json.loads((release / "monstera-watering.json").read_text())
    contextual = json.loads((release / "refresh-conditions.json").read_text())
    expected = {"refresh_conditions": {ACTION: {
        "light_code": "medium", "light_source": "manual", "light_confirmed": True,
        "watering_code": "unknown", "drainage_code": "yes", "pot_type": "plastic",
    }}}
    if (
        care["kb_release_id"] != V3_ID or care["plant_id"] != "monstera_deliciosa"
        or care["record_version"] != 2 or len(care["actions"]) != 1
        or care["actions"][0]["action_id"] != ACTION
        or care["actions"][0]["next_check_interval_days"] != 7 or canonical(contextual) != canonical(expected)
    ):
        raise ValueError("Unexpected release identity, cadence or applicability")
    report = care["provenance"]["validation"] | contextual
    manifest = hashlib.sha256(canonical({"plant": care, "condition": next_condition, "validation_report": report}).encode()).hexdigest()
    return f"""BEGIN;
SET LOCAL lock_timeout = '5s';
LOCK TABLE public.kb_releases, public.catalogue_releases, public.catalogue_taxa,
    public.care_profiles, public.condition_profiles, public.kb_vocabularies,
    public.kb_fallback_protocols IN SHARE ROW EXCLUSIVE MODE;
DO $activation$
DECLARE
    v2 constant uuid := '{V2_ID}';
    v3 constant uuid := '{V3_ID}';
    taxon constant uuid := '{TAXON}';
    before_care constant jsonb := {literal(prior)};
    before_condition constant jsonb := {literal(prior_condition)};
    after_care constant jsonb := {literal(care)};
    after_condition constant jsonb := {literal(next_condition)};
    after_report constant jsonb := {literal(report)};
    before_manifest constant text := '{V2_MANIFEST}';
    after_manifest constant text := '{manifest}';
    active_id uuid;
BEGIN
    IF obj_description('public.read_plant_care_profile(uuid,uuid)'::regprocedure, 'pg_proc')
       IS DISTINCT FROM 'explicit-contextual-calendar:056' THEN
        RAISE EXCEPTION 'V19_CONTEXTUAL_CALENDAR_GUARD_REQUIRED';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM public.catalogue_taxa t
        JOIN public.catalogue_releases r ON r.id=t.release_id
        WHERE t.id=taxon AND t.status='published' AND t.plant_id='monstera_deliciosa'
          AND r.state='published' AND r.version='{CATALOGUE}' AND r.kb_release_id IS NULL
    ) OR EXISTS (
        SELECT 1 FROM public.catalogue_releases WHERE state='published' AND kb_release_id IN(v2,v3)
    ) THEN
        RAISE EXCEPTION 'UNEXPECTED_STAGING_CATALOGUE';
    END IF;

    SELECT id INTO STRICT active_id FROM public.kb_releases WHERE state='published';
    IF NOT EXISTS (
        SELECT 1 FROM public.kb_releases WHERE id=v2 AND version='staging-monstera-care-v2'
          AND manifest_sha256=before_manifest AND state=CASE WHEN active_id=v2 THEN 'published' ELSE 'retired' END
    ) OR (SELECT count(*) FROM public.care_profiles WHERE kb_release_id=v2) <> 1
      OR (SELECT count(*) FROM public.condition_profiles WHERE kb_release_id=v2) <> 1
      OR EXISTS (SELECT 1 FROM public.kb_vocabularies WHERE kb_release_id=v2)
      OR EXISTS (SELECT 1 FROM public.kb_fallback_protocols WHERE kb_release_id=v2)
      OR NOT EXISTS (
        SELECT 1 FROM public.care_profiles WHERE kb_release_id=v2 AND taxon_id=taxon
          AND state='published' AND profile=before_care AND version=before_care->>'record_version'
          AND field_evidence=before_care#>'{{provenance,field_evidence}}'
          AND validation_report=before_care#>'{{provenance,validation}}'
    ) OR NOT EXISTS (
        SELECT 1 FROM public.condition_profiles WHERE kb_release_id=v2 AND condition_id='overwatering'
          AND state='published' AND protocol=before_condition
    ) THEN
        RAISE EXCEPTION 'UNEXPECTED_STAGING_SOURCE_RELEASE';
    END IF;

    IF active_id=v2 THEN
        INSERT INTO public.kb_releases (id,version,state,schema_version,manifest_sha256,seed_version,
            condition_manifest_version,disambiguation_policy,prompt_version,guardrail_version,validation_report)
        SELECT v3,'staging-monstera-care-v3','validated',schema_version,after_manifest,seed_version,
            condition_manifest_version,disambiguation_policy,prompt_version,guardrail_version,
            jsonb_build_object('scope','staging_monstera_care','source_release_id',v2)
        FROM public.kb_releases WHERE id=v2;
        INSERT INTO public.condition_profiles (kb_release_id,condition_id,version,protocol,field_evidence,state)
        SELECT v3,condition_id,version,after_condition,field_evidence,'published'
        FROM public.condition_profiles WHERE kb_release_id=v2 AND condition_id='overwatering';
        INSERT INTO public.care_profiles (kb_release_id,taxon_id,version,profile,field_evidence,validation_report,state)
        VALUES (v3,taxon,after_care->>'record_version',after_care,
            after_care#>'{{provenance,field_evidence}}',after_report,'published');
        UPDATE public.kb_releases SET state='retired' WHERE id=v2;
        UPDATE public.kb_releases SET state='published',published_at=clock_timestamp() WHERE id=v3;
    ELSIF active_id<>v3 THEN
        RAISE EXCEPTION 'UNEXPECTED_STAGING_ACTIVE_RELEASE';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM public.kb_releases WHERE id=v3 AND version='staging-monstera-care-v3'
          AND manifest_sha256=after_manifest AND state='published'
    ) OR (SELECT count(*) FROM public.care_profiles WHERE kb_release_id=v3) <> 1
      OR (SELECT count(*) FROM public.condition_profiles WHERE kb_release_id=v3) <> 1
      OR EXISTS (SELECT 1 FROM public.kb_vocabularies WHERE kb_release_id=v3)
      OR EXISTS (SELECT 1 FROM public.kb_fallback_protocols WHERE kb_release_id=v3)
      OR NOT EXISTS (
        SELECT 1 FROM public.care_profiles WHERE kb_release_id=v3 AND taxon_id=taxon
          AND state='published' AND profile=after_care AND version=after_care->>'record_version'
          AND field_evidence=after_care#>'{{provenance,field_evidence}}' AND validation_report=after_report
    ) OR NOT EXISTS (
        SELECT 1 FROM public.condition_profiles old JOIN public.condition_profiles new
          ON new.kb_release_id=v3 AND new.condition_id=old.condition_id
        WHERE old.kb_release_id=v2 AND old.condition_id='overwatering'
          AND new.state='published' AND new.protocol=after_condition
          AND new.version=old.version AND new.field_evidence=old.field_evidence
    ) THEN
        RAISE EXCEPTION 'UNEXPECTED_STAGING_TARGET_RELEASE';
    END IF;
END;
$activation$;
COMMIT;
"""


if __name__ == "__main__":
    workspace = Path(sys.argv[1]) if len(sys.argv) == 2 else ROOT
    print(render(workspace), end="")
