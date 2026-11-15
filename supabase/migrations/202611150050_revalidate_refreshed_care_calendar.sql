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
            AND (
                (p.care_revision = 1 AND NOT EXISTS (
                    SELECT 1 FROM public.care_plans historical
                    WHERE historical.owner_id = p.owner_id AND historical.plant_id = p.id
                      AND historical.context_revision = p.care_revision AND historical.deleted_at IS NULL
                      AND historical.full_body ? 'refresh_evidence'
                )) OR EXISTS (
                    SELECT 1
                    FROM public.task_rules rule
                    JOIN public.care_plans plan ON plan.id = rule.plan_id
                        AND plan.owner_id = rule.owner_id AND plan.plant_id = rule.plant_id
                    JOIN public.condition_snapshots snapshot ON snapshot.id = plan.snapshot_id
                        AND snapshot.owner_id = plan.owner_id AND snapshot.plant_id = plan.plant_id
                        AND snapshot.deleted_at IS NULL
                    CROSS JOIN LATERAL (
                        SELECT item.value->>'action_id' AS action_id,
                            item.value->'next_check_interval_days' AS interval_days,
                            '/actions/' || (item.position - 1) AS evidence_path
                        FROM jsonb_array_elements(
                            CASE WHEN jsonb_typeof(c.profile->'actions') = 'array' THEN c.profile->'actions'
                            ELSE '[]'::jsonb END
                        ) WITH ORDINALITY item(value, position)
                        WHERE item.value->>'action_code' = 'check_soil'
                          AND item.value->>'purpose' = 'routine_care'
                          AND item.value->'prerequisite_check_ids' = '[]'::jsonb
                          AND item.value->'contraindication_check_ids' = '[]'::jsonb
                          AND coalesce(item.value->'active_ingredients', '[]'::jsonb) = '[]'::jsonb
                        ORDER BY item.position
                        LIMIT 1
                    ) action
                    WHERE rule.owner_id = p.owner_id AND rule.plant_id = p.id
                      AND rule.access_class = 'basic_care' AND rule.action_code = 'check_soil'
                      AND rule.rule_state = 'active' AND rule.deleted_at IS NULL
                      AND plan.state = 'active' AND plan.deleted_at IS NULL
                      AND plan.snapshot_id = p.current_condition_snapshot_id
                      AND plan.context_revision = p.care_revision
                      AND plan.care_profile_id = c.id
                      AND EXISTS (
                          SELECT 1 FROM public.basic_care_memberships membership
                          WHERE membership.owner_id = p.owner_id AND membership.plant_id = p.id
                            AND membership.enabled AND membership.deleted_at IS NULL
                      )
                      AND plan.full_body ? 'refresh_evidence'
                      AND plan.full_body#>>'{refresh_evidence,action_id}' = action.action_id
                      AND to_jsonb(rule.interval_days) = action.interval_days
                      AND c.validation_report->'refresh_conditions'->action.action_id =
                          jsonb_build_object('light_code',snapshot.light_code,'light_source',snapshot.light_source,
                              'light_confirmed',snapshot.light_confirmed,'watering_code',snapshot.watering_code,
                              'drainage_code',snapshot.drainage_code,'pot_type',snapshot.pot_type)
                      AND public.first_aid_approved_source(c.profile->'provenance', action.evidence_path)
                          = plan.full_body#>'{refresh_evidence,action_source}'
                      AND public.first_aid_approved_source(c.profile->'provenance', action.evidence_path || '/next_check_interval_days')
                          = plan.full_body#>'{refresh_evidence,interval_source}'
                      AND public.first_aid_approved_source(c.profile->'provenance', action.evidence_path || '/refresh_conditions')
                          = plan.full_body#>'{refresh_evidence,applicability_source}'
                )
            ),
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
