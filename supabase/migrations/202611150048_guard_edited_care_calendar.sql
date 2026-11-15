BEGIN;

CREATE OR REPLACE FUNCTION public.read_plant_care_profile(p_owner_id UUID, p_plant_id UUID)
RETURNS JSONB LANGUAGE SQL STABLE SECURITY DEFINER SET search_path = '' AS $$
    SELECT jsonb_build_object('plant_id', p.id, 'plant_slug', t.plant_id,
        'kb_release_id', k.id, 'profile', c.profile,
        'calendar_eligible',
            (NOT EXISTS (SELECT 1 FROM public.entitlements e WHERE e.owner_id = p.owner_id)
                OR public.has_verified_paid_access(p.owner_id, statement_timestamp()))
            AND NOT EXISTS (
                SELECT 1 FROM public.basic_care_memberships m
                WHERE m.owner_id = p.owner_id AND m.plant_id = p.id
                  AND m.deleted_at IS NULL AND NOT m.enabled
            )
            AND NOT EXISTS (
                SELECT 1 FROM public.task_rules rule
                WHERE rule.owner_id = p.owner_id AND rule.plant_id = p.id
                  AND rule.access_class = 'basic_care' AND rule.action_code = 'check_soil'
                  AND rule.rule_state = 'paused' AND rule.deleted_at IS NULL
            )
            -- Earlier GETs could show a date from the journal without a stored rule to pause.
            -- Once conditions change, only a refresh for the current context can restore it.
            AND (p.care_revision = 1 OR EXISTS (
                SELECT 1
                FROM public.task_rules rule
                JOIN public.care_plans plan ON plan.id = rule.plan_id
                    AND plan.owner_id = rule.owner_id AND plan.plant_id = rule.plant_id
                WHERE rule.owner_id = p.owner_id AND rule.plant_id = p.id
                  AND rule.access_class = 'basic_care' AND rule.action_code = 'check_soil'
                  AND rule.rule_state = 'active' AND rule.deleted_at IS NULL
                  AND plan.state = 'active' AND plan.deleted_at IS NULL
                  AND plan.snapshot_id = p.current_condition_snapshot_id
                  AND plan.context_revision = p.care_revision
                  AND plan.care_profile_id = c.id
                  AND plan.full_body ? 'refresh_evidence'
            )),
        'last_watered_on', (
            SELECT e.occurred_local_date FROM public.care_entries e
            WHERE e.owner_id = p.owner_id AND e.plant_id = p.id
              AND e.action_code = 'water' AND e.state = 'active' AND e.deleted_at IS NULL
              AND e.occurred_at <= statement_timestamp()
            ORDER BY e.occurred_at DESC, e.recorded_at DESC, e.id DESC
            LIMIT 1
        ))
    FROM public.plants p
    JOIN public.profiles o ON o.id = p.owner_id AND o.account_state = 'active' AND NOT o.anonymous
    LEFT JOIN public.catalogue_taxa t ON t.id = p.taxon_id AND t.status = 'published'
    LEFT JOIN public.catalogue_releases r ON r.id = t.release_id AND r.state = 'published'
    LEFT JOIN public.kb_releases k ON k.state = 'published'
    LEFT JOIN public.care_profiles c ON c.taxon_id = t.id AND c.kb_release_id = k.id
        AND c.state = 'published' AND r.id IS NOT NULL
    WHERE p.id = p_plant_id AND p.owner_id = p_owner_id AND p.deleted_at IS NULL
$$;

COMMIT;
