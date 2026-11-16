BEGIN;

-- Preserve the complete installed function and its ACL at both migration cutoffs.
-- Canonical edits supply drainage and watering context independently.
-- Legacy callers retain bidirectional aliasing outside this function's scope.
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

-- Patch only the verified alias boundary; retain other aliases and the trigger ACL.
DO $migration$
DECLARE
    definition text := pg_get_functiondef(
        'public.sync_condition_snapshot_columns()'::regprocedure);
    alias_boundary constant text := $old$    IF NEW.last_watered IS NOT NULL AND NEW.drainage_code = 'unknown' THEN
        NEW.drainage_code := NEW.last_watered;
    ELSIF NEW.last_watered IS NULL THEN
        NEW.last_watered := NEW.drainage_code;
    END IF;$old$;
    independent_guard constant text := $new$    IF current_setting('narat.independent_snapshot_watered',true) = 'on' THEN
        RETURN NEW;
    END IF;
    -- Unrelated updates must not reinterpret an existing independent pair.
    IF TG_OP = 'UPDATE' THEN
        IF ROW(NEW.drainage_code,NEW.last_watered)
            IS NOT DISTINCT FROM ROW(OLD.drainage_code,OLD.last_watered) THEN
            RETURN NEW;
        END IF;
    END IF;
$new$;
BEGIN
    IF (length(definition)-length(replace(definition,alias_boundary,'')))
            / length(alias_boundary) <> 1 THEN
        RAISE EXCEPTION 'Unexpected condition snapshot alias boundary';
    END IF;
    EXECUTE replace(definition,alias_boundary,independent_guard || alias_boundary);
END;
$migration$;

-- This adds only one setting; search_path, SECURITY DEFINER and ACL are retained.
-- PostgreSQL restores the caller's setting on return, including exceptions.
ALTER FUNCTION public.execute_plant_edit_command(uuid,uuid,uuid,jsonb)
    SET narat.independent_snapshot_watered = 'on';

COMMIT;
