BEGIN;

-- Runtime is shared by identification and diagnosis. Retain its replay/catalogue
-- anchors; the permanent operation marker prevents later context rehydration.
ALTER TABLE public.diagnosis_job_runtime
    ADD COLUMN account_deletion_operation_id UUID,
    ADD CONSTRAINT diagnosis_runtime_scrubbed_context CHECK (
        account_deletion_operation_id IS NULL OR
        (projection IS NULL AND repeat_context IS NULL AND initial_context IS NULL)
    );

CREATE FUNCTION public.guard_account_deleted_diagnosis_runtime()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
    v_owner UUID;
    v_job public.analysis_jobs%ROWTYPE;
BEGIN
    IF TG_OP='DELETE' THEN
        IF OLD.account_deletion_operation_id IS NOT NULL THEN
            RAISE EXCEPTION 'IMMUTABLE_RUNTIME_SCRUB' USING ERRCODE='22023';
        END IF;
        RETURN OLD;
    END IF;
    IF TG_OP='UPDATE' THEN
        IF NEW.job_id IS DISTINCT FROM OLD.job_id THEN
            RAISE EXCEPTION 'IMMUTABLE_RUNTIME_JOB' USING ERRCODE='22023';
        END IF;
        IF OLD.account_deletion_operation_id IS NOT NULL AND
            NEW.account_deletion_operation_id IS DISTINCT FROM OLD.account_deletion_operation_id THEN
            RAISE EXCEPTION 'IMMUTABLE_RUNTIME_SCRUB' USING ERRCODE='22023';
        END IF;
    END IF;
    -- Preserve ordinary worker concurrency. Only the first controlled scrub
    -- needs profile/job validation. After a scrub, row constraints and the
    -- immutable marker protect the context without additional locks.
    IF NEW.account_deletion_operation_id IS NULL THEN RETURN NEW; END IF;
    IF NEW.projection IS NOT NULL OR NEW.repeat_context IS NOT NULL OR NEW.initial_context IS NOT NULL THEN
        RAISE EXCEPTION 'ACCOUNT_RUNTIME_SCRUBBED' USING ERRCODE='22023';
    END IF;
    IF TG_OP='INSERT' THEN
        RAISE EXCEPTION 'INVALID_RUNTIME_SCRUB_INSERT' USING ERRCODE='22023';
    END IF;
    IF OLD.account_deletion_operation_id IS NOT NULL THEN RETURN NEW; END IF;

    SELECT owner_id INTO v_owner FROM public.analysis_jobs WHERE id=NEW.job_id;
    -- The scrub entry point already holds these locks in this order.
    PERFORM 1 FROM public.profiles WHERE id=v_owner FOR UPDATE;
    SELECT * INTO v_job FROM public.analysis_jobs
        WHERE id=NEW.job_id AND owner_id=v_owner FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'RUNTIME_JOB_NOT_FOUND' USING ERRCODE='22023';
    END IF;
    IF v_job.state NOT IN ('succeeded','failed','timed_out')
        OR v_job.mode NOT IN ('diagnosis','identification')
        OR NOT (v_job.quota_state IN ('consumed','released') OR
            (v_job.quota_kind='none' AND v_job.quota_state='not_applicable'))
        OR public.verify_account_deletion_storage_internal(
            v_owner,NEW.account_deletion_operation_id) IS NULL THEN
        RAISE EXCEPTION 'INVALID_RUNTIME_SCRUB' USING ERRCODE='22023';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER account_deleted_diagnosis_runtime
BEFORE INSERT OR UPDATE OR DELETE ON public.diagnosis_job_runtime
FOR EACH ROW EXECUTE FUNCTION public.guard_account_deleted_diagnosis_runtime();

-- Keep ordinary initial-input immutability. The earlier alphabetic trigger
-- validates the only exception: an authenticated terminal-owner scrub marker.
CREATE OR REPLACE FUNCTION public.preserve_initial_diagnosis_context()
RETURNS trigger LANGUAGE plpgsql SET search_path = '' AS $$
BEGIN
    IF OLD.initial_context IS NOT NULL AND NEW.initial_context IS DISTINCT FROM OLD.initial_context
        AND NOT (NEW.account_deletion_operation_id IS NOT NULL AND
            NEW.initial_context IS NULL AND NEW.repeat_context IS NULL AND NEW.projection IS NULL) THEN
        RAISE EXCEPTION 'IMMUTABLE_INITIAL_CONTEXT' USING ERRCODE='22023';
    END IF;
    RETURN NEW;
