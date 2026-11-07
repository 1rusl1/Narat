-- ============================================================================
-- Migration: 202610200005_analysis_care.sql
-- Tasks: T011, T127 (analyses, decisions, plans, rules, tasks, entries, Narat memberships/aid/observations/transitions/claims)
-- Coverage: FR-005, FR-019, FR-020, FR-023–FR-030, FR-037, FR-046, FR-050, FR-054, FR-059, FR-061–FR-068
-- ============================================================================

-- 1. Analysis Jobs (stores quota reservation directly in the job row)
CREATE TABLE IF NOT EXISTS public.analysis_jobs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    owner_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    flow_id UUID NOT NULL,
    intent TEXT NOT NULL CHECK (intent IN ('problem', 'care')),
    add_method TEXT NOT NULL CHECK (add_method IN ('scan', 'catalogue')),
    draft_id UUID REFERENCES public.guest_drafts(id) ON DELETE SET NULL,
    plant_id UUID REFERENCES public.plants(id) ON DELETE SET NULL,
    mode TEXT NOT NULL
        CHECK (mode IN ('identification', 'diagnosis', 'plan', 'follow_up')),
    kb_release_id UUID NOT NULL REFERENCES public.kb_releases(id),
    schema_version TEXT NOT NULL DEFAULT '3.0',
    prompt_version TEXT NOT NULL,
    plan_source TEXT
        CHECK (plan_source IS NULL OR plan_source IN ('analysis', 'catalogue')),
    source_analysis_id UUID,
    previous_analysis_id UUID,
    operation_id UUID NOT NULL,
    payload_hash TEXT NOT NULL,
    locale TEXT NOT NULL CHECK (locale IN ('pl', 'en')),
    photo_ids UUID[] NOT NULL DEFAULT '{}'::uuid[],
    snapshot_id UUID REFERENCES public.condition_snapshots(id) ON DELETE SET NULL,
    expected_care_revision INT,
    quota_kind TEXT NOT NULL
        CHECK (quota_kind IN ('starter_identification', 'starter_diagnosis', 'free_monthly', 'paid_monthly', 'none')),
    quota_state TEXT NOT NULL
        CHECK (quota_state IN ('reserved', 'consumed', 'released', 'not_applicable')),
    quota_installation_id UUID,
    quota_owner_id UUID REFERENCES public.profiles(id) ON DELETE SET NULL,
    monthly_quota_id UUID,
    state TEXT NOT NULL DEFAULT 'queued'
        CHECK (state IN ('queued', 'running', 'succeeded', 'failed', 'timed_out')),
    lease_token UUID,
    provider_started_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    deadline_at TIMESTAMPTZ NOT NULL DEFAULT (clock_timestamp() + INTERVAL '55 seconds'),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    usage JSONB NOT NULL DEFAULT '{}'::jsonb,
    error_code TEXT,
    UNIQUE (owner_id, operation_id),
    CONSTRAINT analysis_jobs_plan_quota_none_chk
        CHECK (mode <> 'plan' OR (quota_kind = 'none' AND quota_state = 'not_applicable' AND provider_started_at IS NULL))
);

CREATE INDEX IF NOT EXISTS idx_analysis_jobs_state_deadline
    ON public.analysis_jobs (state, deadline_at);

-- Link profiles starter job pointers and guest_drafts analysis_job_id
ALTER TABLE public.profiles
    ADD CONSTRAINT fk_profiles_starter_id_job
    FOREIGN KEY (starter_identification_job_id) REFERENCES public.analysis_jobs(id) ON DELETE SET NULL;

ALTER TABLE public.profiles
    ADD CONSTRAINT fk_profiles_starter_diag_job
    FOREIGN KEY (starter_diagnosis_job_id) REFERENCES public.analysis_jobs(id) ON DELETE SET NULL;

ALTER TABLE public.guest_drafts
    ADD CONSTRAINT fk_guest_drafts_analysis_job
    FOREIGN KEY (analysis_job_id) REFERENCES public.analysis_jobs(id) ON DELETE SET NULL;

