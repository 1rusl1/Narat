BEGIN;

ALTER TABLE public.care_entries ADD COLUMN first_aid_job_id UUID;
CREATE UNIQUE INDEX care_entries_one_first_aid_per_job
    ON public.care_entries(owner_id, first_aid_job_id) WHERE first_aid_job_id IS NOT NULL;

-- Resolve only the same published action that the canonical diagnosis presented.
CREATE FUNCTION public.read_first_aid_action(p_owner UUID, p_plant UUID, p_job UUID)
RETURNS TABLE(analysis_id UUID, kb_release_id UUID, protocol_id UUID,
    context_revision INT, action JSONB, interval_days INT, interval_source JSONB)
LANGUAGE SQL STABLE SET search_path = '' AS $$
    SELECT (r.projection->>'analysis_id')::uuid, j.kb_release_id, c.id, p.care_revision, a.value,
        CASE WHEN source.value IS NOT NULL
            AND jsonb_typeof(a.value->'next_check_interval_days') = 'number'
            AND a.value->>'next_check_interval_days' ~ '^([1-9]|[1-8][0-9]|90)$'
            AND a.value->'next_check_interval_days' = r.projection->'control_interval_days'
            THEN (a.value->>'next_check_interval_days')::int END,
        source.value
    FROM public.plants p
    JOIN public.analysis_jobs j ON j.plant_id = p.id AND j.owner_id = p.owner_id
    JOIN public.diagnosis_job_runtime r ON r.job_id = j.id
    JOIN public.kb_releases k ON k.id = j.kb_release_id AND k.state = 'published'
    JOIN public.condition_profiles c ON c.kb_release_id = k.id AND c.state = 'published'
        AND c.condition_id = r.projection->>'selected_condition_id'
    CROSS JOIN LATERAL jsonb_array_elements(CASE WHEN jsonb_typeof(c.protocol->'actions') = 'array'
        THEN c.protocol->'actions' ELSE '[]'::jsonb END) WITH ORDINALITY a(value, position)
    CROSS JOIN LATERAL (SELECT c.protocol#>ARRAY['provenance','field_evidence',
        '/actions/' || (a.position - 1)::text || '/next_check_interval_days'] AS evidence,
        c.protocol#>'{provenance,source_documents}' AS documents) provenance
    LEFT JOIN LATERAL (
        SELECT jsonb_build_object('url', d.value->>'url', 'locator', e.value->>'locator') AS value
        FROM jsonb_array_elements(CASE WHEN jsonb_typeof(provenance.evidence) = 'array'
            THEN provenance.evidence ELSE '[]'::jsonb END)
            WITH ORDINALITY e(value, position)
        JOIN LATERAL jsonb_array_elements(CASE WHEN jsonb_typeof(provenance.documents) = 'array'
            THEN provenance.documents ELSE '[]'::jsonb END)
            d(value) ON d.value->>'source_id' = e.value->>'source_id'
        WHERE d.value->'allowed_for' ? 'derived_records'
          AND d.value->>'url' ~ '^https://[[:alnum:]][[:alnum:].-]+(:[0-9]+)?(/[^[:space:]]*)?$'
          AND nullif(btrim(e.value->>'locator'), '') IS NOT NULL
        ORDER BY e.position, d.value->>'url'
        LIMIT 1
    ) source ON true
    WHERE p.id = p_plant AND p.owner_id = p_owner AND p.deleted_at IS NULL
      AND j.id = p_job AND j.mode = 'diagnosis' AND j.state = 'succeeded'
      AND j.snapshot_id IS NOT DISTINCT FROM p.current_condition_snapshot_id
      AND r.projection->>'diagnosis_status' = 'problem_detected'
      AND r.projection->>'plan_availability' = 'available'
      AND r.projection->>'identification_status' = 'identified'
      AND r.projection->>'plant_id' = p.plant_id
      AND c.protocol->>'kb_release_id' = k.id::text
      AND c.protocol->>'condition_id' = c.condition_id
      AND a.value->>'action_id' = c.protocol->>'first_help_action_id'
      AND a.value->>'action_code' = 'check_soil' AND a.value->>'purpose' = 'diagnostic_check'
      AND a.value->'prerequisite_check_ids' = '[]'::jsonb
      AND a.value->'contraindication_check_ids' = '[]'::jsonb
      AND c.protocol->'contraindication_check_ids' = '[]'::jsonb
      AND coalesce(a.value->'active_ingredients', '[]'::jsonb) = '[]'::jsonb
      AND a.value->>(CASE j.locale WHEN 'pl' THEN 'action_pl' ELSE 'action_en' END)
          = r.projection->>'first_action_summary'