END;
$$;

CREATE FUNCTION public.purge_account_deletion_diagnosis_runtime_internal(
    p_owner_id UUID, p_operation_id UUID
) RETURNS BOOLEAN
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
    v_ids UUID[];
BEGIN
    PERFORM 1 FROM public.profiles WHERE id=p_owner_id FOR UPDATE;
    IF public.verify_account_deletion_storage_internal(p_owner_id,p_operation_id) IS NULL THEN
        RAISE EXCEPTION 'storage verification' USING ERRCODE='P1618';
    END IF;
    PERFORM j.id FROM public.analysis_jobs j
        JOIN public.diagnosis_job_runtime r ON r.job_id=j.id
        WHERE j.owner_id=p_owner_id ORDER BY j.id FOR UPDATE OF j;
    SELECT coalesce(array_agg(j.id ORDER BY j.id),'{}'::uuid[]) INTO v_ids
        FROM public.analysis_jobs j JOIN public.diagnosis_job_runtime r ON r.job_id=j.id
        WHERE j.owner_id=p_owner_id;
    -- Terminal jobs may retain lease tokens; settlement intentionally keeps
    -- these for exact worker replay. Reserved/unknown settlement is a hold.
    IF EXISTS (SELECT 1 FROM public.analysis_jobs j
        JOIN public.diagnosis_job_runtime r ON r.job_id=j.id
        WHERE j.id=ANY(v_ids) AND (
            j.state NOT IN ('succeeded','failed','timed_out')
            OR j.mode NOT IN ('diagnosis','identification')
            OR NOT (j.quota_state IN ('consumed','released') OR
                (j.quota_kind='none' AND j.quota_state='not_applicable'))
            OR (r.account_deletion_operation_id IS NOT NULL
                AND r.account_deletion_operation_id IS DISTINCT FROM p_operation_id)
            OR EXISTS (SELECT 1 FROM public.plants p
                WHERE p.id::text=r.repeat_context->>'target_plant_id'
                    AND p.owner_id IS DISTINCT FROM p_owner_id))) THEN
        RAISE EXCEPTION 'active, unknown or foreign runtime' USING ERRCODE='P1618';
    END IF;
    IF EXISTS (SELECT 1 FROM public.account_quota_usage u
        JOIN public.analysis_jobs j ON j.id=u.job_id
        WHERE j.id=ANY(v_ids) AND (u.owner_id IS DISTINCT FROM p_owner_id
            OR u.quota_state IS DISTINCT FROM j.quota_state)) THEN
        RAISE EXCEPTION 'unknown or foreign settlement' USING ERRCODE='P1618';
    END IF;
    -- Exact preceding accepted phases (017 -> 014 -> 013 -> ...), not a
    -- timestamp or an independently guessed readiness test.
    IF NOT public.purge_account_deletion_guest_drafts_internal(p_owner_id,p_operation_id) THEN
        RAISE EXCEPTION 'guest draft predecessor (017)' USING ERRCODE='P1618';
    END IF;
    UPDATE public.diagnosis_job_runtime SET projection=NULL,repeat_context=NULL,
        initial_context=NULL,account_deletion_operation_id=p_operation_id
        WHERE job_id=ANY(v_ids) AND account_deletion_operation_id IS NULL;
    RETURN true;
EXCEPTION WHEN SQLSTATE 'P1618' THEN
    -- Includes fresh verification and all predecessors in the rollback.
    RETURN false;
END;
$$;

-- Strip inherited default grants as well as the standard application roles.
DO $$
DECLARE v_role TEXT; v_function TEXT;
BEGIN
    FOREACH v_function IN ARRAY ARRAY[
        'public.guard_account_deleted_diagnosis_runtime()',
        'public.purge_account_deletion_diagnosis_runtime_internal(uuid,uuid)']
    LOOP
        FOR v_role IN
            SELECT DISTINCT CASE WHEN a.grantee=0 THEN 'PUBLIC' ELSE quote_ident(r.rolname) END
            FROM pg_proc p
            CROSS JOIN LATERAL aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) a
            LEFT JOIN pg_roles r ON r.oid=a.grantee
            WHERE p.oid=v_function::regprocedure AND a.grantee<>p.proowner
        LOOP
            EXECUTE 'REVOKE ALL ON FUNCTION '||v_function||' FROM '||v_role;
        END LOOP;
    END LOOP;
END $$;

COMMIT;
