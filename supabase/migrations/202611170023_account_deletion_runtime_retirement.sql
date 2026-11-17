BEGIN;

-- A private capability valid only inside the fresh 021 retirement transaction.
CREATE TABLE public.account_deletion_runtime_permits (
    transaction_id xid8 NOT NULL,
    job_id uuid NOT NULL,
    owner_id uuid NOT NULL,
    operation_id uuid NOT NULL
);
ALTER TABLE public.account_deletion_runtime_permits
    ADD PRIMARY KEY(transaction_id,job_id,owner_id,operation_id);
ALTER TABLE public.account_deletion_runtime_permits ENABLE ROW LEVEL SECURITY;

-- Preserve the original guard's owner, configuration and grants.
DO $rewrite$
DECLARE
    v_definition text := pg_get_functiondef(
        'public.guard_account_deleted_diagnosis_runtime()'::regprocedure);
BEGIN
    v_definition:=replace(v_definition,'FOR UPDATE;','FOR UPDATE NOWAIT;');
    IF strpos(v_definition,$old$BEGIN
    IF TG_OP='DELETE' THEN$old$)=0 OR
       strpos(v_definition,$old$        IF OLD.account_deletion_operation_id IS NOT NULL THEN
            RAISE EXCEPTION 'IMMUTABLE_RUNTIME_SCRUB'$old$)=0 THEN
        RAISE EXCEPTION '023 expected original 018 runtime guard';
    END IF;
    v_definition:=replace(v_definition,$old$BEGIN
    IF TG_OP='DELETE' THEN$old$,$new$BEGIN
    IF TG_OP<>'DELETE' THEN
        SELECT owner_id INTO v_owner FROM public.analysis_jobs WHERE id=NEW.job_id;
        -- DML already holds a runtime row. Never wait in reverse lock order.
        PERFORM 1 FROM public.profiles WHERE id=v_owner FOR UPDATE NOWAIT;
        PERFORM 1 FROM public.analysis_jobs WHERE id=NEW.job_id FOR UPDATE NOWAIT;
        IF EXISTS (SELECT 1 FROM public.account_deleted_runtime_identities
            WHERE job_id=NEW.job_id) THEN
            RAISE EXCEPTION 'RETIRED_RUNTIME' USING ERRCODE='22023';
        END IF;
    END IF;
    IF TG_OP='DELETE' THEN$new$);
    v_definition:=replace(v_definition,$old$        IF OLD.account_deletion_operation_id IS NOT NULL THEN
            RAISE EXCEPTION 'IMMUTABLE_RUNTIME_SCRUB'$old$,$new$        IF OLD.account_deletion_operation_id IS NOT NULL THEN
            IF OLD.projection IS NULL AND OLD.repeat_context IS NULL AND OLD.initial_context IS NULL
                AND EXISTS (
                    SELECT 1 FROM public.account_deleted_runtime_identities t
                    JOIN public.account_deletion_runtime_permits p
                        ON p.job_id=t.job_id AND p.owner_id=t.owner_id AND p.operation_id=t.operation_id
                    JOIN public.analysis_jobs j ON j.id=t.job_id AND j.owner_id=t.owner_id
                    WHERE t.job_id=OLD.job_id AND t.operation_id=OLD.account_deletion_operation_id
                        AND p.transaction_id=pg_current_xact_id()) THEN
                RETURN OLD;
            END IF;
            RAISE EXCEPTION 'IMMUTABLE_RUNTIME_SCRUB'$new$);
    EXECUTE v_definition;
END $rewrite$;

