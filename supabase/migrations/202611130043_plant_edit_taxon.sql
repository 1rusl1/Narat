BEGIN;

CREATE OR REPLACE FUNCTION public.execute_plant_edit_command(
    p_owner_id UUID, p_operation_id UUID, p_plant_id UUID, p_payload JSONB
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
    v_plant public.plants%ROWTYPE;
    v_receipt public.operation_receipts%ROWTYPE;
    v_hash TEXT;
    v_name TEXT;
    v_taxon_id UUID;
    v_species_slug TEXT;
    v_conditions JSONB;
    v_snapshot public.condition_snapshots%ROWTYPE;
    v_snapshot_id UUID;
    v_version INT;
    v_light TEXT;
    v_light_source TEXT;
    v_light_confirmed BOOLEAN;
    v_watering TEXT;
    v_drainage TEXT;
    v_pot TEXT;
    v_watermark TIMESTAMPTZ;
    v_result JSONB;
BEGIN
    PERFORM 1 FROM public.profiles
    WHERE id=p_owner_id AND account_state='active' AND NOT anonymous FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'ACTIVE_PERMANENT_OWNER_REQUIRED' USING ERRCODE = '42501';
    END IF;

    IF p_operation_id IS NULL OR p_plant_id IS NULL
       OR jsonb_typeof(p_payload) IS DISTINCT FROM 'object'
       OR (p_payload - 'personal_name' <> '{}'::jsonb AND p_payload - 'conditions' <> '{}'::jsonb
           AND p_payload - 'taxon_id' <> '{}'::jsonb) THEN
        RAISE EXCEPTION 'INVALID_PLANT_EDIT_INPUT' USING ERRCODE = '22023';
    END IF;
    IF p_payload ? 'conditions' THEN
        v_conditions := p_payload->'conditions';
        IF jsonb_typeof(v_conditions) IS DISTINCT FROM 'object' OR v_conditions='{}'::jsonb
           OR v_conditions - ARRAY['light_code','watering_code','drainage_code','pot_type'] <> '{}'::jsonb THEN
            RAISE EXCEPTION 'INVALID_PLANT_EDIT_INPUT' USING ERRCODE = '22023';
        END IF;
        IF EXISTS (
            SELECT 1 FROM jsonb_each(v_conditions) AS c(key,value)
            WHERE jsonb_typeof(c.value)<>'string'
               OR NOT (c.value#>>'{}' = ANY(CASE c.key
                  WHEN 'light_code' THEN ARRAY['low','medium','bright_indirect','direct_sun','unknown']
                  WHEN 'watering_code' THEN ARRAY['several_weekly','weekly','less_often','frequent','moderate','sparse','unknown']
                  WHEN 'drainage_code' THEN ARRAY['yes','no','unknown']
                  WHEN 'pot_type' THEN ARRAY['terracotta','plastic','glazed_ceramic','standard_drainage','other','unknown']
               END))
        ) THEN
            RAISE EXCEPTION 'INVALID_PLANT_EDIT_INPUT' USING ERRCODE = '22023';
        END IF;
    ELSIF p_payload ? 'taxon_id' THEN
        IF jsonb_typeof(p_payload->'taxon_id') IS DISTINCT FROM 'string'
           OR p_payload->>'taxon_id' !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$' THEN
            RAISE EXCEPTION 'INVALID_PLANT_EDIT_INPUT' USING ERRCODE = '22023';
        END IF;
        v_taxon_id := (p_payload->>'taxon_id')::uuid;
        p_payload := jsonb_build_object('taxon_id',v_taxon_id);
    ELSE
        IF jsonb_typeof(p_payload->'personal_name') IS DISTINCT FROM 'string' THEN
            RAISE EXCEPTION 'INVALID_PLANT_EDIT_INPUT' USING ERRCODE = '22023';
        END IF;
        v_name := regexp_replace(p_payload->>'personal_name', '^[[:space:]]+|[[:space:]]+$', '', 'g');
        IF char_length(v_name) NOT BETWEEN 1 AND 120 THEN
            RAISE EXCEPTION 'INVALID_PLANT_EDIT_INPUT' USING ERRCODE = '22023';
        END IF;
    END IF;

    v_hash := encode(sha256(convert_to(
        jsonb_build_array('plant.edit',p_plant_id,p_payload)::text,'UTF8')),'hex');
    SELECT * INTO v_receipt FROM public.operation_receipts
    WHERE owner_id=p_owner_id AND operation_id=p_operation_id;
    IF FOUND THEN
        IF v_receipt.command_name <> 'plant.edit' OR v_receipt.payload_hash <> v_hash THEN
            RAISE EXCEPTION 'IDEMPOTENCY_CONFLICT' USING ERRCODE = '23505';
        END IF;
        RETURN v_receipt.response_payload;
    END IF;

    SELECT * INTO v_plant FROM public.plants
    WHERE id=p_plant_id AND owner_id=p_owner_id AND deleted_at IS NULL FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PLANT_NOT_FOUND' USING ERRCODE = 'P0002';
    END IF;
    IF v_taxon_id IS NOT NULL THEN
        SELECT t.plant_id INTO v_species_slug
        FROM public.catalogue_taxa t
        JOIN public.catalogue_releases cr ON cr.id=t.release_id AND cr.state='published'
        JOIN public.catalogue_release_species s ON s.release_id=cr.id AND s.taxon_id=t.id
        WHERE t.id=v_taxon_id AND t.status='published'
          AND s.status='published' AND s.rank IN ('species','hybrid')
          AND s.plant_id=t.plant_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'TAXON_NOT_PUBLISHED' USING ERRCODE = '22023';
        END IF;
        v_conditions := '{}'::jsonb;
    END IF;
    IF v_conditions IS NOT NULL THEN
        SELECT * INTO v_snapshot FROM public.condition_snapshots
        WHERE id=v_plant.current_condition_snapshot_id AND plant_id=p_plant_id
          AND owner_id=p_owner_id AND deleted_at IS NULL;
        IF NOT FOUND AND v_plant.current_condition_snapshot_id IS NOT NULL THEN
            RAISE EXCEPTION 'CURRENT_CONDITION_SNAPSHOT_UNAVAILABLE';
        END IF;

        v_light := coalesce(v_conditions->>'light_code',v_snapshot.light_code,'unknown');
        v_watering := coalesce(v_conditions->>'watering_code',v_snapshot.watering_code,'unknown');
        v_drainage := coalesce(v_conditions->>'drainage_code',v_snapshot.drainage_code,'unknown');
        v_pot := coalesce(v_conditions->>'pot_type',v_snapshot.pot_type,'unknown');
        IF v_conditions ? 'light_code' THEN
            v_light_confirmed := v_light <> 'unknown';
            v_light_source := CASE WHEN v_light_confirmed THEN 'manual' ELSE 'unknown' END;
        ELSE
            v_light_confirmed := coalesce(v_snapshot.light_confirmed,false);
            v_light_source := coalesce(v_snapshot.light_source,'unknown');
        END IF;

        IF (v_taxon_id IS NOT NULL AND ROW(v_taxon_id,v_species_slug)
              IS DISTINCT FROM ROW(v_plant.taxon_id,v_plant.plant_id))
           OR ROW(v_light,v_light_source,v_light_confirmed,v_watering,v_drainage,v_pot)
           IS DISTINCT FROM ROW(coalesce(v_snapshot.light_code,'unknown'),
               coalesce(v_snapshot.light_source,'unknown'),coalesce(v_snapshot.light_confirmed,false),
               coalesce(v_snapshot.watering_code,'unknown'),coalesce(v_snapshot.drainage_code,'unknown'),
               coalesce(v_snapshot.pot_type,'unknown')) THEN
            SELECT coalesce(max(version),0)+1 INTO v_version FROM public.condition_snapshots
            WHERE plant_id=p_plant_id;
            v_watermark := public.advance_owner_watermark(p_owner_id);
            INSERT INTO public.condition_snapshots(
                owner_id,plant_id,version,light_code,light_source,light_confirmed,watering_code,
                drainage_code,pot_type,season_override,created_at,updated_at)
            VALUES (p_owner_id,p_plant_id,v_version,v_light,v_light_source,v_light_confirmed,
                v_watering,v_drainage,v_pot,coalesce(v_snapshot.season_override,'auto'),v_watermark,v_watermark)
            RETURNING id INTO v_snapshot_id;

            UPDATE public.plants
            SET current_condition_snapshot_id=v_snapshot_id, revision=revision+1,
                taxon_id=coalesce(v_taxon_id,taxon_id), plant_id=coalesce(v_species_slug,plant_id),
                care_revision=care_revision+1, updated_at=v_watermark
            WHERE id=p_plant_id AND owner_id=p_owner_id RETURNING * INTO v_plant;

            UPDATE public.analysis_results
            SET context_state='stale',updated_at=v_watermark
            WHERE owner_id=p_owner_id AND plant_id=p_plant_id AND deleted_at IS NULL
              AND context_state='current'
              AND (source_snapshot_id IS DISTINCT FROM v_snapshot_id
                  OR source_care_revision<>v_plant.care_revision);

            -- Active first-aid controls are bound to the old care revision.
            -- Completed observations and their photo resolver still use the same control.
            UPDATE public.first_aid_followups
            SET state='superseded',updated_at=v_watermark
            WHERE owner_id=p_owner_id AND plant_id=p_plant_id AND deleted_at IS NULL
              AND state='active' AND context_revision<>v_plant.care_revision;

            WITH stale_rules AS MATERIALIZED (
                SELECT r.id FROM public.task_rules r
                WHERE r.owner_id=p_owner_id AND r.plant_id=p_plant_id
                  AND r.deleted_at IS NULL AND r.rule_state='active'
                  AND (
                    EXISTS (SELECT 1 FROM public.care_plans p
                        WHERE p.id=r.plan_id AND p.owner_id=p_owner_id AND p.plant_id=p_plant_id
                          AND (p.context_revision<>v_plant.care_revision OR p.snapshot_id<>v_snapshot_id))
                    OR EXISTS (SELECT 1 FROM public.first_aid_followups f
                        WHERE f.id=r.first_aid_id AND f.owner_id=p_owner_id AND f.plant_id=p_plant_id
                          AND f.state='superseded' AND f.updated_at=v_watermark)
                  )
            ), paused AS (
                UPDATE public.task_rules SET rule_state='paused',updated_at=v_watermark
                WHERE id IN (SELECT id FROM stale_rules)
            )
            UPDATE public.care_tasks t
            SET reminder_eligible=false,inactive_reason='plan_superseded',updated_at=v_watermark
            WHERE t.owner_id=p_owner_id AND t.plant_id=p_plant_id AND t.deleted_at IS NULL
              AND t.state IN ('open','needs_review')
              AND (t.rule_id IN (SELECT id FROM stale_rules)
                OR EXISTS (SELECT 1 FROM public.first_aid_followups f
                    WHERE f.control_task_id=t.id AND f.owner_id=p_owner_id AND f.plant_id=p_plant_id
                      AND f.state='superseded' AND f.updated_at=v_watermark))
              AND (t.reminder_eligible OR t.inactive_reason IS DISTINCT FROM 'plan_superseded');
        END IF;
    ELSIF v_plant.personal_name IS DISTINCT FROM v_name OR v_plant.display_name IS DISTINCT FROM v_name THEN
        v_watermark := public.advance_owner_watermark(p_owner_id);
        UPDATE public.plants
        SET personal_name=v_name, display_name=v_name, revision=revision+1, updated_at=v_watermark
        WHERE id=p_plant_id AND owner_id=p_owner_id RETURNING * INTO v_plant;
    END IF;
    v_result := jsonb_build_object(
        'plant_id',p_plant_id,'revision',v_plant.revision,'care_revision',v_plant.care_revision,
        'condition_snapshot_id',v_plant.current_condition_snapshot_id,'watermark',v_plant.updated_at);
    INSERT INTO public.operation_receipts(owner_id,operation_id,command_name,payload_hash,response_payload)
    VALUES (p_owner_id,p_operation_id,'plant.edit',v_hash,v_result);
    RETURN v_result;
END;
$$;

COMMIT;
