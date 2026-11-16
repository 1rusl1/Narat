BEGIN;

-- Preserve the complete installed function and its ACL at both migration cutoffs.
-- Canonical edits supply drainage and watering context independently.
-- Legacy callers retain bidirectional aliasing for all existing drainage values.
-- Hosted migration roles need only their existing function ownership: no custom
-- GUC, parameter privilege, role change or new grant is required.
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
                v_watering,CASE WHEN v_drainage='unknown' THEN '__narat_plant_edit_unknown__'
                    ELSE v_drainage END,coalesce(v_snapshot.last_watered,'unknown'),v_pot,
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
    independent_guard constant text := $new$    -- Insert-only transport value, never a persisted drainage enum member.
    -- The existing CHECK rejects it on UPDATE or if this rewrite is absent.
    IF TG_OP = 'INSERT' AND NEW.drainage_code = '__narat_plant_edit_unknown__' THEN
        NEW.drainage_code := 'unknown';
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

COMMIT;
