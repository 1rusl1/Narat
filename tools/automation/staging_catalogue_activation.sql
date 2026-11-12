BEGIN ISOLATION LEVEL REPEATABLE READ;
SET LOCAL lock_timeout='5s';
SET LOCAL statement_timeout='120s';
SELECT pg_advisory_xact_lock(hashtext('public.catalogue_releases_mutex'));

CREATE OR REPLACE FUNCTION pg_temp.t149_protected_state() RETURNS jsonb LANGUAGE sql STABLE AS $state$
  SELECT jsonb_build_object(
    'plants', (SELECT jsonb_agg(jsonb_build_object(
        'row', to_jsonb(p), 'advice', public.read_plant_care_profile(p.owner_id,p.id)) ORDER BY p.id)
      FROM public.plants p WHERE p.id IN (@PILOT_PLANTS@)),
    'journal', (SELECT jsonb_agg(jsonb_build_object('entry',to_jsonb(e),'reversal',to_jsonb(r)) ORDER BY e.id)
      FROM public.care_entries e LEFT JOIN public.care_reversals r ON r.entry_id=e.id
      WHERE e.plant_id IN (@PILOT_PLANTS@)),
    'pinned_diagnoses', (SELECT jsonb_agg(jsonb_build_object(
        'catalogue',r.catalogue_release_id,'kb',j.kb_release_id,'result',public.diagnosis_job_payload(j.id))
        ORDER BY j.id)
      FROM public.diagnosis_job_runtime r JOIN public.analysis_jobs j ON j.id=r.job_id
      WHERE r.catalogue_release_id='@PRIOR_RELEASE@' AND j.state IN ('succeeded','failed','timed_out')),
    'old_catalogue', (SELECT jsonb_agg(to_jsonb(s) ORDER BY s.plant_id)
      FROM public.catalogue_release_species s WHERE s.release_id='@PRIOR_RELEASE@'),
    'kb', (SELECT jsonb_agg(to_jsonb(k) ORDER BY k.id) FROM public.kb_releases k)
  );
$state$;

DO $t149$
DECLARE
  expected constant jsonb := @PROJECTIONS@;
  pilot_taxa constant jsonb := @PILOT_TAXA@;
  before_cutover jsonb;
  active_id uuid;
