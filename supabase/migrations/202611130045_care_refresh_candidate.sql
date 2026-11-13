BEGIN;

-- Call inside the refresh writer's transaction so its decision retains the locks.
CREATE FUNCTION public.resolve_basic_care_refresh_candidate(
    p_owner_id UUID, p_plant_id UUID, p_expected_care_revision INT
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
    v_evidence JSONB;
    v_has_entitlement BOOLEAN;
    v_enabled BOOLEAN;
    v_now TIMESTAMPTZ;
    v_anchor DATE;
BEGIN
    v_evidence := public.resolve_basic_care_refresh_evidence(p_owner_id,p_plant_id,p_expected_care_revision);
    IF v_evidence IS NULL THEN
        RETURN jsonb_build_object('state','paused','reason','insufficient_evidence');
    END IF;

    PERFORM 1 FROM public.entitlements WHERE owner_id=p_owner_id FOR SHARE;
    v_has_entitlement := FOUND;
    SELECT enabled INTO v_enabled FROM public.basic_care_memberships
    WHERE owner_id=p_owner_id AND plant_id=p_plant_id AND deleted_at IS NULL FOR SHARE;
    v_now := clock_timestamp();
    IF v_enabled IS DISTINCT FROM TRUE OR
       (v_has_entitlement AND NOT public.has_verified_paid_access(p_owner_id,v_now)) THEN
        RETURN jsonb_build_object('state','paused','reason','automatic_care_unavailable');
    END IF;

    SELECT occurred_local_date INTO v_anchor
    FROM public.care_entries
    WHERE owner_id=p_owner_id AND plant_id=p_plant_id AND action_code='water'
      AND state='active' AND deleted_at IS NULL AND occurred_at<=v_now
    ORDER BY occurred_at DESC,recorded_at DESC,id DESC LIMIT 1 FOR SHARE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('state','paused','reason','missing_watering_anchor');
    END IF;
    RETURN v_evidence || jsonb_build_object('state','eligible','anchor_on',v_anchor);
END;
$$;

REVOKE ALL ON FUNCTION public.resolve_basic_care_refresh_candidate(UUID,UUID,INT)
    FROM PUBLIC,anon,authenticated,service_role;

COMMIT;