-- 2. Analysis Results (immutable source snapshot/photo, signed analysis_receipt, context_state current/stale)
CREATE TABLE IF NOT EXISTS public.analysis_results (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    origin_analysis_id UUID NOT NULL,
    mode TEXT NOT NULL
        CHECK (mode IN ('identification', 'diagnosis', 'follow_up')),
    job_id UUID NOT NULL REFERENCES public.analysis_jobs(id) ON DELETE CASCADE,
    origin_job_id UUID NOT NULL,
    owner_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    plant_id UUID REFERENCES public.plants(id) ON DELETE CASCADE,
    draft_id UUID REFERENCES public.guest_drafts(id) ON DELETE CASCADE,
    source_photo_id UUID NOT NULL REFERENCES public.photo_assets(id),
    source_snapshot_id UUID NOT NULL REFERENCES public.condition_snapshots(id),
    source_care_revision INT NOT NULL DEFAULT 1 CHECK (source_care_revision >= 1),
    locale TEXT NOT NULL CHECK (locale IN ('pl', 'en')),
    kb_release_id UUID NOT NULL REFERENCES public.kb_releases(id),
    classification JSONB NOT NULL,
    condition_candidates JSONB NOT NULL DEFAULT '[]'::jsonb,
    protocol_id UUID REFERENCES public.condition_profiles(id),
    identification JSONB NOT NULL,
    diagnosis_status TEXT
        CHECK (diagnosis_status IS NULL OR diagnosis_status IN ('problem_detected', 'healthy', 'insufficient_data', 'out_of_scope')),
    probable_cause TEXT,
    evidence_basis JSONB NOT NULL DEFAULT '{"visible_symptoms": [], "condition_factors": []}'::jsonb,
    limitations JSONB NOT NULL DEFAULT '[]'::jsonb,
    first_action JSONB,
    source_ids JSONB NOT NULL DEFAULT '[]'::jsonb,
    context_state TEXT NOT NULL DEFAULT 'current'
        CHECK (context_state IN ('current', 'stale')),
    result_hash TEXT NOT NULL,
    analysis_receipt TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    deleted_at TIMESTAMPTZ,
    CONSTRAINT analysis_results_identification_nulls_chk
        CHECK (
            mode <> 'identification'
            OR (
                diagnosis_status IS NULL
                AND probable_cause IS NULL
                AND first_action IS NULL
                AND evidence_basis = '{"visible_symptoms": [], "condition_factors": []}'::jsonb
            )
        )
);

CREATE INDEX IF NOT EXISTS idx_analysis_results_owner_sync
    ON public.analysis_results (owner_id, updated_at, id);

-- 3. Diagnostic Decisions & Answers (append-only revisions, max 2 questions, signed decision_receipt)
CREATE TABLE IF NOT EXISTS public.diagnostic_decisions (
    id UUID NOT NULL,
    revision INT NOT NULL CHECK (revision >= 1),
    origin_decision_id UUID,
    analysis_result_id UUID NOT NULL REFERENCES public.analysis_results(id) ON DELETE CASCADE,
    owner_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    kb_release_id UUID NOT NULL REFERENCES public.kb_releases(id),
    policy_version TEXT NOT NULL,
    context_revision INT NOT NULL DEFAULT 1 CHECK (context_revision >= 1),
    original_candidates JSONB NOT NULL,
    answer_snapshot_ids UUID[] NOT NULL DEFAULT '{}'::uuid[],
    decision_scores JSONB NOT NULL,
    selected_condition_id TEXT,
    state TEXT NOT NULL
        CHECK (state IN ('awaiting_answers', 'resolved', 'uncertain', 'skipped', 'stale')),
    first_action_projection JSONB,
    decision_receipt TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    deleted_at TIMESTAMPTZ,
    PRIMARY KEY (id, revision),
    CONSTRAINT diagnostic_decisions_max_questions_chk
        CHECK (coalesce(array_length(answer_snapshot_ids, 1), 0) <= 2)
);

