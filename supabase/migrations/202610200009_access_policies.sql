-- ============================================================================
-- Migration: 202610200009_access_policies.sql
-- Tasks: T015
-- Coverage: FR-017, FR-020, FR-041, FR-043, SC-009
-- ============================================================================

-- 1. Helper predicate: active authenticated owner
CREATE OR REPLACE FUNCTION public.is_active_owner(p_owner_id UUID)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT auth.uid() IS NOT NULL
       AND auth.uid() = p_owner_id
       AND EXISTS (
           SELECT 1
             FROM public.profiles p
            WHERE p.id = p_owner_id
              AND p.account_state = 'active'
       );
$$;

-- 2. Enable RLS across all public tables
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.operation_receipts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.source_registry ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.source_documents ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.kb_releases ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.catalogue_releases ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.catalogue_taxa ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.taxon_external_ids ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.taxon_names ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.catalogue_media ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.evidence_sources ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.care_profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.condition_profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.kb_vocabularies ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.kb_fallback_protocols ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.treatment_options ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.product_evidence ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.treatment_blocks ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.rooms ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.plants ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.guest_drafts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.condition_snapshots ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.photo_assets ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.draft_claims ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.analysis_jobs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.analysis_results ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.diagnostic_decisions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.diagnostic_answers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.care_plans ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.basic_care_memberships ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.first_aid_followups ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.task_rules ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.care_tasks ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.care_entries ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.care_reversals ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.schedule_changes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.care_observations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.recovery_transitions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.notification_claims ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.purchase_ownership ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.subscription_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.entitlements ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.installation_access ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.monthly_quotas ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.provider_daily_budget ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.deletion_jobs ENABLE ROW LEVEL SECURITY;

-- 3. Owner Read Policies (active owner only; writes go through validated server commands/RPC)
CREATE POLICY profiles_select_own ON public.profiles
    FOR SELECT USING (public.is_active_owner(id));

CREATE POLICY rooms_select_own ON public.rooms
    FOR SELECT USING (public.is_active_owner(owner_id));

CREATE POLICY plants_select_own ON public.plants
    FOR SELECT USING (public.is_active_owner(owner_id));

CREATE POLICY guest_drafts_select_own ON public.guest_drafts
    FOR SELECT USING (public.is_active_owner(guest_owner_id));

CREATE POLICY condition_snapshots_select_own ON public.condition_snapshots
    FOR SELECT USING (public.is_active_owner(owner_id));

CREATE POLICY photo_assets_select_own ON public.photo_assets
    FOR SELECT USING (public.is_active_owner(owner_id));

CREATE POLICY analysis_jobs_select_own ON public.analysis_jobs
    FOR SELECT USING (public.is_active_owner(owner_id));

CREATE POLICY analysis_results_select_own ON public.analysis_results
    FOR SELECT USING (public.is_active_owner(owner_id));

CREATE POLICY diagnostic_decisions_select_own ON public.diagnostic_decisions
    FOR SELECT USING (public.is_active_owner(owner_id));

CREATE POLICY diagnostic_answers_select_own ON public.diagnostic_answers
    FOR SELECT USING (public.is_active_owner(owner_id));

CREATE POLICY basic_care_memberships_select_own ON public.basic_care_memberships
    FOR SELECT USING (public.is_active_owner(owner_id));

CREATE POLICY first_aid_followups_select_own ON public.first_aid_followups
    FOR SELECT USING (public.is_active_owner(owner_id));

CREATE POLICY task_rules_select_own ON public.task_rules
    FOR SELECT USING (public.is_active_owner(owner_id));

CREATE POLICY care_tasks_select_own ON public.care_tasks
    FOR SELECT USING (public.is_active_owner(owner_id));

CREATE POLICY care_entries_select_own ON public.care_entries
    FOR SELECT USING (public.is_active_owner(owner_id));

CREATE POLICY care_reversals_select_own ON public.care_reversals
    FOR SELECT USING (public.is_active_owner(owner_id));

