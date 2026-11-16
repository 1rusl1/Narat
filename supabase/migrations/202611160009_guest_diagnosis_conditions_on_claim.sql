BEGIN;

-- Extend only verified guest diagnosis publication inside the existing claim transaction.
DO $migration$
DECLARE
    definition text := pg_get_functiondef(
        'public.process_guest_photo_claim(uuid,uuid,uuid,text,boolean)'::regprocedure);
    declaration_boundary constant text := '    v_result JSONB;';
    validation_boundary constant text := '    v_ts := public.advance_owner_watermark(p_owner_id);';
    snapshot_boundary constant text := '    UPDATE public.photo_assets SET owner_id=p_owner_id,plant_id=v_plant,draft_id=NULL,';
    validation constant text := $new$    -- Guest diagnosis conditions must come from this exact consumed source.
    IF v_draft.intent='problem' OR EXISTS (
        SELECT 1 FROM public.analysis_jobs WHERE id=v_draft.analysis_job_id AND mode='diagnosis'
    ) THEN
        SELECT r.initial_context INTO v_initial_conditions
        FROM public.analysis_jobs j
        JOIN public.diagnosis_job_runtime r ON r.job_id=j.id
        JOIN public.guest_identification_sources g ON g.photo_id=v_photo.id
        WHERE j.id=v_draft.analysis_job_id AND j.owner_id=v_draft.guest_owner_id
          AND j.photo_ids=ARRAY[v_photo.id] AND j.draft_id=v_draft.id
          AND j.flow_id=v_draft.flow_id AND j.quota_installation_id=v_installation.id
          AND v_draft.intent='problem' AND v_draft.add_method='scan'
          AND v_draft.storage_cleaned_at IS NULL
          AND g.storage_cleaned_at IS NULL AND g.expires_at=v_draft.expires_at
          AND g.expires_at>clock_timestamp()
          AND public._bound_guest_diagnosis_taxon(j.id)=v_draft.confirmed_taxon_id
        FOR UPDATE OF j,r,g;
        IF NOT FOUND OR v_initial_conditions IS NULL THEN
            RAISE EXCEPTION 'DIAGNOSIS_SOURCE_NOT_FOUND' USING ERRCODE='P0002';
        END IF;
    END IF;
$new$;
    snapshot constant text := $new$    IF v_initial_conditions IS NOT NULL THEN
        INSERT INTO public.condition_snapshots (
            owner_id, plant_id, version, light_code, light_source, light_confirmed,
            watering_code, drainage_code, last_watered, created_at, updated_at
        ) VALUES (
            p_owner_id, v_plant, 1, v_initial_conditions->>'light',
            CASE WHEN v_initial_conditions->>'light'='unknown' THEN 'unknown' ELSE 'manual' END,
            v_initial_conditions->>'light'<>'unknown',
            v_initial_conditions->>'watering_frequency', v_initial_conditions->>'drainage',
            'unknown', v_ts, v_ts
        ) RETURNING id INTO v_initial_snapshot;
        UPDATE public.plants
        SET current_snapshot_id=v_initial_snapshot,
            current_condition_snapshot_id=v_initial_snapshot
        WHERE id=v_plant AND owner_id=p_owner_id;
        -- Clear only the validated source projection after attaching its answers.
        UPDATE public.diagnosis_job_runtime SET projection=NULL
        WHERE job_id=v_draft.analysis_job_id;
    END IF;
$new$;
BEGIN
    IF (length(definition)-length(replace(definition,declaration_boundary,'')))
            / length(declaration_boundary) <> 1
       OR (length(definition)-length(replace(definition,validation_boundary,'')))
            / length(validation_boundary) <> 1
       OR (length(definition)-length(replace(definition,snapshot_boundary,'')))
            / length(snapshot_boundary) <> 1
       OR position('Guest diagnosis conditions must come' IN definition) <> 0 THEN
        RAISE EXCEPTION 'Unexpected guest diagnosis claim boundary';
    END IF;
    definition := replace(definition,declaration_boundary,
        declaration_boundary || E'\n    v_initial_conditions JSONB;\n    v_initial_snapshot UUID;');
    definition := replace(definition,validation_boundary,validation || validation_boundary);
    EXECUTE replace(definition,snapshot_boundary,snapshot || snapshot_boundary);
END;
$migration$;

COMMIT;
