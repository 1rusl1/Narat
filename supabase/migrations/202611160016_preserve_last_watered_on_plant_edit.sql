BEGIN;

-- Preserve the complete installed function and its ACL at both migration cutoffs.
-- Do not change the legacy bidirectional drainage/last_watered alias trigger.
-- Explicit drainage='unknown' with an older non-unknown last_watered remains
-- ambiguous for legacy writers: 004 restores drainage from that historical value.
DO $migration$
DECLARE
    definition text := pg_get_functiondef(
        'public.execute_plant_edit_command(uuid,uuid,uuid,jsonb)'::regprocedure);
    old_insert constant text := $old$            INSERT INTO public.condition_snapshots(
                owner_id,plant_id,version,light_code,light_source,light_confirmed,watering_code,
                drainage_code,pot_type,season_override,created_at,updated_at)
            VALUES (p_owner_id,p_plant_id,v_version,v_light,v_light_source,v_light_confirmed,
                v_watering,v_drainage,v_pot,coalesce(v_snapshot.season_override,'auto'),v_watermark,v_watermark)
            RETURNING id INTO v_snapshot_id;$old$;
    new_insert constant text := $new$            INSERT INTO public.condition_snapshots(
                owner_id,plant_id,version,light_code,light_source,light_confirmed,watering_code,
                drainage_code,last_watered,pot_type,season_override,created_at,updated_at)
            VALUES (p_owner_id,p_plant_id,v_version,v_light,v_light_source,v_light_confirmed,
                v_watering,v_drainage,coalesce(v_snapshot.last_watered,'unknown'),v_pot,
                coalesce(v_snapshot.season_override,'auto'),v_watermark,v_watermark)
            RETURNING id INTO v_snapshot_id;$new$;
BEGIN
    IF (length(definition)-length(replace(definition,old_insert,'')))
            / length(old_insert) <> 1 THEN
        RAISE EXCEPTION 'Unexpected plant edit snapshot insert boundary';
    END IF;
    EXECUTE replace(definition,old_insert,new_insert);
END;
$migration$;

COMMIT;
