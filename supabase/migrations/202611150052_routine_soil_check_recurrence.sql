BEGIN;

-- A read-only factual anchor shared by the projection and the private writer.
-- A watering fact is still required: a check alone cannot activate routine care.
CREATE FUNCTION public.resolve_routine_soil_check(p_owner_id UUID, p_plant_id UUID)
RETURNS JSONB LANGUAGE SQL STABLE SECURITY DEFINER SET search_path = '' AS $$
    WITH current_rule AS (
        SELECT rule.id, rule.interval_days, p.care_revision
        FROM public.plants p
        JOIN public.profiles owner ON owner.id=p.owner_id
            AND owner.account_state='active' AND NOT owner.anonymous
        JOIN public.condition_snapshots s ON s.id=p.current_condition_snapshot_id
            AND s.owner_id=p.owner_id AND s.plant_id=p.id AND s.deleted_at IS NULL
        JOIN public.catalogue_taxa t ON t.id=p.taxon_id AND t.status='published'
            AND t.plant_id=p.plant_id
        JOIN public.catalogue_releases release ON release.id=t.release_id AND release.state='published'
        JOIN public.kb_releases kb ON kb.state='published'
        JOIN public.care_profiles c ON c.taxon_id=t.id AND c.kb_release_id=kb.id
            AND c.state='published' AND c.profile->>'plant_id'=t.plant_id
            AND c.profile->>'kb_release_id'=kb.id::text
        JOIN public.care_plans plan ON plan.owner_id=p.owner_id AND plan.plant_id=p.id
            AND plan.snapshot_id=s.id AND plan.context_revision=p.care_revision
            AND plan.care_profile_id=c.id AND plan.plan_kind='routine'
            AND plan.access_tier='basic' AND plan.state='active' AND plan.deleted_at IS NULL
        JOIN public.task_rules rule ON rule.plan_id=plan.id AND rule.owner_id=p.owner_id
            AND rule.plant_id=p.id AND rule.access_class='basic_care'
            AND rule.action_code='check_soil' AND rule.condition_code='check_soil_first'
            AND rule.rule_state='active' AND rule.deleted_at IS NULL
        CROSS JOIN LATERAL (
            SELECT a.value->>'action_id' AS action_id,
                a.value->'next_check_interval_days' AS interval_days,
                proof.action_source, proof.interval_source, proof.applicability_source
            FROM jsonb_array_elements(CASE WHEN jsonb_typeof(c.profile->'actions')='array'
                THEN c.profile->'actions' ELSE '[]'::jsonb END) WITH ORDINALITY a(value,position)
            CROSS JOIN LATERAL (
                SELECT public.first_aid_approved_source(c.profile->'provenance',
                        '/actions/'||(a.position-1)) AS action_source,
                    public.first_aid_approved_source(c.profile->'provenance',
                        '/actions/'||(a.position-1)||'/next_check_interval_days') AS interval_source,
                    public.first_aid_approved_source(c.profile->'provenance',
                        '/actions/'||(a.position-1)||'/refresh_conditions') AS applicability_source
            ) proof
            WHERE a.value->>'action_code'='check_soil' AND a.value->>'purpose'='routine_care'
                AND a.value->>'action_id' ~ '^[a-z][a-z0-9_]*$'
                AND a.value->'prerequisite_check_ids'='[]'::jsonb
                AND a.value->'contraindication_check_ids'='[]'::jsonb
                AND coalesce(a.value->'active_ingredients','[]'::jsonb)='[]'::jsonb
                AND jsonb_typeof(a.value->'next_check_interval_days')='number'
                AND a.value->>'next_check_interval_days' ~ '^([1-9]|[1-8][0-9]|90)$'
                AND c.validation_report->'refresh_conditions'->(a.value->>'action_id')=
                    jsonb_build_object('light_code',s.light_code,'light_source',s.light_source,
                        'light_confirmed',s.light_confirmed,'watering_code',s.watering_code,
                        'drainage_code',s.drainage_code,'pot_type',s.pot_type)
                AND proof.action_source IS NOT NULL AND proof.interval_source IS NOT NULL
                AND proof.applicability_source IS NOT NULL
            ORDER BY a.position LIMIT 1
        ) action
        WHERE p.id=p_plant_id AND p.owner_id=p_owner_id AND p.deleted_at IS NULL
            AND to_jsonb(rule.interval_days)=action.interval_days
            AND plan.full_body=jsonb_build_object('refresh_evidence',jsonb_build_object(
                'snapshot_id',s.id,'care_revision',p.care_revision,'profile_id',c.id,
                'action_id',action.action_id,'interval_days',action.interval_days,
                'action_source',action.action_source,'interval_source',action.interval_source,
                'applicability_source',action.applicability_source))
            AND EXISTS (SELECT 1 FROM public.basic_care_memberships m
                WHERE m.owner_id=p.owner_id AND m.plant_id=p.id AND m.enabled AND m.deleted_at IS NULL)
            AND (NOT EXISTS (SELECT 1 FROM public.entitlements e WHERE e.owner_id=p.owner_id)
                OR public.has_verified_paid_access(p.owner_id,statement_timestamp()))
        ORDER BY rule.created_at DESC,rule.id DESC LIMIT 1
    ), watering AS (
        SELECT e.*
        FROM public.care_entries e
        WHERE e.owner_id=p_owner_id AND e.plant_id=p_plant_id
            AND e.action_code='water' AND e.state='active' AND e.deleted_at IS NULL
            AND e.first_aid_job_id IS NULL AND isfinite(e.occurred_at)
            AND isfinite(e.occurred_local_date) AND e.occurred_at<=statement_timestamp()
            AND (e.task_id IS NULL OR EXISTS (
                SELECT 1 FROM public.care_tasks task
                JOIN public.task_rules rule ON rule.id=task.rule_id
                    AND rule.owner_id=task.owner_id AND rule.plant_id=task.plant_id
                    AND rule.first_aid_id IS NULL
                JOIN public.care_plans plan ON plan.id=rule.plan_id
                    AND plan.owner_id=rule.owner_id AND plan.plant_id=rule.plant_id
                    AND plan.plan_kind='routine'
                    AND plan.context_revision=(SELECT care_revision FROM current_rule)
                WHERE task.id=e.task_id AND task.owner_id=e.owner_id AND task.plant_id=e.plant_id
                    AND task.deleted_at IS NULL))
        ORDER BY e.occurred_at DESC,e.recorded_at DESC,e.id DESC LIMIT 1
    )
    SELECT jsonb_build_object('rule_id',r.id,'care_revision',r.care_revision,
        'due_local_date',anchor.occurred_local_date+r.interval_days,
        'anchor_local_date',anchor.occurred_local_date,'anchor_kind',anchor.action_code)
    FROM current_rule r CROSS JOIN watering
    CROSS JOIN LATERAL (
        SELECT facts.* FROM (
            SELECT watering.id,watering.occurred_at,watering.recorded_at,
                watering.occurred_local_date,watering.action_code
            UNION ALL
            SELECT e.id,e.occurred_at,e.recorded_at,e.occurred_local_date,e.action_code
            FROM public.care_entries e JOIN public.care_tasks task ON task.id=e.task_id
                AND task.owner_id=e.owner_id AND task.plant_id=e.plant_id
                AND task.completed_entry_id=e.id AND task.rule_id=r.id
                AND task.state='completed' AND task.deleted_at IS NULL
                AND task.action_code='check_soil'
            WHERE e.owner_id=p_owner_id AND e.plant_id=p_plant_id AND e.action_code='check_soil'
                AND e.first_aid_job_id IS NULL AND e.state='active' AND e.deleted_at IS NULL
                AND isfinite(e.occurred_at) AND isfinite(e.occurred_local_date)
                AND e.occurred_at<=statement_timestamp()
        ) facts ORDER BY occurred_at DESC,recorded_at DESC,id DESC LIMIT 1
    ) anchor
