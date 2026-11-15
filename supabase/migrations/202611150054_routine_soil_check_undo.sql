BEGIN;

-- Manual history remains editable after expiry and evidence withdrawal.
CREATE FUNCTION public.execute_routine_soil_check_undo(
    p_owner_id UUID, p_operation_id UUID, p_plant_id UUID, p_entry_id UUID
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
    v_receipt public.operation_receipts%ROWTYPE;
    v_entry public.care_entries%ROWTYPE;
    v_task UUID;
    v_reversal UUID;
    v_hash TEXT;
    v_ts TIMESTAMPTZ;
    v_result JSONB;
BEGIN
    IF p_operation_id IS NULL OR p_plant_id IS NULL OR p_entry_id IS NULL THEN
        RAISE EXCEPTION 'INVALID_SOIL_CHECK_INPUT' USING ERRCODE='22023';
    END IF;
    PERFORM 1 FROM public.profiles
    WHERE id=p_owner_id AND account_state='active' AND NOT anonymous FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'ACTIVE_PERMANENT_OWNER_REQUIRED' USING ERRCODE='42501';
    END IF;
    v_hash := encode(sha256(convert_to(jsonb_build_array(
        'care.check_soil.undo',p_plant_id,p_entry_id)::text,'UTF8')),'hex');
    SELECT * INTO v_receipt FROM public.operation_receipts
    WHERE owner_id=p_owner_id AND operation_id=p_operation_id;
    IF FOUND THEN
        IF v_receipt.command_name<>'care.check_soil.undo' OR v_receipt.payload_hash<>v_hash THEN
            RAISE EXCEPTION 'IDEMPOTENCY_CONFLICT' USING ERRCODE='23505';
        END IF;
        RETURN v_receipt.response_payload;
    END IF;

    PERFORM 1 FROM public.plants
    WHERE id=p_plant_id AND owner_id=p_owner_id AND deleted_at IS NULL FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PLANT_NOT_FOUND' USING ERRCODE='P0002';
    END IF;
    SELECT * INTO v_entry FROM public.care_entries
    WHERE id=p_entry_id AND owner_id=p_owner_id AND plant_id=p_plant_id
      AND action_code='check_soil' AND first_aid_job_id IS NULL
      AND task_id IS NOT NULL AND deleted_at IS NULL FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'CARE_ENTRY_NOT_FOUND' USING ERRCODE='P0002';
    END IF;
    IF v_entry.state<>'active' THEN
        RAISE EXCEPTION 'CARE_ENTRY_ALREADY_VOIDED' USING ERRCODE='23505';
    END IF;
    SELECT t.id INTO v_task FROM public.care_tasks t
    JOIN public.task_rules r ON r.id=t.rule_id
      AND r.owner_id=t.owner_id AND r.plant_id=t.plant_id
    JOIN public.care_plans cp ON cp.id=r.plan_id
      AND cp.owner_id=r.owner_id AND cp.plant_id=r.plant_id
    WHERE t.id=v_entry.task_id AND t.owner_id=p_owner_id AND t.plant_id=p_plant_id
      AND t.completed_entry_id=p_entry_id AND t.state='completed' AND t.deleted_at IS NULL
      AND t.action_code='check_soil' AND t.condition_code='check_soil_first'
      AND t.occurrence_key=r.id::text||':'||to_char(t.due_local_date,'YYYY-MM-DD')
      AND r.first_aid_id IS NULL AND r.access_class='basic_care'
      AND r.action_code='check_soil' AND r.condition_code='check_soil_first'
      AND cp.plan_kind='routine' AND cp.access_tier='basic'
    FOR UPDATE OF t;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'ROUTINE_SOIL_CHECK_ENTRY_REQUIRED' USING ERRCODE='55000';
    END IF;

    v_ts := public.advance_owner_watermark(p_owner_id);
    UPDATE public.care_entries SET state='voided',updated_at=v_ts WHERE id=p_entry_id;
    INSERT INTO public.care_reversals(owner_id,entry_id,operation_id,recorded_at,updated_at)
    VALUES(p_owner_id,p_entry_id,p_operation_id,v_ts,v_ts) RETURNING id INTO v_reversal;
    UPDATE public.care_tasks
    SET state='superseded',reminder_eligible=false,inactive_reason='first_action_undone',
        updated_at=v_ts
    WHERE id=v_task;

    v_result := jsonb_build_object('plant_id',p_plant_id,'task_id',v_task,
        'entry_id',p_entry_id,'reversal_id',v_reversal,'state','voided','watermark',v_ts);
    INSERT INTO public.operation_receipts(owner_id,operation_id,command_name,payload_hash,response_payload)
    VALUES(p_owner_id,p_operation_id,'care.check_soil.undo',v_hash,v_result);
    RETURN v_result;
END;
$$;
REVOKE ALL ON FUNCTION public.execute_routine_soil_check_undo(UUID,UUID,UUID,UUID)
    FROM PUBLIC,anon,authenticated,service_role;

-- Preserve the accepted writer, including its ACL, receipt lookup and due checks.
-- Only the exact reversed task can be reused; every old fact and receipt survives.
DO $migration$
DECLARE
    definition TEXT;
    old_write TEXT := $old$    IF EXISTS (SELECT 1 FROM public.care_tasks
               WHERE plant_id=p_plant_id AND occurrence_key=v_key) THEN
        RAISE EXCEPTION 'SOIL_CHECK_OCCURRENCE_CONFLICT' USING ERRCODE='23505';
    END IF;

    v_ts := public.advance_owner_watermark(p_owner_id);
    INSERT INTO public.care_tasks(owner_id,plant_id,rule_id,occurrence_key,action_code,
        due_local_date,timezone,condition_code,state,reminder_eligible,inactive_reason,created_at,updated_at)
    VALUES(p_owner_id,p_plant_id,p_rule_id,v_key,'check_soil',v_due,p_timezone,
        'check_soil_first','completed',false,'completed',v_ts,v_ts)
    RETURNING id INTO v_task;$old$;
    new_write TEXT := $new$    SELECT t.id INTO v_task
    FROM public.care_tasks t
    JOIN public.care_entries e ON e.id=t.completed_entry_id
      AND e.task_id=t.id AND e.owner_id=t.owner_id AND e.plant_id=t.plant_id
    JOIN public.care_reversals reversal ON reversal.entry_id=e.id
      AND reversal.owner_id=e.owner_id AND reversal.deleted_at IS NULL
    JOIN public.task_rules r ON r.id=t.rule_id
      AND r.owner_id=t.owner_id AND r.plant_id=t.plant_id
    JOIN public.care_plans cp ON cp.id=r.plan_id
      AND cp.owner_id=r.owner_id AND cp.plant_id=r.plant_id
    WHERE t.owner_id=p_owner_id AND t.plant_id=p_plant_id
      AND t.rule_id=p_rule_id AND t.occurrence_key=v_key AND t.due_local_date=v_due
      AND t.state='superseded' AND t.deleted_at IS NULL
      AND t.action_code='check_soil' AND t.condition_code='check_soil_first'
      AND t.inactive_reason='first_action_undone' AND NOT t.reminder_eligible
      AND e.action_code='check_soil' AND e.first_aid_job_id IS NULL
      AND e.state='voided' AND e.deleted_at IS NULL
      AND r.first_aid_id IS NULL AND r.access_class='basic_care'
      AND r.action_code='check_soil' AND r.condition_code='check_soil_first'
      AND cp.plan_kind='routine' AND cp.access_tier='basic'
      AND NOT EXISTS (SELECT 1 FROM public.care_entries active
          WHERE active.task_id=t.id AND active.state='active')
    FOR UPDATE OF t;
    IF v_task IS NULL AND EXISTS (SELECT 1 FROM public.care_tasks
        WHERE plant_id=p_plant_id AND occurrence_key=v_key) THEN
        RAISE EXCEPTION 'SOIL_CHECK_OCCURRENCE_CONFLICT' USING ERRCODE='23505';
    END IF;

    v_ts := public.advance_owner_watermark(p_owner_id);
    IF v_task IS NULL THEN
        INSERT INTO public.care_tasks(owner_id,plant_id,rule_id,occurrence_key,action_code,
            due_local_date,timezone,condition_code,state,reminder_eligible,inactive_reason,created_at,updated_at)
        VALUES(p_owner_id,p_plant_id,p_rule_id,v_key,'check_soil',v_due,p_timezone,
            'check_soil_first','completed',false,'completed',v_ts,v_ts)
        RETURNING id INTO v_task;
    ELSE
        UPDATE public.care_tasks
        SET state='completed',timezone=p_timezone,reminder_eligible=false,
            inactive_reason='completed',updated_at=v_ts
        WHERE id=v_task;
    END IF;$new$;
BEGIN
    definition := pg_get_functiondef(
        'public.execute_routine_soil_check(uuid,uuid,uuid,integer,uuid,date,timestamptz,text)'::regprocedure);
    IF position(old_write IN definition)=0 THEN
        RAISE EXCEPTION 'Unexpected routine soil check writer implementation';
    END IF;
    EXECUTE replace(definition,old_write,new_write);
END;
$migration$;

COMMIT;
