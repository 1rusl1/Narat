BEGIN;

-- Extend the installed writer so exact and historical receipts keep their original meaning.
DO $migration$
DECLARE
    definition text := pg_get_functiondef(
        'public.execute_plant_create_command(uuid,uuid,jsonb,timestamptz)'::regprocedure);
    source_boundary constant text := $old$  IF p_payload ? 'identification_job_id' THEN
$old$;
    source_guard constant text := $new$  IF p_payload ? 'diagnosis_job_id' THEN
    IF v_creation_source <> 'catalogue' OR v_add_method <> 'scan' OR v_intent <> 'problem'
      OR jsonb_typeof(p_payload->'diagnosis_job_id') IS DISTINCT FROM 'string'
      OR jsonb_typeof(p_payload->'plant_id') IS DISTINCT FROM 'string'
      OR btrim(p_payload->>'plant_id') = ''
      OR p_payload - ARRAY['creation_source','add_method','creation_intent','diagnosis_job_id',
                           'plant_id','personal_name'] <> '{}'::jsonb
      OR (p_payload ? 'personal_name' AND jsonb_typeof(p_payload->'personal_name') <> 'string') THEN
      RAISE EXCEPTION 'invalid_diagnosis_save' USING ERRCODE = '22023';
    END IF;
    IF EXISTS (SELECT 1 FROM public.profiles WHERE id = p_owner_id AND anonymous) THEN
      RAISE EXCEPTION 'owner_forbidden' USING ERRCODE = '42501';
    END IF;

    SELECT a.id, a.plant_id INTO v_photo_id, v_photo_plant_id
    FROM public.analysis_jobs j
    JOIN public.diagnosis_job_runtime r ON r.job_id = j.id
    JOIN public.photo_assets a ON a.id = j.photo_ids[1]
    JOIN public.diagnosis_upload_tickets t ON t.photo_asset_id = a.id
    WHERE j.id = (p_payload->>'diagnosis_job_id')::uuid AND j.owner_id = p_owner_id
      AND j.mode = 'diagnosis' AND j.state = 'succeeded' AND j.plant_id IS NULL
      AND cardinality(j.photo_ids) = 1 AND r.projection->>'identification_status' = 'identified'
      AND r.projection->>'plant_id' = p_payload->>'plant_id'
      AND a.owner_id = p_owner_id AND a.draft_id IS NULL AND a.deleted_at IS NULL
      AND a.state = 'ready' AND a.uploaded_at IS NOT NULL
      AND a.original_key = p_owner_id::text || '/' || a.id::text
      AND EXISTS (SELECT 1 FROM storage.objects o
          JOIN storage.buckets b ON b.id = o.bucket_id AND NOT b.public
          WHERE o.bucket_id = 'analysis-inputs' AND o.name = a.original_key)
    FOR UPDATE OF j, a;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'diagnosis_source_not_found' USING ERRCODE = 'P0002';
    END IF;
    IF v_photo_plant_id IS NOT NULL THEN
      RAISE EXCEPTION 'diagnosis_photo_already_attached' USING ERRCODE = '23505';
    END IF;
  ELSIF p_payload ? 'identification_job_id' THEN
$new$;
    receipt_boundary constant text := $old$  IF v_identification_job_id IS NOT NULL THEN
    v_response := v_response || jsonb_build_object('photo_id', v_photo_id);
$old$;
    receipt_with_photo constant text := $new$  IF v_identification_job_id IS NOT NULL OR p_payload ? 'diagnosis_job_id' THEN
    v_response := v_response || jsonb_build_object('photo_id', v_photo_id);
$new$;
BEGIN
    IF (length(definition) - length(replace(definition, source_boundary, '')))
        / length(source_boundary) <> 1
        OR (length(definition) - length(replace(definition, receipt_boundary, '')))
        / length(receipt_boundary) <> 1
        OR position('invalid_diagnosis_save' IN definition) <> 0 THEN
        RAISE EXCEPTION 'Unexpected plant create photo binding boundaries';
    END IF;
    EXECUTE replace(replace(definition, source_boundary, source_guard),
                    receipt_boundary, receipt_with_photo);
END;
$migration$;

COMMIT;