CREATE FUNCTION public.guard_retired_analysis_job()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_old_id uuid; v_old_owner uuid;
BEGIN
    IF TG_OP<>'INSERT' THEN v_old_id:=OLD.id; v_old_owner:=OLD.owner_id; END IF;
    -- AFTER observes changes made by all BEFORE triggers, including timestamps.
    IF TG_OP='DELETE' THEN
        PERFORM 1 FROM public.profiles WHERE id=v_old_owner FOR UPDATE NOWAIT;
    ELSE
        PERFORM 1 FROM public.profiles WHERE id IN (v_old_owner,NEW.owner_id)
            ORDER BY id FOR UPDATE NOWAIT;
    END IF;
    IF EXISTS (SELECT 1 FROM public.account_deleted_runtime_identities
        WHERE job_id=v_old_id OR (TG_OP<>'DELETE' AND job_id=NEW.id)) THEN
        IF TG_OP<>'UPDATE' THEN
            RAISE EXCEPTION 'IMMUTABLE_RETIRED_JOB' USING ERRCODE='22023';
        END IF;
        IF to_jsonb(NEW) IS DISTINCT FROM to_jsonb(OLD) THEN
            RAISE EXCEPTION 'IMMUTABLE_RETIRED_JOB' USING ERRCODE='22023';
        END IF;
    END IF;
    RETURN NULL;
END;
$$;
CREATE TRIGGER account_deleted_analysis_job
AFTER INSERT OR UPDATE OR DELETE ON public.analysis_jobs
FOR EACH ROW EXECUTE FUNCTION public.guard_retired_analysis_job();

CREATE FUNCTION public.guard_account_deleted_runtime_identity()
RETURNS trigger LANGUAGE plpgsql SET search_path='' AS $$
BEGIN
    RAISE EXCEPTION 'IMMUTABLE_RETIRED_IDENTITY' USING ERRCODE='22023';
END;
$$;
CREATE TRIGGER account_deleted_runtime_identity
BEFORE UPDATE OR DELETE ON public.account_deleted_runtime_identities
FOR EACH ROW EXECUTE FUNCTION public.guard_account_deleted_runtime_identity();

