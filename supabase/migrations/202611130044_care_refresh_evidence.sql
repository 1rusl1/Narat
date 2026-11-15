BEGIN;

-- The eventual refresh writer must call this in its own transaction.
CREATE FUNCTION public.resolve_basic_care_refresh_evidence(
    p_owner_id UUID, p_plant_id UUID, p_expected_care_revision INT
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
    v_plant public.plants%ROWTYPE;
    v_snapshot public.condition_snapshots%ROWTYPE;
    v_profile public.care_profiles%ROWTYPE;
    v_context JSONB;
    v_rule JSONB;
BEGIN
    PERFORM 1 FROM public.profiles
    WHERE id=p_owner_id AND account_state='active' AND NOT anonymous FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'ACTIVE_PERMANENT_OWNER_REQUIRED' USING ERRCODE='42501';
    END IF;
    SELECT * INTO v_plant FROM public.plants
    WHERE id=p_plant_id AND owner_id=p_owner_id AND deleted_at IS NULL FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PLANT_NOT_FOUND' USING ERRCODE='P0002';
    END IF;
    IF v_plant.care_revision IS DISTINCT FROM p_expected_care_revision THEN
        RAISE EXCEPTION 'CARE_REVISION_CHANGED' USING ERRCODE='23505';
    END IF;
    SELECT * INTO v_snapshot FROM public.condition_snapshots
    WHERE id=v_plant.current_condition_snapshot_id AND owner_id=p_owner_id
      AND plant_id=p_plant_id AND deleted_at IS NULL FOR SHARE;
    IF NOT FOUND THEN RETURN NULL; END IF;

    SELECT c.* INTO v_profile
    FROM public.care_profiles c
    JOIN public.kb_releases k ON k.id=c.kb_release_id AND k.state='published'
    JOIN public.catalogue_taxa t ON t.id=c.taxon_id AND t.status='published'
    JOIN public.catalogue_releases r ON r.id=t.release_id AND r.state='published'
    WHERE c.taxon_id=v_plant.taxon_id AND c.state='published' AND t.plant_id=v_plant.plant_id
      AND c.profile->>'kb_release_id'=k.id::text AND c.profile->>'plant_id'=t.plant_id
    FOR SHARE OF c,k,t,r;
    IF NOT FOUND THEN RETURN NULL; END IF;

    v_context := jsonb_build_object('light_code',v_snapshot.light_code,'light_source',v_snapshot.light_source,
        'light_confirmed',v_snapshot.light_confirmed,'watering_code',v_snapshot.watering_code,
        'drainage_code',v_snapshot.drainage_code,'pot_type',v_snapshot.pot_type);
    SELECT jsonb_build_object('snapshot_id',v_snapshot.id,'care_revision',v_plant.care_revision,
        'profile_id',v_profile.id,'action_id',a.value->>'action_id',
        'interval_days',a.value->'next_check_interval_days','action_source',proof.action_source,
        'interval_source',proof.interval_source,'applicability_source',proof.applicability_source)
    INTO v_rule
    FROM jsonb_array_elements(CASE WHEN jsonb_typeof(v_profile.profile->'actions')='array'
        THEN v_profile.profile->'actions' ELSE '[]'::jsonb END)
        WITH ORDINALITY a(value,position)
    CROSS JOIN LATERAL (
        SELECT public.first_aid_approved_source(v_profile.profile->'provenance',
            '/actions/'||(a.position-1)) AS action_source,
            public.first_aid_approved_source(v_profile.profile->'provenance',
            '/actions/'||(a.position-1)||'/next_check_interval_days') AS interval_source,
            public.first_aid_approved_source(v_profile.profile->'provenance',
            '/actions/'||(a.position-1)||'/refresh_conditions') AS applicability_source
    ) proof
    WHERE a.value->>'action_code'='check_soil' AND a.value->>'purpose'='routine_care'
      AND a.value->>'action_id' ~ '^[a-z][a-z0-9_]*$'
      AND a.value->'prerequisite_check_ids'='[]'::jsonb
      AND a.value->'contraindication_check_ids'='[]'::jsonb
      AND coalesce(a.value->'active_ingredients','[]'::jsonb)='[]'::jsonb
      AND jsonb_typeof(a.value->'next_check_interval_days')='number'
      AND a.value->>'next_check_interval_days' ~ '^([1-9]|[1-8][0-9]|90)$'
      AND v_profile.validation_report->'refresh_conditions'->(a.value->>'action_id')=v_context
      AND proof.action_source IS NOT NULL AND proof.interval_source IS NOT NULL
      AND proof.applicability_source IS NOT NULL
    ORDER BY a.position LIMIT 1;
    RETURN v_rule;
END;
$$;

REVOKE ALL ON FUNCTION public.resolve_basic_care_refresh_evidence(UUID,UUID,INT)
    FROM PUBLIC,anon,authenticated,service_role;

COMMIT;