$$;
REVOKE ALL ON FUNCTION public.read_first_aid_action(UUID, UUID, UUID) FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.execute_manual_care_command(
    p_owner_id UUID, p_operation_id UUID, p_plant_id UUID,
    p_command_name TEXT, p_payload JSONB
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
    v_owner public.profiles%ROWTYPE;
    v_receipt public.operation_receipts%ROWTYPE;
    v_hash TEXT;
    v_occurred_at TIMESTAMPTZ;
    v_timezone TEXT;
    v_ts TIMESTAMPTZ;
    v_entry_id UUID;
    v_reversal_id UUID;
    v_entry_state TEXT;
    v_result JSONB;
    v_first_aid_job UUID;
    v_first_aid RECORD;
    v_control_id UUID;
    v_local_day DATE;
BEGIN
    IF p_operation_id IS NULL OR p_plant_id IS NULL OR p_command_name IS NULL
       OR p_command_name NOT IN ('care.record', 'care.undo', 'care.correct_date', 'care.first_aid.record')
       OR jsonb_typeof(p_payload) IS DISTINCT FROM 'object' THEN
        RAISE EXCEPTION 'INVALID_CARE_INPUT' USING ERRCODE = '22023';
    END IF;

    SELECT * INTO v_owner FROM public.profiles WHERE id = p_owner_id FOR UPDATE;
    IF NOT FOUND OR v_owner.account_state <> 'active' OR v_owner.anonymous THEN
        RAISE EXCEPTION 'ACTIVE_PERMANENT_OWNER_REQUIRED' USING ERRCODE = '42501';
    END IF;

    v_hash := encode(sha256(convert_to(
        jsonb_build_array(p_command_name, p_plant_id, p_payload)::text, 'UTF8')), 'hex');
    SELECT * INTO v_receipt FROM public.operation_receipts
    WHERE owner_id = p_owner_id AND operation_id = p_operation_id;
    IF FOUND THEN
        IF v_receipt.command_name <> p_command_name OR v_receipt.payload_hash <> v_hash THEN
            RAISE EXCEPTION 'IDEMPOTENCY_CONFLICT' USING ERRCODE = '23505';
        END IF;
        RETURN v_receipt.response_payload;
    END IF;

    PERFORM 1 FROM public.plants
    WHERE id = p_plant_id AND owner_id = p_owner_id AND deleted_at IS NULL
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PLANT_NOT_FOUND' USING ERRCODE = 'P0002';
    END IF;

    IF (CASE p_command_name
        WHEN 'care.record' THEN
            p_payload - ARRAY['action_code', 'occurred_at', 'timezone'] <> '{}'::jsonb
            OR p_payload->>'action_code' IS DISTINCT FROM 'water'
        WHEN 'care.first_aid.record' THEN
            p_payload - ARRAY['job_id', 'occurred_at', 'timezone'] <> '{}'::jsonb
            OR p_payload->>'job_id' IS NULL
        WHEN 'care.correct_date' THEN
            p_payload - ARRAY['entry_id', 'occurred_at', 'timezone'] <> '{}'::jsonb
            OR p_payload->>'entry_id' IS NULL
        ELSE p_payload - 'entry_id' <> '{}'::jsonb OR p_payload->>'entry_id' IS NULL
    END) THEN
        RAISE EXCEPTION 'INVALID_CARE_INPUT' USING ERRCODE = '22023';
    END IF;

    IF p_command_name <> 'care.undo' THEN
        v_timezone := p_payload->>'timezone';
        IF coalesce(p_payload->>'occurred_at', '') !~
               '^[0-9]{4}-[0-9]{2}-[0-9]{2}T([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9]([.][0-9]{1,6})?(Z|[+-](0[0-9]|1[0-5]):[0-5][0-9])$'
           OR v_timezone IS NULL OR length(v_timezone) > 128
           OR NOT EXISTS (SELECT 1 FROM pg_catalog.pg_timezone_names WHERE name = v_timezone) THEN
            RAISE EXCEPTION 'INVALID_CARE_INPUT' USING ERRCODE = '22023';
        END IF;
        v_occurred_at := (p_payload->>'occurred_at')::timestamptz;
        IF v_occurred_at > clock_timestamp() THEN
            RAISE EXCEPTION 'FUTURE_CARE_ENTRY' USING ERRCODE = '22023';
        END IF;
    END IF;

    IF p_command_name = 'care.first_aid.record' THEN
        v_first_aid_job := (p_payload->>'job_id')::uuid;
        SELECT * INTO v_first_aid FROM public.read_first_aid_action(p_owner_id, p_plant_id, v_first_aid_job);
        IF NOT FOUND THEN RAISE EXCEPTION 'FIRST_AID_ACTION_NOT_FOUND' USING ERRCODE = 'P0002'; END IF;
        IF EXISTS (
            SELECT 1 FROM public.first_aid_followups
            WHERE owner_id = p_owner_id AND plant_id = p_plant_id
                AND origin_analysis_id = v_first_aid.analysis_id
        ) THEN
            RAISE EXCEPTION 'FIRST_AID_ALREADY_RECORDED' USING ERRCODE = '23505';
        END IF;
    END IF;

    IF p_command_name IN ('care.record', 'care.first_aid.record') THEN
        v_local_day := timezone(v_timezone, v_occurred_at)::date;
        v_ts := public.advance_owner_watermark(p_owner_id);
        INSERT INTO public.care_entries (
            owner_id, plant_id, action_code, occurred_at, occurred_local_date,
            timezone, operation_id, recorded_at, updated_at, first_aid_job_id
        ) VALUES (
            p_owner_id, p_plant_id, CASE WHEN v_first_aid_job IS NULL THEN 'water' ELSE 'check_soil' END,
            v_occurred_at, v_local_day, v_timezone, p_operation_id, v_ts, v_ts, v_first_aid_job
        ) RETURNING id INTO v_entry_id;
        v_entry_state := 'active';
        IF v_first_aid_job IS NOT NULL THEN
            IF v_first_aid.interval_days IS NOT NULL AND (
                NOT EXISTS (SELECT 1 FROM public.entitlements e WHERE e.owner_id = p_owner_id)
                OR public.has_verified_paid_access(p_owner_id, v_ts)
            ) THEN
                INSERT INTO public.first_aid_followups(
                    owner_id, plant_id, origin_analysis_id, kb_release_id, protocol_id, action_code,
                    first_action_snapshot, check_policy_snapshot, action_entry_id, context_revision,
                    created_at, updated_at
                ) VALUES (
                    p_owner_id, p_plant_id, v_first_aid.analysis_id, v_first_aid.kb_release_id,
                    v_first_aid.protocol_id, 'check_soil', v_first_aid.action, jsonb_build_object(
                        'due_on', v_local_day + v_first_aid.interval_days,
                        'interval_days', v_first_aid.interval_days,
                        'source', v_first_aid.interval_source),
                    v_entry_id, v_first_aid.context_revision, v_ts, v_ts
                ) RETURNING id INTO v_control_id;
            END IF;
        END IF;
    ELSE
        v_entry_id := (p_payload->>'entry_id')::uuid;
        SELECT state INTO v_entry_state FROM public.care_entries
        WHERE id = v_entry_id AND owner_id = p_owner_id AND plant_id = p_plant_id
            AND task_id IS NULL AND deleted_at IS NULL
            AND (action_code = 'water' OR (p_command_name = 'care.undo' AND first_aid_job_id IS NOT NULL))
        FOR UPDATE;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'CARE_ENTRY_NOT_FOUND' USING ERRCODE = 'P0002';
        END IF;
        IF v_entry_state <> 'active' THEN
            RAISE EXCEPTION 'CARE_ENTRY_ALREADY_VOIDED' USING ERRCODE = '23505';
        END IF;
        v_ts := public.advance_owner_watermark(p_owner_id);
        IF p_command_name = 'care.correct_date' THEN
            UPDATE public.care_entries
            SET occurred_at = v_occurred_at,
                occurred_local_date = timezone(v_timezone, v_occurred_at)::date,
                timezone = v_timezone, updated_at = v_ts
            WHERE id = v_entry_id;
        ELSE
            UPDATE public.care_entries SET state = 'voided', updated_at = v_ts WHERE id = v_entry_id;
            INSERT INTO public.care_reversals (owner_id, entry_id, operation_id, recorded_at, updated_at)
            VALUES (p_owner_id, v_entry_id, p_operation_id, v_ts, v_ts)
            RETURNING id INTO v_reversal_id;
            UPDATE public.first_aid_followups SET state = 'undone', updated_at = v_ts
            WHERE owner_id = p_owner_id AND plant_id = p_plant_id AND action_entry_id = v_entry_id
                AND state = 'active' AND deleted_at IS NULL
                AND EXISTS (SELECT 1 FROM public.care_entries
                    WHERE id = v_entry_id AND first_aid_job_id IS NOT NULL);
            v_entry_state := 'voided';
        END IF;
    END IF;

    v_result := jsonb_build_object(
        'plant_id', p_plant_id, 'entry_id', v_entry_id, 'reversal_id', v_reversal_id,
        'state', v_entry_state, 'watermark', v_ts);
    IF v_first_aid_job IS NOT NULL THEN
        v_result := v_result || jsonb_build_object('control_id', v_control_id);
    END IF;
    INSERT INTO public.operation_receipts (owner_id, operation_id, command_name, payload_hash, response_payload)
    VALUES (p_owner_id, p_operation_id, p_command_name, v_hash, v_result);
    RETURN v_result;
END;
$$;

REVOKE ALL ON FUNCTION public.execute_manual_care_command(UUID, UUID, UUID, TEXT, JSONB)
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.execute_manual_care_command(UUID, UUID, UUID, TEXT, JSONB)
TO service_role;

COMMIT;
