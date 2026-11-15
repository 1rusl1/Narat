"""Render the versioned Monstera KB activation for the documented staging project."""
import hashlib
import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
RELEASES = ROOT / "knowledge-base/releases"
OLD_ID = "3ed50000-0000-4000-8000-000000000011"
NEW_ID = "3ed50000-0000-4000-8000-000000000012"


def canonical(value):
    return json.dumps(value, sort_keys=True, ensure_ascii=False, separators=(",", ":"))


def literal(value):
    data = canonical(value)
    tag = "$narat_profile$"
    if tag in data or "$activation$" in data:
        raise ValueError("Unexpected SQL dollar-quote delimiter in the profile")
    return f"{tag}{data}{tag}::jsonb"


def render():
    care = json.loads((RELEASES / "staging-monstera-care-v2/monstera-watering.json").read_text())
    prior = json.loads((RELEASES / "staging-diagnosis-v1/monstera-overwatering.json").read_text())
    if (care["kb_release_id"], care["plant_id"], prior["kb_release_id"], prior["condition_id"]) != (
        NEW_ID, "monstera_deliciosa", OLD_ID, "overwatering"
    ):
        raise ValueError("Unexpected staging release or profile identity")
    condition = {**prior, "kb_release_id": NEW_ID}
    manifest = hashlib.sha256(canonical({"plant": care, "condition": condition}).encode()).hexdigest()
    return f"""BEGIN;
SET LOCAL lock_timeout = '5s';
LOCK TABLE public.kb_releases IN SHARE ROW EXCLUSIVE MODE;
DO $activation$
DECLARE
    old_id constant uuid := '{OLD_ID}';
    new_id constant uuid := '{NEW_ID}';
    care constant jsonb := {literal(care)};
    prior_condition constant jsonb := {literal(prior)};
    next_condition constant jsonb := {literal(condition)};
    manifest constant text := '{manifest}';
    current_id uuid;
    monstera_taxon uuid;
BEGIN
    SELECT id INTO current_id FROM public.kb_releases WHERE state='published';
    SELECT t.id INTO STRICT monstera_taxon FROM public.catalogue_taxa t
    JOIN public.catalogue_releases r ON r.id=t.release_id
    WHERE r.state='published' AND t.status='published' AND t.plant_id='monstera_deliciosa';

    IF current_id = new_id THEN
        IF NOT EXISTS (SELECT 1 FROM public.kb_releases WHERE id=new_id AND manifest_sha256=manifest)
           OR (SELECT count(*) FROM public.care_profiles WHERE kb_release_id=new_id) <> 1
           OR (SELECT count(*) FROM public.condition_profiles WHERE kb_release_id=new_id) <> 1
           OR NOT EXISTS (SELECT 1 FROM public.care_profiles WHERE kb_release_id=new_id
               AND taxon_id=monstera_taxon AND state='published' AND profile=care)
           OR NOT EXISTS (SELECT 1 FROM public.condition_profiles WHERE kb_release_id=new_id
               AND condition_id='overwatering' AND state='published' AND protocol=next_condition) THEN
            RAISE EXCEPTION 'UNEXPECTED_STAGING_RELEASE_CONTENT';
        END IF;
        RETURN;
    END IF;

    IF current_id IS DISTINCT FROM old_id
       OR (SELECT count(*) FROM public.condition_profiles WHERE kb_release_id=old_id) <> 1
       OR NOT EXISTS (SELECT 1 FROM public.condition_profiles WHERE kb_release_id=old_id
           AND condition_id='overwatering' AND state='published' AND protocol=prior_condition)
       OR EXISTS (SELECT 1 FROM public.care_profiles WHERE kb_release_id=old_id)
       OR EXISTS (SELECT 1 FROM public.kb_vocabularies WHERE kb_release_id=old_id)
       OR EXISTS (SELECT 1 FROM public.kb_fallback_protocols WHERE kb_release_id=old_id)
       OR EXISTS (SELECT 1 FROM public.catalogue_releases WHERE kb_release_id=old_id AND state='published') THEN
        RAISE EXCEPTION 'UNEXPECTED_STAGING_SOURCE_RELEASE';
    END IF;

    INSERT INTO public.kb_releases (id,version,state,schema_version,manifest_sha256,seed_version,
        condition_manifest_version,disambiguation_policy,prompt_version,guardrail_version,validation_report)
    SELECT new_id,'staging-monstera-care-v2','validated',schema_version,manifest,seed_version,
        condition_manifest_version,disambiguation_policy,prompt_version,guardrail_version,
        jsonb_build_object('scope','staging_monstera_care','source_release_id',old_id)
    FROM public.kb_releases WHERE id=old_id;

    INSERT INTO public.condition_profiles (kb_release_id,condition_id,version,protocol,field_evidence,state)
    SELECT new_id,condition_id,version,next_condition,field_evidence,'published'
    FROM public.condition_profiles WHERE kb_release_id=old_id AND condition_id='overwatering';

    INSERT INTO public.care_profiles (kb_release_id,taxon_id,version,profile,field_evidence,validation_report,state)
    VALUES (new_id,monstera_taxon,care->>'record_version',care,care->'provenance'->'field_evidence',
        care->'provenance'->'validation','published');

    UPDATE public.kb_releases SET state='retired' WHERE id=old_id;
    UPDATE public.kb_releases SET state='published',published_at=clock_timestamp() WHERE id=new_id;
END;
$activation$;
COMMIT;
"""


if __name__ == "__main__":
    print(render(), end="")