CREATE FUNCTION public.retire_account_deletion_runtime_internal(
    p_owner_id uuid,p_operation_id uuid
) RETURNS boolean LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path='' AS $$
DECLARE v_jobs jsonb; v_ids uuid[];
BEGIN
    PERFORM 1 FROM public.profiles WHERE id=p_owner_id FOR UPDATE;
    IF NOT FOUND OR p_operation_id IS NULL THEN RETURN false; END IF;
    SELECT coalesce(jsonb_agg(to_jsonb(j) ORDER BY j.id),'[]'::jsonb) INTO v_jobs
        FROM public.analysis_jobs j WHERE j.owner_id=p_owner_id;
    -- Check semantic anchors before predecessors could unlink/purge them.
    IF EXISTS (SELECT 1 FROM public.analysis_jobs j WHERE j.owner_id=p_owner_id
        AND (j.draft_id IS NOT NULL OR j.plant_id IS NOT NULL OR j.snapshot_id IS NOT NULL
            OR j.source_analysis_id IS NOT NULL OR j.previous_analysis_id IS NOT NULL))
        OR EXISTS (SELECT 1 FROM public.guest_drafts d JOIN public.analysis_jobs j
            ON j.id=d.analysis_job_id WHERE j.owner_id=p_owner_id)
        OR EXISTS (SELECT 1 FROM public.analysis_results r JOIN public.analysis_jobs j
            ON j.id=r.job_id WHERE j.owner_id=p_owner_id) THEN
        RAISE EXCEPTION 'semantic replay anchor' USING ERRCODE='P1623';
    END IF;
    IF EXISTS (SELECT 1 FROM public.analysis_jobs j
        JOIN public.account_deleted_runtime_identities t ON t.job_id=j.id
        LEFT JOIN public.diagnosis_job_runtime r ON r.job_id=j.id
        WHERE j.owner_id=p_owner_id AND (t.owner_id IS DISTINCT FROM p_owner_id
            OR t.operation_id IS DISTINCT FROM p_operation_id
            OR (r.job_id IS NOT NULL AND (r.account_deletion_operation_id IS DISTINCT FROM p_operation_id
                OR r.projection IS NOT NULL OR r.repeat_context IS NOT NULL OR r.initial_context IS NOT NULL)))) THEN
        RAISE EXCEPTION 'existing identity conflict' USING ERRCODE='P1623';
    END IF;
    -- Saved proof/identity is never authorization. Repeat the entire chain.
    IF NOT public.persist_account_deletion_proof_internal(p_owner_id,p_operation_id) THEN
        RAISE EXCEPTION 'fresh 021 hold' USING ERRCODE='P1623';
    END IF;
    PERFORM id FROM public.analysis_jobs WHERE owner_id=p_owner_id ORDER BY id FOR UPDATE;
    SELECT coalesce(array_agg(id ORDER BY id),'{}'::uuid[]) INTO v_ids
        FROM public.analysis_jobs WHERE owner_id=p_owner_id;
    PERFORM job_id FROM public.diagnosis_job_runtime WHERE job_id=ANY(v_ids)
        ORDER BY job_id FOR UPDATE;
    IF v_jobs IS DISTINCT FROM (SELECT coalesce(jsonb_agg(to_jsonb(j) ORDER BY j.id),'[]'::jsonb)
        FROM public.analysis_jobs j WHERE j.owner_id=p_owner_id) THEN
        RAISE EXCEPTION 'predecessor changed retained jobs' USING ERRCODE='P1623';
    END IF;
    -- Validate the whole owner jobset after locks, including jobs without runtime.
    IF EXISTS (SELECT 1 FROM public.analysis_jobs j
        LEFT JOIN public.diagnosis_job_runtime r ON r.job_id=j.id
        LEFT JOIN public.account_deleted_runtime_identities t ON t.job_id=j.id
        LEFT JOIN public.account_quota_usage u ON u.job_id=j.id
        WHERE j.id=ANY(v_ids) AND (
            j.mode NOT IN ('identification','diagnosis')
            OR j.state NOT IN ('succeeded','failed','timed_out')
            OR j.draft_id IS NOT NULL OR j.plant_id IS NOT NULL OR j.snapshot_id IS NOT NULL
            OR j.source_analysis_id IS NOT NULL OR j.previous_analysis_id IS NOT NULL
            OR EXISTS (SELECT 1 FROM public.guest_drafts d WHERE d.analysis_job_id=j.id)
            OR EXISTS (SELECT 1 FROM public.analysis_results a WHERE a.job_id=j.id)
            OR (t.job_id IS NOT NULL AND (t.owner_id IS DISTINCT FROM p_owner_id
                OR t.operation_id IS DISTINCT FROM p_operation_id))
            OR (r.job_id IS NULL AND (t.job_id IS NULL OR NOT EXISTS (
                SELECT 1 FROM public.account_deletion_proofs p WHERE p.owner_id=t.owner_id
                    AND p.operation_id=t.operation_id)))
            OR (r.job_id IS NOT NULL AND (r.account_deletion_operation_id IS DISTINCT FROM p_operation_id
                OR r.projection IS NOT NULL OR r.repeat_context IS NOT NULL OR r.initial_context IS NOT NULL))
            OR (u.job_id IS NOT NULL AND (u.owner_id IS DISTINCT FROM p_owner_id
                OR u.quota_state IS DISTINCT FROM j.quota_state))
            OR NOT (
                (j.quota_kind='none' AND j.quota_state='not_applicable'
                    AND j.monthly_quota_id IS NULL AND u.job_id IS NULL)
                OR (j.quota_state IN ('consumed','released')
                    AND (j.quota_state='released' OR j.state='succeeded')
                    AND (
                        (j.quota_kind IN ('free_monthly','paid_monthly')
                            AND (u.job_id IS NOT NULL OR EXISTS (
                                SELECT 1 FROM public.monthly_quotas q WHERE q.id=j.monthly_quota_id
                                    AND q.owner_id=p_owner_id AND q.quota_kind=j.quota_kind))
                            AND (j.monthly_quota_id IS NULL OR EXISTS (
                                SELECT 1 FROM public.monthly_quotas q WHERE q.id=j.monthly_quota_id
                                    AND q.owner_id=p_owner_id AND q.quota_kind=j.quota_kind)))
                        OR (j.quota_kind='starter_'||j.mode AND j.monthly_quota_id IS NULL
                            AND (j.quota_state='released' OR EXISTS (
                                SELECT 1 FROM public.profiles o WHERE o.id=p_owner_id AND
                                    CASE WHEN j.mode='identification' THEN o.starter_identification_consumed
                                        ELSE o.starter_diagnosis_consumed END))
                            AND NOT EXISTS (SELECT 1 FROM public.installation_access i
                                WHERE i.starter_identification_job_id=j.id OR i.starter_diagnosis_job_id=j.id)
                            AND NOT EXISTS (SELECT 1 FROM public.profiles o
                                WHERE o.starter_identification_job_id=j.id OR o.starter_diagnosis_job_id=j.id))
                    ))
            ))) THEN
        RAISE EXCEPTION 'unsupported job, accounting or runtime identity' USING ERRCODE='P1623';
    END IF;
    -- No runtime child relationship has an accepted retention contract. Hold
    -- conservatively even for an empty new FK, rather than cascading unknown data.
    IF EXISTS (SELECT 1 FROM pg_constraint WHERE contype='f'
        AND confrelid='public.diagnosis_job_runtime'::regclass) THEN
        RAISE EXCEPTION 'unknown runtime FK' USING ERRCODE='P1623';
    END IF;
    IF EXISTS (SELECT 1 FROM public.account_deleted_runtime_identities
        WHERE owner_id=p_owner_id AND (operation_id IS DISTINCT FROM p_operation_id
            OR NOT (job_id=ANY(v_ids)))) THEN
        RAISE EXCEPTION 'orphan or mismatched identity' USING ERRCODE='P1623';
    END IF;
    INSERT INTO public.account_deleted_runtime_identities(job_id,owner_id,operation_id)
        SELECT id,p_owner_id,p_operation_id FROM public.analysis_jobs WHERE id=ANY(v_ids)
        ON CONFLICT (job_id) DO NOTHING;
    INSERT INTO public.account_deletion_runtime_permits
        SELECT pg_current_xact_id(),id,p_owner_id,p_operation_id
        FROM public.analysis_jobs WHERE id=ANY(v_ids);
    DELETE FROM public.diagnosis_job_runtime WHERE job_id=ANY(v_ids);
    DELETE FROM public.account_deletion_runtime_permits
        WHERE transaction_id=pg_current_xact_id() AND owner_id=p_owner_id AND operation_id=p_operation_id;
    RETURN true;
EXCEPTION WHEN SQLSTATE 'P1623' THEN
    -- Includes fresh proof, all predecessor writes, identities, permits and deletes.
    RETURN false;
END;
$$;

-- Strip every non-owner source of default/inherited privileges.
DO $acl$
DECLARE v_role text; v_function text;
BEGIN
    FOR v_role IN
        SELECT DISTINCT CASE WHEN a.grantee=0 THEN 'PUBLIC' ELSE quote_ident(r.rolname) END
        FROM pg_class c
        CROSS JOIN LATERAL aclexplode(coalesce(c.relacl,acldefault('r',c.relowner))) a
        LEFT JOIN pg_roles r ON r.oid=a.grantee
        WHERE c.oid='public.account_deletion_runtime_permits'::regclass AND a.grantee<>c.relowner
    LOOP
        EXECUTE 'REVOKE ALL ON TABLE public.account_deletion_runtime_permits FROM '||v_role;
    END LOOP;
    FOREACH v_function IN ARRAY ARRAY[
        'public.retire_account_deletion_runtime_internal(uuid,uuid)',
        'public.guard_retired_analysis_job()',
        'public.guard_account_deleted_runtime_identity()']
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
END $acl$;

COMMIT;
