BEGIN;

CREATE FUNCTION public.write_basic_care_refresh_rule(
    p_owner_id UUID, p_operation_id UUID, p_plant_id UUID, p_candidate JSONB, p_watermark TIMESTAMPTZ
) RETURNS TIMESTAMPTZ LANGUAGE plpgsql SET search_path = '' AS $$
DECLARE
    v_watermark TIMESTAMPTZ := p_watermark;
    v_revision INT := (p_candidate->>'care_revision')::int;
    v_snapshot_id UUID := (p_candidate->>'snapshot_id')::uuid;
    v_profile_id UUID := (p_candidate->>'profile_id')::uuid;
    v_interval INT := (p_candidate->>'interval_days')::int;
    v_evidence JSONB := p_candidate - ARRAY['state','anchor_on'];
    v_rule_id UUID;
    v_plan_id UUID;
BEGIN
    -- The caller holds the owner and evidence locks from candidate resolution.
    SELECT r.id INTO v_rule_id
    FROM public.task_rules r
    JOIN public.care_plans cp ON cp.id=r.plan_id
      AND cp.owner_id=r.owner_id AND cp.plant_id=r.plant_id
    WHERE r.owner_id=p_owner_id AND r.plant_id=p_plant_id
      AND r.access_class='basic_care' AND r.action_code='check_soil'
      AND r.rule_state='active' AND r.deleted_at IS NULL
      AND r.condition_code='check_soil_first' AND r.interval_days=v_interval
      AND cp.plan_kind='routine' AND cp.access_tier='basic'
      AND cp.state='active' AND cp.deleted_at IS NULL
      AND cp.snapshot_id=v_snapshot_id AND cp.context_revision=v_revision
      AND cp.care_profile_id=v_profile_id AND cp.full_body=jsonb_build_object('refresh_evidence',v_evidence)
    ORDER BY r.id LIMIT 1;

    IF v_rule_id IS NULL OR EXISTS (
        SELECT 1 FROM public.task_rules r
        WHERE r.owner_id=p_owner_id AND r.plant_id=p_plant_id
          AND r.access_class='basic_care' AND r.action_code='check_soil'
          AND r.rule_state IN ('active','paused') AND r.deleted_at IS NULL
          AND r.id<>v_rule_id
    ) THEN
        v_watermark := public.advance_owner_watermark(p_owner_id);
        WITH replaced AS (
            UPDATE public.task_rules
            SET rule_state='superseded',updated_at=v_watermark
            WHERE owner_id=p_owner_id AND plant_id=p_plant_id
              AND access_class='basic_care' AND action_code='check_soil'
              AND rule_state IN ('active','paused') AND deleted_at IS NULL
              AND id IS DISTINCT FROM v_rule_id
            RETURNING id
        )
        UPDATE public.care_tasks t
        SET state='superseded',reminder_eligible=false,inactive_reason='plan_superseded',
            revision=t.revision+1,updated_at=v_watermark
        FROM replaced r
        WHERE t.rule_id=r.id AND t.owner_id=p_owner_id AND t.plant_id=p_plant_id
          AND t.state IN ('open','needs_review') AND t.deleted_at IS NULL;
    END IF;

    IF v_rule_id IS NULL THEN
        INSERT INTO public.care_plans(operation_id,owner_id,plant_id,locale,plan_kind,access_tier,
            source_kind,snapshot_id,kb_release_id,care_profile_id,context_revision,full_body,
            created_at,updated_at)
        SELECT p_operation_id,p_owner_id,p_plant_id,'en','routine','basic','catalogue',v_snapshot_id,
            c.kb_release_id,c.id,v_revision,jsonb_build_object('refresh_evidence',v_evidence),
            v_watermark,v_watermark
        FROM public.care_profiles c WHERE c.id=v_profile_id
        RETURNING id INTO STRICT v_plan_id;

        INSERT INTO public.task_rules(plan_id,owner_id,plant_id,access_class,action_code,
            condition_code,interval_days,created_at,updated_at)
        VALUES(v_plan_id,p_owner_id,p_plant_id,'basic_care','check_soil','check_soil_first',
            v_interval,v_watermark,v_watermark);
    END IF;
    RETURN v_watermark;
END;
$$;

REVOKE ALL ON FUNCTION public.write_basic_care_refresh_rule(UUID,UUID,UUID,JSONB,TIMESTAMPTZ)
    FROM PUBLIC,anon,authenticated,service_role;

