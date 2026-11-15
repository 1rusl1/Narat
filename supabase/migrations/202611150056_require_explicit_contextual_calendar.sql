BEGIN;

-- Contextual profiles must never fall back to the revision-one watering calendar.
-- Keep 050 as the access gate and 052 as the single verified routine resolver.
CREATE OR REPLACE FUNCTION public.read_plant_care_profile(p_owner_id UUID, p_plant_id UUID)
RETURNS JSONB LANGUAGE SQL STABLE SECURITY DEFINER SET search_path = '' AS $$
    WITH profile AS (
        SELECT public.read_plant_care_profile_050(p_owner_id,p_plant_id) AS body
    ), routine AS (
        SELECT public.resolve_routine_soil_check(p_owner_id,p_plant_id) AS body
    ), contextual AS (
        SELECT EXISTS (
            SELECT 1
            FROM public.plants p
            JOIN public.catalogue_taxa t ON t.id=p.taxon_id AND t.status='published'
            JOIN public.kb_releases kb ON kb.state='published'
            JOIN public.care_profiles c ON c.taxon_id=t.id AND c.kb_release_id=kb.id
                AND c.state='published'
            WHERE p.id=p_plant_id AND p.owner_id=p_owner_id AND p.deleted_at IS NULL
                AND p.id::text=profile.body->>'plant_id'
                AND t.plant_id=profile.body->>'plant_slug'
                AND kb.id::text=profile.body->>'kb_release_id'
                AND c.profile=profile.body->'profile'
                AND c.validation_report ? 'refresh_conditions'
        ) AS required
        FROM profile
    )
    SELECT profile.body
        || CASE WHEN contextual.required AND routine.body IS NULL
            THEN jsonb_build_object('calendar_eligible',false) ELSE '{}'::jsonb END
        || CASE WHEN profile.body->'calendar_eligible'='true'::jsonb AND routine.body IS NOT NULL
            THEN jsonb_build_object('routine_check',routine.body) ELSE '{}'::jsonb END
    FROM profile CROSS JOIN routine CROSS JOIN contextual
$$;
REVOKE ALL ON FUNCTION public.read_plant_care_profile(UUID,UUID) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.read_plant_care_profile(UUID,UUID) TO service_role;
COMMENT ON FUNCTION public.read_plant_care_profile(UUID,UUID)
IS 'explicit-contextual-calendar:056';

COMMIT;