CREATE INDEX IF NOT EXISTS idx_diagnostic_decisions_owner_sync
    ON public.diagnostic_decisions (owner_id, updated_at, id, revision DESC);

CREATE TABLE IF NOT EXISTS public.diagnostic_answers (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    decision_id UUID NOT NULL,
    question_id TEXT NOT NULL,
    answer_revision INT NOT NULL CHECK (answer_revision >= 1),
    answer TEXT NOT NULL CHECK (answer IN ('yes', 'no')),
    operation_id UUID NOT NULL,
    received_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    owner_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    deleted_at TIMESTAMPTZ,
    UNIQUE (decision_id, question_id, answer_revision),
    UNIQUE (owner_id, operation_id)
);

CREATE INDEX IF NOT EXISTS idx_diagnostic_answers_owner_sync
    ON public.diagnostic_answers (owner_id, updated_at, id);

-- 4. Care Plans (routine/recovery, basic/full access_tier, readable after expiry)
CREATE TABLE IF NOT EXISTS public.care_plans (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    job_id UUID REFERENCES public.analysis_jobs(id) ON DELETE SET NULL,
    operation_id UUID,
    owner_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    plant_id UUID NOT NULL REFERENCES public.plants(id) ON DELETE CASCADE,
    locale TEXT NOT NULL CHECK (locale IN ('pl', 'en')),
    plan_kind TEXT NOT NULL
        CHECK (plan_kind IN ('routine', 'recovery')),
    access_tier TEXT NOT NULL
        CHECK (access_tier IN ('basic', 'full')),
    attribution_flow_id UUID,
    source_kind TEXT NOT NULL
        CHECK (source_kind IN ('analysis', 'catalogue')),
    source_analysis_id UUID REFERENCES public.analysis_results(id) ON DELETE SET NULL,
    source_photo_id UUID REFERENCES public.photo_assets(id) ON DELETE SET NULL,
    snapshot_id UUID NOT NULL REFERENCES public.condition_snapshots(id),
    kb_release_id UUID NOT NULL REFERENCES public.kb_releases(id),
    diagnostic_decision_id UUID,
    diagnostic_decision_revision INT,
    treatment_start_local_date DATE,
    protocol_id UUID REFERENCES public.condition_profiles(id),
    care_profile_id UUID REFERENCES public.care_profiles(id),
    context_revision INT NOT NULL CHECK (context_revision >= 1),
    version INT NOT NULL DEFAULT 1 CHECK (version >= 1),
    full_body JSONB NOT NULL,
    next_check_date DATE,
    comparison_traits JSONB NOT NULL DEFAULT '[]'::jsonb,
    photo_angle_hint TEXT,
    state TEXT NOT NULL DEFAULT 'active'
        CHECK (state IN ('active', 'superseded')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    deleted_at TIMESTAMPTZ,
    CONSTRAINT care_plans_origin_link_chk
        CHECK (num_nonnulls(job_id, operation_id) = 1),
    CONSTRAINT care_plans_kind_source_chk
        CHECK (
            (plan_kind = 'routine' AND source_kind = 'catalogue')
            OR (plan_kind = 'recovery' AND source_kind = 'analysis' AND access_tier = 'full')
        ),
    FOREIGN KEY (diagnostic_decision_id, diagnostic_decision_revision)
        REFERENCES public.diagnostic_decisions(id, revision)
);

CREATE INDEX IF NOT EXISTS idx_care_plans_owner_sync
    ON public.care_plans (owner_id, updated_at, id);

CREATE INDEX IF NOT EXISTS idx_care_plans_plant_state
    ON public.care_plans (plant_id, access_tier, state);

-- 5. Basic Care Memberships (T127: Free basic care up to 3 selected plants, enabled_at tie-breaker)
CREATE TABLE IF NOT EXISTS public.basic_care_memberships (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    owner_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    plant_id UUID NOT NULL REFERENCES public.plants(id) ON DELETE CASCADE,
    enabled_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    enabled BOOLEAN NOT NULL DEFAULT true,
    free_slot INT CHECK (free_slot BETWEEN 1 AND 3),
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    deleted_at TIMESTAMPTZ,
    UNIQUE (owner_id, plant_id),
    CONSTRAINT basic_care_memberships_slot_requires_enabled_chk
        CHECK (free_slot IS NULL OR enabled = true)
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_basic_care_memberships_owner_free_slot
    ON public.basic_care_memberships (owner_id, free_slot)
    WHERE free_slot IS NOT NULL AND deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_basic_care_memberships_owner_sync
    ON public.basic_care_memberships (owner_id, updated_at, id);

-- 6. First Aid Followups (T127: 1 free control per origin_analysis_id, independent of 3 Free slots)
CREATE TABLE IF NOT EXISTS public.first_aid_followups (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    owner_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    plant_id UUID NOT NULL REFERENCES public.plants(id) ON DELETE CASCADE,
    origin_analysis_id UUID NOT NULL,
    decision_revision INT,
    kb_release_id UUID NOT NULL REFERENCES public.kb_releases(id),
    protocol_id UUID REFERENCES public.condition_profiles(id),
    action_code TEXT NOT NULL,
    first_action_snapshot JSONB NOT NULL,
    check_policy_snapshot JSONB NOT NULL DEFAULT '{}'::jsonb,
    action_entry_id UUID,
    control_task_id UUID,
    context_revision INT NOT NULL DEFAULT 1 CHECK (context_revision >= 1),
    state TEXT NOT NULL DEFAULT 'active'
        CHECK (state IN ('active', 'undone', 'completed', 'superseded')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    deleted_at TIMESTAMPTZ,
    UNIQUE (owner_id, plant_id, origin_analysis_id)
);

CREATE INDEX IF NOT EXISTS idx_first_aid_followups_owner_sync
    ON public.first_aid_followups (owner_id, updated_at, id);

-- 7. Task Rules (T011 + T127: access_class basic_care/first_aid_control/premium, exactly plan_id or first_aid_id)
CREATE TABLE IF NOT EXISTS public.task_rules (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    plan_id UUID REFERENCES public.care_plans(id) ON DELETE CASCADE,
    first_aid_id UUID REFERENCES public.first_aid_followups(id) ON DELETE CASCADE,
    owner_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    plant_id UUID NOT NULL REFERENCES public.plants(id) ON DELETE CASCADE,
    access_class TEXT NOT NULL
        CHECK (access_class IN ('basic_care', 'first_aid_control', 'premium')),
    rule_state TEXT NOT NULL DEFAULT 'active'
        CHECK (rule_state IN ('active', 'paused', 'superseded')),
    action_code TEXT NOT NULL,
    condition_code TEXT NOT NULL,
    interval_days INT NOT NULL CHECK (interval_days >= 0),
    algorithm_version TEXT NOT NULL DEFAULT '1.0',
    algorithm_params JSONB NOT NULL DEFAULT '{}'::jsonb,
    applied_modifiers JSONB NOT NULL DEFAULT '{}'::jsonb,
    treatment_step_id TEXT,
    start_offset_days INT NOT NULL DEFAULT 0 CHECK (start_offset_days >= 0),
    repeat_count INT NOT NULL DEFAULT 1 CHECK (repeat_count >= 1),
    repeat_index INT NOT NULL DEFAULT 0 CHECK (repeat_index >= 0),
    treatment_start_local_date DATE,
    phase TEXT,
    check_offset_days INT CHECK (check_offset_days IS NULL OR check_offset_days >= 1),
    comparison_traits JSONB NOT NULL DEFAULT '[]'::jsonb,
    photo_angle_hint TEXT,
    source_ids JSONB NOT NULL DEFAULT '[]'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    deleted_at TIMESTAMPTZ,
    CONSTRAINT task_rules_single_origin_chk
        CHECK (num_nonnulls(plan_id, first_aid_id) = 1),
    CONSTRAINT task_rules_first_aid_class_chk
        CHECK (
            (first_aid_id IS NOT NULL AND access_class = 'first_aid_control' AND repeat_count = 1)
            OR (plan_id IS NOT NULL AND access_class IN ('basic_care', 'premium'))
        ),
    CONSTRAINT task_rules_repeat_interval_chk
        CHECK (repeat_count = 1 OR interval_days >= 1)
);

CREATE INDEX IF NOT EXISTS idx_task_rules_plant_state
    ON public.task_rules (plant_id, access_class, rule_state);

-- 8. Care Tasks (T011 + T127: reminder_eligible, inactive_reason, needs_review, check_soil_first)
CREATE TABLE IF NOT EXISTS public.care_tasks (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    owner_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    plant_id UUID NOT NULL REFERENCES public.plants(id) ON DELETE CASCADE,
    rule_id UUID REFERENCES public.task_rules(id) ON DELETE SET NULL,
    occurrence_key TEXT NOT NULL,
    action_code TEXT NOT NULL,
    due_local_date DATE NOT NULL,
    timezone TEXT NOT NULL DEFAULT 'Europe/Warsaw',
    condition_code TEXT NOT NULL DEFAULT 'check_soil_first',
    reminder_eligible BOOLEAN NOT NULL DEFAULT true,
    inactive_reason TEXT
        CHECK (
            inactive_reason IS NULL
            OR inactive_reason IN ('free_slot_removed', 'first_action_undone', 'plan_superseded', 'completed')
        ),
    localized_reason_snapshot JSONB NOT NULL DEFAULT '{}'::jsonb,
    comparison_traits JSONB NOT NULL DEFAULT '[]'::jsonb,
    photo_angle_hint TEXT,
    state TEXT NOT NULL DEFAULT 'open'
        CHECK (state IN ('open', 'completed', 'superseded', 'needs_review')),
    revision INT NOT NULL DEFAULT 1 CHECK (revision >= 1),
    completed_entry_id UUID,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    deleted_at TIMESTAMPTZ,
    UNIQUE (plant_id, occurrence_key)
);

CREATE INDEX IF NOT EXISTS idx_care_tasks_owner_sync
    ON public.care_tasks (owner_id, updated_at, id);

CREATE INDEX IF NOT EXISTS idx_care_tasks_plant_state_due
    ON public.care_tasks (plant_id, state, due_local_date);

-- 9. Care Entries (recorded care facts; future dates rejected by command handler & CHECK)
CREATE TABLE IF NOT EXISTS public.care_entries (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    owner_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    plant_id UUID NOT NULL REFERENCES public.plants(id) ON DELETE CASCADE,
    task_id UUID REFERENCES public.care_tasks(id) ON DELETE SET NULL,
    action_code TEXT NOT NULL,
    occurred_at TIMESTAMPTZ NOT NULL,
    occurred_local_date DATE NOT NULL,
    timezone TEXT NOT NULL,
    recorded_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    state TEXT NOT NULL DEFAULT 'active'
        CHECK (state IN ('active', 'voided')),
    operation_id UUID NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    deleted_at TIMESTAMPTZ
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_care_entries_one_active_per_task
    ON public.care_entries (task_id)
    WHERE state = 'active' AND task_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_care_entries_owner_sync
    ON public.care_entries (owner_id, updated_at, id);

CREATE INDEX IF NOT EXISTS idx_care_entries_plant_date
    ON public.care_entries (plant_id, state, occurred_local_date DESC, occurred_at DESC);

ALTER TABLE public.care_tasks
    ADD CONSTRAINT fk_care_tasks_completed_entry
    FOREIGN KEY (completed_entry_id) REFERENCES public.care_entries(id) ON DELETE SET NULL;

ALTER TABLE public.first_aid_followups
    ADD CONSTRAINT fk_first_aid_followups_action_entry
    FOREIGN KEY (action_entry_id) REFERENCES public.care_entries(id) ON DELETE SET NULL;

ALTER TABLE public.first_aid_followups
    ADD CONSTRAINT fk_first_aid_followups_control_task
    FOREIGN KEY (control_task_id) REFERENCES public.care_tasks(id) ON DELETE SET NULL;

-- 10. Care Reversals (undo history preserved without deleting care_entries)
CREATE TABLE IF NOT EXISTS public.care_reversals (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    owner_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    entry_id UUID NOT NULL UNIQUE REFERENCES public.care_entries(id) ON DELETE CASCADE,
    operation_id UUID NOT NULL,
    recorded_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    deleted_at TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_care_reversals_owner_sync
    ON public.care_reversals (owner_id, updated_at, id);

-- 11. Schedule Changes (explainable date shifts FR-029)
CREATE TABLE IF NOT EXISTS public.schedule_changes (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    owner_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    plant_id UUID NOT NULL REFERENCES public.plants(id) ON DELETE CASCADE,
    from_date DATE,
    to_date DATE NOT NULL,
    cause_code TEXT NOT NULL,
    source_event_id UUID,
    explanation_code TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    deleted_at TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_schedule_changes_owner_sync
    ON public.schedule_changes (owner_id, updated_at, id);

-- 12. Care Observations (T127: personal control check observation & optional own photo without AI)
CREATE TABLE IF NOT EXISTS public.care_observations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    owner_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    plant_id UUID NOT NULL REFERENCES public.plants(id) ON DELETE CASCADE,
    task_id UUID REFERENCES public.care_tasks(id) ON DELETE SET NULL,
    status_code TEXT NOT NULL
        CHECK (status_code IN ('improved', 'unchanged', 'worse', 'unknown')),
    note TEXT,
    photo_id UUID REFERENCES public.photo_assets(id) ON DELETE SET NULL,
    observed_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    operation_id UUID NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    deleted_at TIMESTAMPTZ,
    UNIQUE (owner_id, operation_id)
);

CREATE INDEX IF NOT EXISTS idx_care_observations_owner_sync
    ON public.care_observations (owner_id, updated_at, id);

-- 13. Recovery Transitions (T127: explicit transition from recovery to basic care FR-067)
CREATE TABLE IF NOT EXISTS public.recovery_transitions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    owner_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    plant_id UUID NOT NULL REFERENCES public.plants(id) ON DELETE CASCADE,
    recovery_plan_id UUID NOT NULL REFERENCES public.care_plans(id) ON DELETE CASCADE,
    observation_id UUID NOT NULL REFERENCES public.care_observations(id) ON DELETE RESTRICT,
    expected_care_revision INT NOT NULL CHECK (expected_care_revision >= 1),
    operation_id UUID NOT NULL,
    state TEXT NOT NULL
        CHECK (state IN ('explicit_requested', 'confirmed', 'reassessment_required')),
    routine_plan_id UUID REFERENCES public.care_plans(id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    deleted_at TIMESTAMPTZ,
    UNIQUE (owner_id, operation_id)
);

CREATE INDEX IF NOT EXISTS idx_recovery_transitions_owner_sync
    ON public.recovery_transitions (owner_id, updated_at, id);

-- 14. Notification Claims (T127: deduplicated progress_report YYYY-MM without timezone & trial_end)
CREATE TABLE IF NOT EXISTS public.notification_claims (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    owner_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    kind TEXT NOT NULL
        CHECK (kind IN ('progress_report', 'trial_end')),
    period_key TEXT NOT NULL,
    installation_id UUID NOT NULL,
    scheduled_at TIMESTAMPTZ NOT NULL,
    state TEXT NOT NULL DEFAULT 'reserved'
        CHECK (state IN ('reserved', 'scheduled', 'cancelled')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    deleted_at TIMESTAMPTZ,
    UNIQUE (owner_id, kind, period_key),
    CONSTRAINT notification_claims_report_period_format_chk
        CHECK (kind <> 'progress_report' OR period_key ~ '^\d{4}-(0[1-9]|1[0-2])$')
);

CREATE INDEX IF NOT EXISTS idx_notification_claims_owner_sync
    ON public.notification_claims (owner_id, updated_at, id);
