BEGIN;

-- Preserve the installed writer, its signature, privileges and legacy history.
-- Fail closed if the receipt/mismatch boundary no longer matches exactly once.
DO $migration$
DECLARE
    definition text := pg_get_functiondef(
        'public.execute_plant_create_command(uuid,uuid,jsonb,timestamptz)'::regprocedure);
    receipt_boundary constant text := $old$  IF EXISTS (
    SELECT 1 FROM public.operation_receipts r
    WHERE r.owner_id = p_owner_id AND r.operation_id = p_operation_id
  ) THEN
    RAISE EXCEPTION 'operation_payload_mismatch' USING ERRCODE = '23505';
  END IF;
$old$;
    input_guard constant text := $new$
  -- Only newly supplied context is retired; exact historical receipts replay above.
  IF p_payload->'conditions'->>'light_source' = 'camera_estimate'
    OR p_payload->'overrides'->>'light_source' = 'camera_estimate' THEN
    RAISE EXCEPTION 'CAMERA_LIGHT_SOURCE_RETIRED' USING ERRCODE = '22023';
  END IF;

  IF COALESCE(p_payload, '{}'::jsonb) ? 'season_override'
    OR COALESCE(p_payload->'conditions', '{}'::jsonb) ? 'season_override'
    OR COALESCE(p_payload->'overrides', '{}'::jsonb) ? 'season_override' THEN
    RAISE EXCEPTION 'SEASON_OVERRIDE_RETIRED' USING ERRCODE = '22023';
  END IF;
$new$;
BEGIN
    IF (length(definition) - length(replace(definition, receipt_boundary, '')))
        / length(receipt_boundary) <> 1
        OR position('CAMERA_LIGHT_SOURCE_RETIRED' IN definition) <> 0 THEN
        RAISE EXCEPTION 'Unexpected plant create receipt boundary';
    END IF;
    EXECUTE replace(definition, receipt_boundary, receipt_boundary || input_guard);
END;
$migration$;

COMMIT;