CREATE POLICY schedule_changes_select_own ON public.schedule_changes
    FOR SELECT USING (public.is_active_owner(owner_id));

CREATE POLICY care_observations_select_own ON public.care_observations
    FOR SELECT USING (public.is_active_owner(owner_id));

CREATE POLICY recovery_transitions_select_own ON public.recovery_transitions
    FOR SELECT USING (public.is_active_owner(owner_id));

CREATE POLICY notification_claims_select_own ON public.notification_claims
    FOR SELECT USING (public.is_active_owner(owner_id));

CREATE POLICY entitlements_select_own ON public.entitlements
    FOR SELECT USING (public.is_active_owner(owner_id));

CREATE POLICY monthly_quotas_select_own ON public.monthly_quotas
    FOR SELECT USING (public.is_active_owner(owner_id));

-- 4. Catalogue Public Read Policies (only published/approved records; raw Golden Records care_profiles/condition_profiles remain server-only)
CREATE POLICY kb_releases_select_published ON public.kb_releases
    FOR SELECT USING (state = 'published');

CREATE POLICY catalogue_releases_select_published ON public.catalogue_releases
    FOR SELECT USING (state = 'published');

CREATE POLICY catalogue_taxa_select_published ON public.catalogue_taxa
    FOR SELECT USING (
        status = 'published'
        AND release_id IS NOT NULL
        AND EXISTS (
            SELECT 1 FROM public.catalogue_releases cr
             WHERE cr.id = catalogue_taxa.release_id
               AND cr.state = 'published'
        )
    );

CREATE POLICY taxon_names_select_published ON public.taxon_names
    FOR SELECT USING (
        EXISTS (
            SELECT 1 FROM public.catalogue_taxa t
            JOIN public.catalogue_releases cr ON cr.id = t.release_id
             WHERE t.id = taxon_names.taxon_id
               AND t.status = 'published'
               AND cr.state = 'published'
        )
    );

CREATE POLICY catalogue_media_select_approved ON public.catalogue_media
    FOR SELECT USING (
        review_state = 'approved'
        AND EXISTS (
            SELECT 1 FROM public.catalogue_taxa t
            JOIN public.catalogue_releases cr ON cr.id = t.release_id
             WHERE t.id = catalogue_media.taxon_id
               AND t.status = 'published'
               AND cr.state = 'published'
        )
    );

CREATE POLICY treatment_blocks_select_authenticated ON public.treatment_blocks
    FOR SELECT USING (auth.uid() IS NOT NULL);

-- 5. Safe Free Projections (exclude care_plans.full_body and photo_assets storage keys from sync)
CREATE OR REPLACE VIEW public.care_plan_summaries
WITH (security_barrier = true)
AS
SELECT
    cp.id,
    cp.owner_id,
    cp.plant_id,
    cp.locale,
    cp.plan_kind,
    cp.access_tier,
    cp.source_kind,
    cp.source_analysis_id,
    cp.snapshot_id,
    cp.kb_release_id,
    cp.diagnostic_decision_id,
    cp.diagnostic_decision_revision,
    cp.treatment_start_local_date,
    cp.protocol_id,
    cp.care_profile_id,
    cp.context_revision,
    cp.version,
    cp.next_check_date,
    cp.comparison_traits,
    cp.photo_angle_hint,
    cp.state,
    cp.created_at,
    cp.updated_at,
    cp.deleted_at
FROM public.care_plans cp
WHERE public.is_active_owner(cp.owner_id);

DO $$
BEGIN
    IF current_setting('server_version_num')::int >= 150000 THEN
        EXECUTE 'ALTER VIEW public.care_plan_summaries SET (security_invoker = true)';
    END IF;
END;
$$;

-- Note: `care_plans` base table has NO direct client SELECT policy so `full_body` cannot be queried
-- directly via PostgREST free sync; owner full plan history is served via validated owner RPC/Edge API
-- which enforces safety blocks (`treatment_blocks` and `product_evidence.valid_until`) even after expiry.
