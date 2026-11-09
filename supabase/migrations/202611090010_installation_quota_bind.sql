-- T163 binding only. No migration-time DML or guest result/media transfer.
BEGIN;
CREATE OR REPLACE FUNCTION public.bind_installation_to_owner(
    p_installation_id UUID, p_owner_id UUID,
    p_now TIMESTAMPTZ DEFAULT now()
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_profile public.profiles%ROWTYPE;
    v_installation public.installation_access%ROWTYPE;
    v_job public.analysis_jobs%ROWTYPE;
    v_sources UUID[];
    v_pointers UUID[] := ARRAY[NULL, NULL]::uuid[];
    v_consumed BOOLEAN[];
    v_linked UUID[];
    v_first TIMESTAMPTZ;
    v_mode TEXT;
    v_index INTEGER;
    v_side INTEGER;
    v_pointer UUID;
BEGIN
    IF p_now IS NULL OR NOT isfinite(p_now) THEN
        RAISE EXCEPTION 'INVALID_QUOTA_TIME' USING ERRCODE = '22023';
    END IF;

    -- The service caller supplies verified identities. HTTP credential proof is B2.
    -- Same lock order as 008/009; never acquire a foreign owner's tuple.
    SELECT * INTO v_profile FROM public.profiles WHERE id = p_owner_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'OWNER_NOT_FOUND' USING ERRCODE = 'P0002';
    END IF;
    IF v_profile.anonymous OR v_profile.account_state <> 'active' THEN
        RAISE EXCEPTION 'ACTIVE_PERMANENT_OWNER_REQUIRED' USING ERRCODE = '42501';
    END IF;
    -- Make stale RR/SERIALIZABLE contenders retry without changing the watermark.
    UPDATE public.profiles SET updated_at = updated_at WHERE id = p_owner_id;
    SELECT * INTO v_installation FROM public.installation_access
    WHERE id = p_installation_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'INSTALLATION_NOT_FOUND' USING ERRCODE = 'P0002';
    END IF;

    v_sources := ARRAY[v_profile.starter_identification_job_id,
                       v_installation.starter_identification_job_id,
                       v_profile.starter_diagnosis_job_id,
                       v_installation.starter_diagnosis_job_id];
    v_consumed := ARRAY[
        v_profile.starter_identification_consumed OR v_installation.starter_identification_consumed,
        v_profile.starter_diagnosis_consumed OR v_installation.starter_diagnosis_consumed];
    v_first := LEAST(v_profile.first_starter_success_at,
                     v_installation.first_starter_success_at);

    -- Lock all referenced jobs in a stable order, including terminal pointers.
    -- A stored pointer can refer to a guest/shared lease. Read it, never reassign it.
    PERFORM j.id FROM public.analysis_jobs j
    WHERE j.id = ANY(v_sources) ORDER BY j.id FOR UPDATE;
    FOR v_index IN 1..2 LOOP
        v_mode := CASE v_index WHEN 1 THEN 'identification' ELSE 'diagnosis' END;
        FOR v_side IN 1..2 LOOP
            v_pointer := v_sources[(v_index - 1) * 2 + v_side];
            IF v_pointer IS NULL THEN CONTINUE; END IF;
            SELECT * INTO v_job FROM public.analysis_jobs WHERE id = v_pointer;
            IF NOT FOUND OR v_job.mode <> v_mode
               OR v_job.quota_kind <> 'starter_' || v_mode
               OR v_job.monthly_quota_id IS NOT NULL
               OR (v_job.quota_owner_id IS NOT NULL AND v_job.quota_owner_id <> v_job.owner_id) THEN
                RAISE EXCEPTION 'STARTER_HISTORY_UNRESOLVED' USING ERRCODE = '23514';
            END IF;

            IF v_job.quota_state = 'consumed' THEN
                -- Only settlement proves billable success; repair lagging markers.
                v_consumed[v_index] := true;
                v_first := LEAST(v_first, v_job.updated_at);
            ELSIF v_job.quota_state = 'released'
                  OR (v_job.quota_state = 'reserved' AND v_job.state IN ('failed', 'timed_out')) THEN
                -- Drop only terminal references, including a copied guest pointer
                -- on a repeat bind after 009 released the source reservation.
                NULL;
            ELSIF v_job.quota_state = 'reserved' AND v_job.state IN ('queued', 'running', 'succeeded') THEN
                -- Success can still settle non-billable. Keep its blocking pointer
                -- until 009 decides; deadline alone does not settle a live lease.
                IF v_pointers[v_index] IS NOT NULL AND v_pointers[v_index] <> v_pointer THEN
                    RAISE EXCEPTION 'STARTER_RESERVATION_CONFLICT' USING ERRCODE = '23514';
                END IF;
                v_pointers[v_index] := v_pointer;
            ELSE
                RAISE EXCEPTION 'STARTER_HISTORY_UNRESOLVED' USING ERRCODE = '23514';
            END IF;
        END LOOP;
    END LOOP;

    v_linked := CASE WHEN p_owner_id = ANY(v_installation.linked_owner_ids)
        THEN v_installation.linked_owner_ids
        ELSE array_append(v_installation.linked_owner_ids, p_owner_id) END;
    -- Update only starter/binding fields. No registration, purchase or monthly writes.
    -- No-op repeats retain logical row bytes; the tuple update still fences stale reads.
    UPDATE public.installation_access SET
        linked_owner_ids = v_linked,
        starter_identification_consumed = v_consumed[1],
        starter_diagnosis_consumed = v_consumed[2],
        starter_identification_job_id = v_pointers[1],
        starter_diagnosis_job_id = v_pointers[2],
        first_starter_success_at = v_first,
        updated_at = CASE WHEN ROW(linked_owner_ids,
            starter_identification_consumed, starter_diagnosis_consumed,
            starter_identification_job_id, starter_diagnosis_job_id, first_starter_success_at)
            IS DISTINCT FROM ROW(v_linked, v_consumed[1], v_consumed[2],
                v_pointers[1], v_pointers[2], v_first)
            THEN GREATEST(p_now, updated_at) ELSE updated_at END
    WHERE id = p_installation_id;
    UPDATE public.profiles SET
        starter_identification_consumed = v_consumed[1],
        starter_diagnosis_consumed = v_consumed[2],
        starter_identification_job_id = v_pointers[1],
        starter_diagnosis_job_id = v_pointers[2],
        first_starter_success_at = v_first,
        updated_at = CASE WHEN ROW(starter_identification_consumed, starter_diagnosis_consumed,
            starter_identification_job_id, starter_diagnosis_job_id, first_starter_success_at)
            IS DISTINCT FROM ROW(v_consumed[1], v_consumed[2], v_pointers[1], v_pointers[2], v_first)
            THEN GREATEST(p_now, updated_at + INTERVAL '1 microsecond') ELSE updated_at END
    WHERE id = p_owner_id;
    RETURN jsonb_build_object(
        'installation_id', p_installation_id, 'owner_id', p_owner_id,
        'starter_identification_consumed', v_consumed[1],
        'starter_diagnosis_consumed', v_consumed[2],
        'starter_identification_job_id', v_pointers[1],
        'starter_diagnosis_job_id', v_pointers[2],
        'first_starter_success_at', v_first);
END;
$$;
REVOKE ALL ON FUNCTION public.bind_installation_to_owner(UUID, UUID, TIMESTAMPTZ)
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.bind_installation_to_owner(UUID, UUID, TIMESTAMPTZ)
    TO service_role;
COMMIT;
