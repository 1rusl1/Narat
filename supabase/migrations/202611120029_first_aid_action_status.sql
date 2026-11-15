BEGIN;

CREATE FUNCTION public.first_aid_approved_source(p_provenance JSONB, p_path TEXT)
RETURNS JSONB LANGUAGE SQL STABLE SET search_path = '' AS $$
    SELECT jsonb_build_object('url', d.value->>'url', 'locator', e.value->>'locator')
    FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p_provenance->'field_evidence'->p_path) = 'array'
        THEN p_provenance->'field_evidence'->p_path ELSE '[]'::jsonb END)
        WITH ORDINALITY e(value, position)
    JOIN LATERAL jsonb_array_elements(CASE WHEN jsonb_typeof(p_provenance->'source_documents') = 'array'
        THEN p_provenance->'source_documents' ELSE '[]'::jsonb END)
        d(value) ON d.value->>'source_id' = e.value->>'source_id'
    WHERE d.value->'allowed_for' ? 'derived_records'
      AND d.value->>'url' ~ '^https://[[:alnum:]][[:alnum:].-]+(:[0-9]+)?(/[^[:space:]]*)?$'
      AND nullif(btrim(e.value->>'locator'), '') IS NOT NULL
    ORDER BY e.position, d.value->>'url'
    LIMIT 1
$$;
REVOKE ALL ON FUNCTION public.first_aid_approved_source(JSONB, TEXT) FROM PUBLIC, anon, authenticated, service_role;

-- The command and the owner status view both resolve the same applicable action.
CREATE OR REPLACE FUNCTION public.read_first_aid_action(p_owner UUID, p_plant UUID, p_job UUID)
RETURNS TABLE(analysis_id UUID, kb_release_id UUID, protocol_id UUID,
    context_revision INT, action JSONB, interval_days INT, interval_source JSONB)
LANGUAGE SQL STABLE SET search_path = '' AS $$
    SELECT (r.projection->>'analysis_id')::uuid, j.kb_release_id, c.id, p.care_revision,
        a.value || jsonb_build_object('source', proof.action_source),
        CASE WHEN proof.interval_source IS NOT NULL
            AND jsonb_typeof(a.value->'next_check_interval_days') = 'number'
            AND a.value->>'next_check_interval_days' ~ '^([1-9]|[1-8][0-9]|90)$'
            AND a.value->'next_check_interval_days' = r.projection->'control_interval_days'
            THEN (a.value->>'next_check_interval_days')::int END,
        proof.interval_source
    FROM public.plants p
    JOIN public.analysis_jobs j ON j.plant_id = p.id AND j.owner_id = p.owner_id
    JOIN public.diagnosis_job_runtime r ON r.job_id = j.id
    JOIN public.kb_releases k ON k.id = j.kb_release_id AND k.state = 'published'
    JOIN public.condition_profiles c ON c.kb_release_id = k.id AND c.state = 'published'
        AND c.condition_id = r.projection->>'selected_condition_id'
    CROSS JOIN LATERAL jsonb_array_elements(CASE WHEN jsonb_typeof(c.protocol->'actions') = 'array'
        THEN c.protocol->'actions' ELSE '[]'::jsonb END) WITH ORDINALITY a(value, position)
    CROSS JOIN LATERAL (
        SELECT public.first_aid_approved_source(c.protocol->'provenance',
            '/actions/' || (a.position - 1)::text) AS action_source,
            public.first_aid_approved_source(c.protocol->'provenance',
                '/actions/' || (a.position - 1)::text || '/next_check_interval_days') AS interval_source
    ) proof
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
      AND a.value->>'action_id' ~ '^[a-z][a-z0-9_]*$'
      AND proof.action_source IS NOT NULL
      AND a.value->>'action_code' = 'check_soil' AND a.value->>'purpose' = 'diagnostic_check'
      AND a.value->'prerequisite_check_ids' = '[]'::jsonb
      AND a.value->'contraindication_check_ids' = '[]'::jsonb
      AND c.protocol->'contraindication_check_ids' = '[]'::jsonb
      AND coalesce(a.value->'active_ingredients', '[]'::jsonb) = '[]'::jsonb
      AND a.value->>(CASE j.locale WHEN 'pl' THEN 'action_pl' ELSE 'action_en' END)
          = r.projection->>'first_action_summary'
$$;

CREATE OR REPLACE FUNCTION public.read_diagnosis_job(p_owner_id UUID, p_job_id UUID)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
    v_job public.analysis_jobs%ROWTYPE;
    v_guest BOOLEAN;
    v_payload JSONB;
    v_action JSONB;
BEGIN
    SELECT anonymous INTO v_guest FROM public.profiles
    WHERE id = p_owner_id AND account_state = 'active' FOR UPDATE;
    IF NOT FOUND THEN RETURN NULL; END IF;
    -- Settlement follows the quota service lock order even for a status poll.
    PERFORM i.id FROM public.installation_access i JOIN public.analysis_jobs j
      ON j.quota_installation_id=i.id
    WHERE j.id=p_job_id AND j.owner_id=p_owner_id FOR UPDATE OF i;
    SELECT j.* INTO v_job FROM public.analysis_jobs j
    JOIN public.diagnosis_job_runtime r ON r.job_id = j.id
    WHERE j.owner_id = p_owner_id AND j.id = p_job_id
      AND (NOT v_guest OR (j.mode = 'identification' AND j.quota_installation_id IS NOT NULL))
    FOR UPDATE OF j;
    IF NOT FOUND THEN RETURN NULL; END IF;
    IF v_guest AND v_job.state='succeeded' AND (
        EXISTS (SELECT 1 FROM public.guest_identification_sources
          WHERE photo_id=v_job.photo_ids[1] AND expires_at<=clock_timestamp())
        OR EXISTS (SELECT 1 FROM public.guest_drafts WHERE id=v_job.draft_id
          AND (deleted_at IS NOT NULL OR claimed_at IS NOT NULL))
    ) THEN RETURN NULL; END IF;
    IF v_job.state IN ('queued','running') AND v_job.deadline_at <= clock_timestamp() THEN
        PERFORM public.finalize_analysis_quota(v_job.id, 'timed_out', true, clock_timestamp());
        UPDATE public.analysis_jobs SET error_code = 'ANALYSIS_TIMEOUT' WHERE id = v_job.id;
    END IF;
    v_payload := public.diagnosis_job_payload(v_job.id);
    IF NOT v_guest AND v_job.mode = 'diagnosis' AND v_job.state = 'succeeded'
       AND v_job.plant_id IS NOT NULL AND v_payload->>'target_plant_id' = v_job.plant_id::text THEN
        SELECT jsonb_build_object(
            'job_id', v_job.id, 'plant_id', v_job.plant_id,
            'action_id', a.action->>'action_id', 'action_code', a.action->>'action_code',
            'source', a.action->'source')
        INTO v_action
        FROM public.read_first_aid_action(p_owner_id, v_job.plant_id, v_job.id) a
        WHERE NOT EXISTS (
            SELECT 1 FROM public.care_entries e
            WHERE e.owner_id = p_owner_id AND e.first_aid_job_id = v_job.id
        ) AND NOT EXISTS (
            SELECT 1 FROM public.first_aid_followups f
            WHERE f.owner_id = p_owner_id AND f.plant_id = v_job.plant_id
                AND f.origin_analysis_id = a.analysis_id
        );
        IF v_action IS NOT NULL THEN
            v_payload := v_payload || jsonb_build_object('first_aid_action', v_action);
        END IF;
    END IF;
    RETURN v_payload;
END;
$$;

COMMIT;
