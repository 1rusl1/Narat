BEGIN;

-- Internal writer only: no transport is authorized to execute this yet.
CREATE FUNCTION public.execute_routine_soil_check(
    p_owner_id UUID, p_operation_id UUID, p_plant_id UUID,
    p_expected_care_revision INT, p_rule_id UUID, p_due_local_date DATE,
    p_occurred_at TIMESTAMPTZ, p_timezone TEXT
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
    v_receipt public.operation_receipts%ROWTYPE;
    v_candidate JSONB;
    v_hash TEXT;
    v_key TEXT;
    v_due DATE;
    v_task UUID;
    v_entry UUID;
    v_ts TIMESTAMPTZ;
    v_result JSONB;
BEGIN
    PERFORM 1 FROM public.profiles
    WHERE id=p_owner_id AND account_state='active' AND NOT anonymous FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'ACTIVE_PERMANENT_OWNER_REQUIRED' USING ERRCODE='42501';
    END IF;
    IF p_operation_id IS NULL OR p_plant_id IS NULL OR p_rule_id IS NULL
       OR p_expected_care_revision IS NULL OR p_expected_care_revision<1
       OR p_due_local_date IS NULL OR NOT isfinite(p_due_local_date)
       OR p_occurred_at IS NULL OR NOT isfinite(p_occurred_at)
       OR p_timezone IS NULL OR length(p_timezone)>128
       OR NOT EXISTS (SELECT 1 FROM pg_catalog.pg_timezone_names WHERE name=p_timezone) THEN
        RAISE EXCEPTION 'INVALID_SOIL_CHECK_INPUT' USING ERRCODE='22023';
    END IF;

    -- Canonical dates/instants keep replay independent of session TimeZone/DateStyle.
    v_hash := encode(sha256(convert_to(jsonb_build_array(
        'care.check_soil.complete',p_plant_id,p_expected_care_revision,p_rule_id,
        to_char(p_due_local_date,'YYYY-MM-DD'),extract(epoch FROM p_occurred_at),
        p_timezone)::text,'UTF8')),'hex');
    SELECT * INTO v_receipt FROM public.operation_receipts
    WHERE owner_id=p_owner_id AND operation_id=p_operation_id;
    IF FOUND THEN
        IF v_receipt.command_name<>'care.check_soil.complete' OR v_receipt.payload_hash<>v_hash THEN
            RAISE EXCEPTION 'IDEMPOTENCY_CONFLICT' USING ERRCODE='23505';
        END IF;
        RETURN v_receipt.response_payload;
    END IF;

    -- Locks current plant/revision, published evidence, membership, access and anchor.
    v_candidate := public.resolve_basic_care_refresh_candidate(
        p_owner_id,p_plant_id,p_expected_care_revision);
    IF v_candidate->>'state' IS DISTINCT FROM 'eligible' THEN
        RAISE EXCEPTION 'ROUTINE_SOIL_CHECK_UNAVAILABLE' USING ERRCODE='55000';
    END IF;
    PERFORM 1 FROM public.task_rules r
    JOIN public.care_plans cp ON cp.id=r.plan_id
      AND cp.owner_id=r.owner_id AND cp.plant_id=r.plant_id
    WHERE r.id=p_rule_id AND r.owner_id=p_owner_id AND r.plant_id=p_plant_id
      AND r.rule_state='active' AND r.deleted_at IS NULL
      AND r.access_class='basic_care' AND r.action_code='check_soil'
      AND r.condition_code='check_soil_first'
      AND r.interval_days=(v_candidate->>'interval_days')::int
      AND cp.plan_kind='routine' AND cp.access_tier='basic'
      AND cp.state='active' AND cp.deleted_at IS NULL
      AND cp.snapshot_id=(v_candidate->>'snapshot_id')::uuid
      AND cp.context_revision=p_expected_care_revision
      AND cp.care_profile_id=(v_candidate->>'profile_id')::uuid
      AND cp.full_body=jsonb_build_object('refresh_evidence',v_candidate-ARRAY['state','anchor_on'])
    FOR SHARE OF r,cp;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'CURRENT_REFRESHED_RULE_REQUIRED' USING ERRCODE='55000';
    END IF;
    -- Also enforce the calendar's first displayed action and any explicit pause.
    IF public.read_plant_care_profile(p_owner_id,p_plant_id)->'calendar_eligible'
       IS DISTINCT FROM 'true'::jsonb THEN
        RAISE EXCEPTION 'ROUTINE_SOIL_CHECK_UNAVAILABLE' USING ERRCODE='55000';
    END IF;
    v_due := (v_candidate->>'anchor_on')::date+(v_candidate->>'interval_days')::int;
    IF p_due_local_date<>v_due THEN
        RAISE EXCEPTION 'SOIL_CHECK_OCCURRENCE_CHANGED' USING ERRCODE='23505';
    END IF;
    IF p_occurred_at>clock_timestamp() THEN
        RAISE EXCEPTION 'FUTURE_CARE_ENTRY' USING ERRCODE='22023';
    END IF;
    IF timezone(p_timezone,p_occurred_at)::date<v_due THEN
        RAISE EXCEPTION 'SOIL_CHECK_NOT_DUE' USING ERRCODE='22023';
    END IF;
    v_key := p_rule_id::text||':'||to_char(v_due,'YYYY-MM-DD');
    IF EXISTS (SELECT 1 FROM public.care_tasks
               WHERE plant_id=p_plant_id AND occurrence_key=v_key) THEN
        RAISE EXCEPTION 'SOIL_CHECK_OCCURRENCE_CONFLICT' USING ERRCODE='23505';
    END IF;

    v_ts := public.advance_owner_watermark(p_owner_id);
    INSERT INTO public.care_tasks(owner_id,plant_id,rule_id,occurrence_key,action_code,
        due_local_date,timezone,condition_code,state,reminder_eligible,inactive_reason,created_at,updated_at)
    VALUES(p_owner_id,p_plant_id,p_rule_id,v_key,'check_soil',v_due,p_timezone,
        'check_soil_first','completed',false,'completed',v_ts,v_ts)
    RETURNING id INTO v_task;
    INSERT INTO public.care_entries(owner_id,plant_id,task_id,action_code,occurred_at,
        occurred_local_date,timezone,operation_id,recorded_at,updated_at)
    VALUES(p_owner_id,p_plant_id,v_task,'check_soil',p_occurred_at,
        timezone(p_timezone,p_occurred_at)::date,p_timezone,p_operation_id,v_ts,v_ts)
    RETURNING id INTO v_entry;
    UPDATE public.care_tasks SET completed_entry_id=v_entry WHERE id=v_task;

    v_result := jsonb_build_object('plant_id',p_plant_id,'rule_id',p_rule_id,
        'care_revision',p_expected_care_revision,'occurrence_key',v_key,'due_local_date',v_due,
        'task_id',v_task,'entry_id',v_entry,'state','completed','watermark',v_ts);
    INSERT INTO public.operation_receipts(owner_id,operation_id,command_name,payload_hash,response_payload)
    VALUES(p_owner_id,p_operation_id,'care.check_soil.complete',v_hash,v_result);
    RETURN v_result;
END;
$$;

REVOKE ALL ON FUNCTION public.execute_routine_soil_check(UUID,UUID,UUID,INT,UUID,DATE,TIMESTAMPTZ,TEXT)
    FROM PUBLIC,anon,authenticated,service_role;

COMMIT;