$$;
REVOKE ALL ON FUNCTION public.resolve_routine_soil_check(UUID,UUID)
    FROM PUBLIC,anon,authenticated,service_role;

-- Retain the accepted 050 projection, including its legacy calendar semantics.
ALTER FUNCTION public.read_plant_care_profile(UUID,UUID) RENAME TO read_plant_care_profile_050;
REVOKE ALL ON FUNCTION public.read_plant_care_profile_050(UUID,UUID)
    FROM PUBLIC,anon,authenticated,service_role;
CREATE FUNCTION public.read_plant_care_profile(p_owner_id UUID, p_plant_id UUID)
RETURNS JSONB LANGUAGE SQL STABLE SECURITY DEFINER SET search_path = '' AS $$
    WITH profile AS (
        SELECT public.read_plant_care_profile_050(p_owner_id,p_plant_id) AS body
    ), routine AS (
        SELECT public.resolve_routine_soil_check(p_owner_id,p_plant_id) AS body
    )
    SELECT profile.body || CASE
        WHEN profile.body->'calendar_eligible'='true'::jsonb AND routine.body IS NOT NULL
        THEN jsonb_build_object('routine_check',routine.body) ELSE '{}'::jsonb END
    FROM profile CROSS JOIN routine
$$;
REVOKE ALL ON FUNCTION public.read_plant_care_profile(UUID,UUID) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.read_plant_care_profile(UUID,UUID) TO service_role;

-- Change only the private 051 due validation. Receipt lookup remains before this
-- resolution, so an exact replay survives advancement and source withdrawal.
DO $migration$
DECLARE
    definition TEXT;
    old_validation TEXT := $old$    v_due := (v_candidate->>'anchor_on')::date+(v_candidate->>'interval_days')::int;
    IF p_due_local_date<>v_due THEN$old$;
    new_validation TEXT := $new$    SELECT (routine->>'due_local_date')::date INTO v_due
    FROM (SELECT public.resolve_routine_soil_check(p_owner_id,p_plant_id) AS routine) resolved
    WHERE (routine->>'rule_id')::uuid=p_rule_id
      AND (routine->>'care_revision')::int=p_expected_care_revision;
    IF v_due IS NULL THEN
        RAISE EXCEPTION 'ROUTINE_SOIL_CHECK_UNAVAILABLE' USING ERRCODE='55000';
    END IF;
    IF p_due_local_date<>v_due THEN$new$;
BEGIN
    definition := pg_get_functiondef(
        'public.execute_routine_soil_check(uuid,uuid,uuid,integer,uuid,date,timestamptz,text)'::regprocedure);
    IF position(old_validation IN definition)=0 THEN
        RAISE EXCEPTION 'Unexpected 051 routine soil check implementation';
    END IF;
    EXECUTE replace(definition,old_validation,new_validation);
END;
$migration$;

COMMIT;
