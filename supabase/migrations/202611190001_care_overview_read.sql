BEGIN;

-- Private service envelope. Every SPI read shares the calling statement's MVCC
-- snapshot (STABLE); statement_timestamp is also the accepted resolvers' clock.
CREATE FUNCTION public.read_owner_care_overview(
    p_owner_id UUID, p_after UUID DEFAULT NULL, p_limit INTEGER DEFAULT 100
) RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' SET timezone = 'UTC' AS $overview$
DECLARE
    v_now CONSTANT TIMESTAMPTZ := statement_timestamp();
    v_owner public.profiles%ROWTYPE;
    v_until TIMESTAMPTZ;
    v_has_entitlement BOOLEAN;
    v_automation BOOLEAN;
    v_publication TEXT;
    v_plants JSONB := '[]'::jsonb;
    v_controls JSONB;
    v_plant RECORD;
    v_control RECORD;
    v_action RECORD;
    v_count INTEGER := 0;
    v_last UUID;
    v_next UUID;
BEGIN
    IF p_limit IS NULL OR p_limit < 1 OR p_limit > 200 THEN
        RAISE EXCEPTION 'INVALID_CARE_OVERVIEW_LIMIT' USING ERRCODE = '22023';
    END IF;
    SELECT * INTO v_owner FROM public.profiles
    WHERE id = p_owner_id AND account_state = 'active' AND NOT anonymous;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'ACTIVE_PERMANENT_OWNER_REQUIRED' USING ERRCODE = '42501';
    END IF;

    -- A retained, invalid entitlement is never Free. Match the verified wire
    -- deadline, including the trial minimum; grace_until cannot extend it.
    SELECT CASE WHEN e.state IN ('active','grace')
            AND isfinite(e.valid_until)
            AND (e.grace_until IS NULL OR isfinite(e.grace_until))
            AND (e.trial_end_at IS NULL OR isfinite(e.trial_end_at))
        THEN CASE WHEN e.offer_kind = 'paid' THEN e.valid_until
            WHEN e.offer_kind = 'trial' AND e.trial_end_at IS NOT NULL
                THEN least(e.valid_until,e.trial_end_at) END END
    INTO v_until FROM public.entitlements e WHERE e.owner_id = p_owner_id;
    v_has_entitlement := FOUND;
    v_automation := NOT v_has_entitlement OR
        (public.has_verified_paid_access(p_owner_id,v_now)
            AND coalesce(v_until > v_now,false));

    -- Conservative global publication generation, independent of page/owner.
    -- Hash actual contents, not just release IDs or editorial timestamps: the
    -- accepted authorities consult embedded provenance and validation reports.
    -- Including unpublished rows also detects withdrawal, removal and restoration.
    -- Only the digest leaves this query; no KB/source body is in this metadata.
    SELECT encode(sha256(convert_to('care-overview:1:' ||
        coalesce(string_agg(kind || ':' ||
            encode(sha256(convert_to(body::text,'UTF8')),'hex'),
            ',' ORDER BY kind,body->>'id'),''),'UTF8')),'hex')
    INTO v_publication
    FROM (
        SELECT 'catalogue_releases' AS kind,to_jsonb(r) AS body FROM public.catalogue_releases r
        UNION ALL SELECT 'catalogue_taxa',to_jsonb(t) FROM public.catalogue_taxa t
        UNION ALL SELECT 'kb_releases',to_jsonb(k) FROM public.kb_releases k
        UNION ALL SELECT 'care_profiles',to_jsonb(c) FROM public.care_profiles c
        UNION ALL SELECT 'condition_profiles',to_jsonb(c) FROM public.condition_profiles c
        UNION ALL SELECT 'source_registry',to_jsonb(s) FROM public.source_registry s
        UNION ALL SELECT 'source_documents',to_jsonb(s) FROM public.source_documents s
        UNION ALL SELECT 'evidence_sources',to_jsonb(e) FROM public.evidence_sources e
    ) publication;

    FOR v_plant IN
        SELECT p.* FROM public.plants p
        WHERE p.owner_id = p_owner_id AND p.deleted_at IS NULL
            AND (p_after IS NULL OR p.id > p_after)
        ORDER BY p.id LIMIT p_limit + 1
    LOOP
        IF v_count = p_limit THEN
            v_next := v_last;
            EXIT;
        END IF;
        v_controls := '[]'::jsonb;
        IF v_automation THEN
            -- Separate candidate selection from the 029 call: malformed legacy
            -- projection UUIDs must never reach that helper's UUID cast.
            FOR v_control IN
                SELECT f.*,e.first_aid_job_id AS job_id,e.occurred_local_date
                FROM public.first_aid_followups f
                JOIN public.care_entries e ON e.id = f.action_entry_id
                    AND e.owner_id = f.owner_id AND e.plant_id = f.plant_id
                    AND e.action_code = 'check_soil' AND e.task_id IS NULL
                    AND e.state = 'active' AND e.deleted_at IS NULL
                JOIN public.analysis_jobs j ON j.id = e.first_aid_job_id
                    AND j.owner_id = e.owner_id AND j.plant_id = e.plant_id
                    AND j.mode = 'diagnosis' AND j.state = 'succeeded'
                    AND j.kb_release_id = f.kb_release_id
                    AND j.snapshot_id IS NOT DISTINCT FROM v_plant.current_condition_snapshot_id
                JOIN public.diagnosis_job_runtime r ON r.job_id = j.id
                WHERE f.owner_id = p_owner_id AND f.plant_id = v_plant.id
                    AND f.state = 'active' AND f.deleted_at IS NULL
                    AND f.action_code = 'check_soil' AND f.control_task_id IS NULL
                    AND f.context_revision = v_plant.care_revision
                    AND isfinite(e.occurred_at) AND e.occurred_at <= v_now
                    AND isfinite(e.occurred_local_date)
                    AND e.occurred_local_date <= (v_now AT TIME ZONE 'UTC')::date + 1
                    AND r.projection->>'analysis_id' ~
                        '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
                    AND (v_plant.current_condition_snapshot_id IS NULL OR EXISTS (
                        SELECT 1 FROM public.condition_snapshots s
                        WHERE s.id = v_plant.current_condition_snapshot_id
                            AND s.owner_id = p_owner_id AND s.plant_id = v_plant.id
                            AND s.deleted_at IS NULL))
                    AND NOT EXISTS (
                        SELECT 1 FROM public.care_observations o
                        WHERE o.first_aid_control_id = f.id AND o.deleted_at IS NULL)
                ORDER BY f.id
            LOOP
                SELECT a.* INTO v_action
                FROM public.read_first_aid_action(p_owner_id,v_plant.id,v_control.job_id) a
                WHERE a.analysis_id = v_control.origin_analysis_id
                    AND a.kb_release_id = v_control.kb_release_id
                    AND a.protocol_id = v_control.protocol_id
                    AND a.context_revision = v_control.context_revision
                    AND a.action = v_control.first_action_snapshot
                    AND a.interval_days BETWEEN 1 AND 90
                    AND a.interval_source IS NOT NULL
                    -- Compare JSON to a date computed only from typed, finite
                    -- facts and the current authority; never cast policy JSON.
                    AND v_control.check_policy_snapshot = jsonb_build_object(
                        'due_on',v_control.occurred_local_date + a.interval_days,
                        'interval_days',a.interval_days,'source',a.interval_source);
                IF FOUND THEN
                    v_controls := v_controls || jsonb_build_array(jsonb_build_object(
                        'control_id',v_control.id,'action_entry_id',v_control.action_entry_id,
                        'job_id',v_control.job_id,'origin_analysis_id',v_action.analysis_id,
                        'kb_release_id',v_action.kb_release_id,'protocol_id',v_action.protocol_id,
                        'context_revision',v_action.context_revision,
                        'action_id',v_action.action->>'action_id','action_code','check_soil',
                        'policy',v_control.check_policy_snapshot));
                END IF;
            END LOOP;
        END IF;
        v_plants := v_plants || jsonb_build_array(jsonb_build_object(
            'plant_id',v_plant.id,'care_revision',v_plant.care_revision,
            -- RPC-only raw response. A future HTTP adapter MUST use the existing
            -- pure card validator/serializer before returning a recommendation.
            'care_profile',public.read_plant_care_profile(p_owner_id,v_plant.id),
            'first_aid_controls',v_controls));
        v_count := v_count + 1;
        v_last := v_plant.id;
    END LOOP;

    RETURN jsonb_build_object('owner_id',p_owner_id,'server_now',v_now,
        'owner_watermark',v_owner.updated_at,'publication_fingerprint',v_publication,
        'reminder_hour_local',v_owner.reminder_hour_local,
        'automation_allowed',v_automation,'verified_access_until',v_until,
        'plants',v_plants,'next_after',v_next);
END
$overview$;

REVOKE ALL ON FUNCTION public.read_owner_care_overview(UUID,UUID,INTEGER)
    FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.read_owner_care_overview(UUID,UUID,INTEGER) TO service_role;
COMMENT ON FUNCTION public.read_owner_care_overview(UUID,UUID,INTEGER)
IS 'Private read-only owner care generation; raw care_profile requires HTTP card serialization.';

COMMIT;
