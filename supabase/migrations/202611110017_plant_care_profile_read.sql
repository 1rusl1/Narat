BEGIN;

CREATE FUNCTION public.read_plant_care_profile(p_owner_id UUID, p_plant_id UUID)
RETURNS JSONB LANGUAGE SQL STABLE SECURITY DEFINER SET search_path = '' AS $$
    SELECT jsonb_build_object('plant_id', p.id, 'plant_slug', t.plant_id,
        'kb_release_id', k.id, 'profile', c.profile)
    FROM public.plants p
    JOIN public.profiles o ON o.id = p.owner_id AND o.account_state = 'active' AND NOT o.anonymous
    LEFT JOIN public.catalogue_taxa t ON t.id = p.taxon_id AND t.status = 'published'
    LEFT JOIN public.catalogue_releases r ON r.id = t.release_id AND r.state = 'published'
    LEFT JOIN public.kb_releases k ON k.state = 'published'
    LEFT JOIN public.care_profiles c ON c.taxon_id = t.id AND c.kb_release_id = k.id
        AND c.state = 'published' AND r.id IS NOT NULL
    WHERE p.id = p_plant_id AND p.owner_id = p_owner_id AND p.deleted_at IS NULL
$$;

REVOKE ALL ON FUNCTION public.read_plant_care_profile(UUID, UUID) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.read_plant_care_profile(UUID, UUID) TO service_role;

COMMIT;