BEGIN
  SELECT id INTO STRICT active_id FROM public.catalogue_releases WHERE state='published';
  IF active_id NOT IN ('@PRIOR_RELEASE@','@RELEASE@')
     OR NOT EXISTS (SELECT 1 FROM public.catalogue_releases WHERE id='@RELEASE@' AND version='@VERSION@'
         AND source_hash='@SHA@' AND kb_release_id IS NULL AND state IN ('draft','validated','published','retired'))
     OR (SELECT count(*) FROM public.catalogue_release_species WHERE release_id='@PRIOR_RELEASE@') <> 3
     OR NOT EXISTS (SELECT 1 FROM public.kb_releases WHERE state='published' AND id='@CARE_KB@') THEN
    RAISE EXCEPTION 'unexpected_catalogue_or_kb_state';
  END IF;

  IF (SELECT count(*) FROM public.catalogue_release_species WHERE release_id='@RELEASE@') <> @COUNT@
     OR EXISTS (
       SELECT 1 FROM public.catalogue_release_species s
       WHERE s.release_id='@RELEASE@' AND (
         s.status <> 'published'
         OR expected->s.plant_id IS DISTINCT FROM jsonb_build_array(
           s.wikidata_id, s.hero_image->>'sha256', s.hero_image->>'storage_path',
           s.hero_image->>'author', s.hero_image->>'license', s.hero_image->>'license_url',
           s.hero_image->>'attribution', s.hero_image->>'source_page', s.hero_image->>'mime',
           s.hero_image->'bytes', s.scientific_name)
         OR s.hero_image->>'download_url' IS DISTINCT FROM
           ('@ORIGIN@/storage/v1/object/public/@BUCKET@/' || (s.hero_image->>'storage_path'))
       )) THEN
    RAISE EXCEPTION 'staged_catalogue_does_not_match_approved_release';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM storage.buckets WHERE id='@BUCKET@' AND public)
     OR (SELECT count(*) FROM storage.objects WHERE bucket_id='@BUCKET@' AND name LIKE '@VERSION@/%') <> @COUNT@
     OR EXISTS (
       SELECT 1 FROM public.catalogue_release_species s
       LEFT JOIN storage.objects o ON o.bucket_id='@BUCKET@' AND o.name=s.hero_image->>'storage_path'
       WHERE s.release_id='@RELEASE@' AND (o.id IS NULL
          OR o.metadata->>'size' IS DISTINCT FROM s.hero_image->>'bytes'
          OR o.metadata->>'mimetype' IS DISTINCT FROM s.hero_image->>'mime')
     ) THEN
    RAISE EXCEPTION 'catalogue_media_is_missing_or_invalid';
  END IF;

  IF EXISTS (
    SELECT 1 FROM jsonb_each_text(pilot_taxa) p
    LEFT JOIN public.catalogue_release_species old
      ON old.release_id='@PRIOR_RELEASE@' AND old.plant_id=p.key
    LEFT JOIN public.catalogue_release_species staged
      ON staged.release_id='@RELEASE@' AND staged.plant_id=p.key
    WHERE old.taxon_id::text IS DISTINCT FROM p.value OR staged.taxon_id::text IS DISTINCT FROM p.value
      OR old.wikidata_id IS DISTINCT FROM staged.wikidata_id
  ) OR (SELECT count(*) FROM public.plants p WHERE p.id IN (@PILOT_PLANTS@)
      AND p.deleted_at IS NULL AND p.taxon_id::text=pilot_taxa->>'monstera_deliciosa'
      AND public.read_plant_care_profile(p.owner_id,p.id)->>'kb_release_id'='@CARE_KB@') <> 2
    OR NOT EXISTS (SELECT 1 FROM public.care_entries WHERE plant_id IN (@PILOT_PLANTS@))
    OR NOT EXISTS (SELECT 1 FROM public.diagnosis_job_runtime r JOIN public.analysis_jobs j ON j.id=r.job_id
                   WHERE r.catalogue_release_id='@PRIOR_RELEASE@' AND j.state='succeeded' AND r.projection IS NOT NULL) THEN
    RAISE EXCEPTION 'protected_pilot_identity_or_history_unavailable';
  END IF;

  before_cutover := pg_temp.t149_protected_state();
  IF active_id <> '@RELEASE@' THEN
    PERFORM public.publish_catalogue_release('@RELEASE@');
  END IF;

  IF pg_temp.t149_protected_state() IS DISTINCT FROM before_cutover
    OR (SELECT count(*) FROM public.catalogue_taxa WHERE release_id='@RELEASE@' AND status='published') <> @COUNT@
    OR NOT EXISTS (SELECT 1 FROM public.catalogue_releases WHERE id='@PRIOR_RELEASE@' AND state='retired')
    OR public.get_catalogue_species_card('monstera_deliciosa','en')->>'taxon_id'
       IS DISTINCT FROM pilot_taxa->>'monstera_deliciosa'
    OR public.get_catalogue_species_card(pilot_taxa->>'monstera_deliciosa','en')->>'care_profile_available'
       IS DISTINCT FROM 'true'
    OR public.get_catalogue_species_card('begonia_maculata','pl')->'description'->>'language'
       IS DISTINCT FROM 'en' THEN
    RAISE EXCEPTION 'catalogue_cutover_changed_protected_state';
  END IF;
END;
$t149$;

SELECT r.id AS release_id, r.version, r.source_hash,
       (SELECT count(*) FROM public.catalogue_taxa t WHERE t.release_id=r.id AND t.status='published') AS species,
       (SELECT count(*) FROM storage.objects o WHERE o.bucket_id='@BUCKET@' AND o.name LIKE '@VERSION@/%') AS media
FROM public.catalogue_releases r WHERE r.id='@RELEASE@' AND r.state='published';
COMMIT;
