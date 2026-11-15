BEGIN;

-- Transform the installed projection, including deployments that never applied 024.
-- CREATE OR REPLACE preserves the view's columns, options, owner and grants.
DO $migration$
DECLARE
    definition text := pg_get_viewdef('public.owner_sync_entries'::regclass, false);
    field_pattern constant text := $pattern$'season_override'(::text)?,[[:space:]]+cs[.]season_override,[[:space:]]+$pattern$;
BEGIN
    IF (SELECT count(*) FROM regexp_matches(definition, field_pattern, 'g')) <> 1 THEN
        RAISE EXCEPTION 'Unexpected owner sync season projection';
    END IF;
    definition := regexp_replace(definition, field_pattern, '');
    IF position('season_override' IN definition) <> 0 THEN
        RAISE EXCEPTION 'Unexpected remaining owner sync season reference';
    END IF;
    EXECUTE 'CREATE OR REPLACE VIEW public.owner_sync_entries AS ' || definition;
END;
$migration$;

COMMENT ON VIEW public.owner_sync_entries IS 'owner-sync:season-override-retired:057';

COMMIT;