CREATE OR REPLACE FUNCTION public.execute_care_recommendation_refresh(
    p_owner_id UUID, p_operation_id UUID, p_plant_id UUID, p_payload JSONB
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
    v_watermark TIMESTAMPTZ;
    v_revision INT;
    v_hash TEXT;
    v_receipt public.operation_receipts%ROWTYPE;
    v_candidate JSONB;
    v_read_action TEXT;
    v_state TEXT := 'paused';
    v_result JSONB;
BEGIN
    SELECT updated_at INTO v_watermark FROM public.profiles
    WHERE id=p_owner_id AND account_state='active' AND NOT anonymous FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'ACTIVE_PERMANENT_OWNER_REQUIRED' USING ERRCODE='42501';
    END IF;
    IF p_operation_id IS NULL OR p_plant_id IS NULL
       OR jsonb_typeof(p_payload) IS DISTINCT FROM 'object'
       OR p_payload-'expected_care_revision' <> '{}'::jsonb
       OR jsonb_typeof(p_payload->'expected_care_revision') IS DISTINCT FROM 'number'
       OR (p_payload->>'expected_care_revision') !~ '^[1-9][0-9]{0,9}$' THEN
        RAISE EXCEPTION 'INVALID_CARE_REFRESH_INPUT' USING ERRCODE='22023';
    END IF;
    IF (p_payload->>'expected_care_revision')::bigint > 2147483647 THEN
        RAISE EXCEPTION 'INVALID_CARE_REFRESH_INPUT' USING ERRCODE='22023';
    END IF;
    v_revision := (p_payload->>'expected_care_revision')::int;
    v_hash := encode(sha256(convert_to(
        jsonb_build_array('care.recommendation.refresh',p_plant_id,v_revision)::text,'UTF8')),'hex');
    SELECT * INTO v_receipt FROM public.operation_receipts
    WHERE owner_id=p_owner_id AND operation_id=p_operation_id;
    IF FOUND THEN
        IF v_receipt.command_name <> 'care.recommendation.refresh' OR v_receipt.payload_hash <> v_hash THEN
            RAISE EXCEPTION 'IDEMPOTENCY_CONFLICT' USING ERRCODE='23505';
        END IF;
        RETURN v_receipt.response_payload;
    END IF;

    v_candidate := public.resolve_basic_care_refresh_candidate(p_owner_id,p_plant_id,v_revision);
    IF v_candidate->>'state' = 'eligible' THEN
        SELECT a.value->>'action_id' INTO v_read_action
        FROM public.care_profiles c
        CROSS JOIN LATERAL jsonb_array_elements(c.profile->'actions') WITH ORDINALITY a(value,position)
        WHERE c.id=(v_candidate->>'profile_id')::uuid
          AND a.value->>'action_code'='check_soil' AND a.value->>'purpose'='routine_care'
          AND a.value->'prerequisite_check_ids'='[]'::jsonb
          AND a.value->'contraindication_check_ids'='[]'::jsonb
          AND coalesce(a.value->'active_ingredients','[]'::jsonb)='[]'::jsonb
        ORDER BY a.position LIMIT 1;
        IF v_read_action IS DISTINCT FROM v_candidate->>'action_id' THEN
            v_candidate := jsonb_build_object('state','paused','reason','insufficient_evidence');
        END IF;
    END IF;

    IF v_candidate->>'state' = 'eligible' THEN
        v_watermark := public.write_basic_care_refresh_rule(
            p_owner_id,p_operation_id,p_plant_id,v_candidate,v_watermark);
        v_state := 'refreshed';
    END IF;

    v_result := jsonb_build_object('plant_id',p_plant_id,'care_revision',v_revision,
        'state',v_state,'reason',v_candidate->>'reason','watermark',v_watermark);
    INSERT INTO public.operation_receipts(owner_id,operation_id,command_name,payload_hash,response_payload)
    VALUES (p_owner_id,p_operation_id,'care.recommendation.refresh',v_hash,v_result);
    RETURN v_result;
END;
$$;

REVOKE ALL ON FUNCTION public.execute_care_recommendation_refresh(UUID,UUID,UUID,JSONB)
    FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.execute_care_recommendation_refresh(UUID,UUID,UUID,JSONB)
    TO service_role;

COMMIT;
