BEGIN;

-- Private identity prerequisite only. Nothing records a retirement yet, and this
-- table grants no authority to delete a runtime, job, profile, or Auth account.
CREATE TABLE public.account_deleted_runtime_identities (
    job_id UUID PRIMARY KEY,
    owner_id UUID NOT NULL,
    operation_id UUID NOT NULL
);
ALTER TABLE public.account_deleted_runtime_identities ENABLE ROW LEVEL SECURITY;

-- Strip every default grant, including grants inherited through custom roles.
DO $$
DECLARE v_role TEXT;
BEGIN
    FOR v_role IN
        SELECT DISTINCT CASE WHEN a.grantee=0 THEN 'PUBLIC' ELSE quote_ident(r.rolname) END
        FROM pg_class c
        CROSS JOIN LATERAL aclexplode(coalesce(c.relacl,acldefault('r',c.relowner))) a
        LEFT JOIN pg_roles r ON r.oid=a.grantee
        WHERE c.oid='public.account_deleted_runtime_identities'::regclass
            AND a.grantee<>c.relowner
    LOOP
        EXECUTE 'REVOKE ALL ON TABLE public.account_deleted_runtime_identities FROM '||v_role;
    END LOOP;
END $$;

-- Preserve the latest ordinary finisher, its owner, configuration and ACL.
-- Change only the job lookup: the existing lease check and terminal response
-- below it remain the sole successful exit for this read-only fallback.
DO $rewrite$
DECLARE
    v_definition TEXT := pg_get_functiondef(
        'public.finish_diagnosis_job(uuid,uuid,jsonb,boolean,text)'::regprocedure);
    v_old TEXT := $old$    SELECT j.* INTO v_job FROM public.analysis_jobs j
    JOIN public.diagnosis_job_runtime r ON r.job_id = j.id
    WHERE j.id = p_job_id AND j.owner_id = v_owner FOR UPDATE OF j;
$old$;
    v_new TEXT := $new$    SELECT j.* INTO v_job FROM public.analysis_jobs j
    JOIN public.diagnosis_job_runtime r ON r.job_id = j.id
    WHERE j.id = p_job_id AND j.owner_id = v_owner FOR UPDATE OF j;
    IF NOT FOUND THEN
        -- Profile and installation were already locked in the original order.
        -- A durable 021 proof alone does not identify a missing runtime.
        SELECT j.* INTO v_job FROM public.analysis_jobs j
        JOIN public.account_deleted_runtime_identities t
          ON t.job_id=j.id AND t.owner_id=j.owner_id
        JOIN public.account_deletion_proofs p
          ON p.owner_id=t.owner_id AND p.operation_id=t.operation_id
        JOIN public.profiles o ON o.id=j.owner_id
        WHERE j.id=p_job_id AND j.owner_id=v_owner
          AND NOT o.anonymous AND o.account_state='deleting'
          AND j.mode IN ('identification','diagnosis')
          AND j.state IN ('succeeded','failed','timed_out')
          AND (j.quota_state IN ('consumed','released') OR
               (j.quota_kind='none' AND j.quota_state='not_applicable'))
          AND NOT EXISTS (
              SELECT 1 FROM public.diagnosis_job_runtime r WHERE r.job_id=j.id)
        FOR UPDATE OF j;
    END IF;
$new$;
BEGIN
    IF (length(v_definition)-length(replace(v_definition,v_old,''))) / length(v_old) <> 1 THEN
        RAISE EXCEPTION '022 expected exactly one current finisher job lookup';
    END IF;
    EXECUTE replace(v_definition,v_old,v_new);
END $rewrite$;

COMMIT;
