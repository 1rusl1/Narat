BEGIN;

-- Preserve 001 admission, exact/historical receipts, and every other create route.
DO $migration$
DECLARE
    definition text := pg_get_functiondef(
        'public.execute_plant_create_command(uuid,uuid,jsonb,timestamptz)'::regprocedure);
    snapshot_boundary constant text := $old$  -- In basic catalogue save without care questions, condition_snapshots is optional (NULL)
$old$;
    initial_snapshot constant text := $new$  -- Initial diagnosis answers belong to this same plant.create transaction.
  -- The 001 source guard above has already locked and validated the owner/job/photo.
  -- Old compatible jobs without context deliberately retain their previous behavior.
  IF p_payload ? 'diagnosis_job_id' THEN
    SELECT r.initial_context INTO v_conditions
    FROM public.diagnosis_job_runtime r
    WHERE r.job_id = (p_payload->>'diagnosis_job_id')::uuid;

    IF v_conditions IS NOT NULL THEN
      INSERT INTO public.condition_snapshots (
        owner_id, plant_id, version, light_code, light_source, light_confirmed,
        watering_code, drainage_code, last_watered, created_at, updated_at
      ) VALUES (
        p_owner_id, v_new_plant_uuid, 1, v_conditions->>'light',
        CASE WHEN v_conditions->>'light' = 'unknown' THEN 'unknown' ELSE 'manual' END,
        v_conditions->>'light' <> 'unknown',
        v_conditions->>'watering_frequency', v_conditions->>'drainage',
        -- Do not let the legacy alias trigger turn drainage into a watering date.
        'unknown', v_ts, v_ts
      )
      RETURNING id INTO v_current_snap_id;

      UPDATE public.plants
      SET current_snapshot_id = v_current_snap_id,
          current_condition_snapshot_id = v_current_snap_id
      WHERE id = v_new_plant_uuid AND owner_id = p_owner_id;
    END IF;
  END IF;

$new$;
BEGIN
    IF (length(definition) - length(replace(definition, snapshot_boundary, '')))
        / length(snapshot_boundary) <> 1
        OR position('invalid_diagnosis_save' IN definition) = 0
        OR position('Initial diagnosis answers belong' IN definition) <> 0 THEN
        RAISE EXCEPTION 'Unexpected initial diagnosis snapshot boundary';
    END IF;
    EXECUTE replace(definition, snapshot_boundary, initial_snapshot || snapshot_boundary);
END;
$migration$;

COMMIT;
