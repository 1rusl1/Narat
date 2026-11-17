BEGIN;

-- Empty-account boundary only. No Auth HTTP/API call, provider preflight or
-- auth.users mutation. T083 and Apple support remain open.
-- Generate exactly two private entry points with the same fail-closed graph
-- validator; no independently callable helper or caller-controlled bypass.
DO $migration$
DECLARE
    v_name text;
    v_complete boolean;
    v_role text;
    v_body text := $body$
DECLARE
    v_complete constant boolean := @COMPLETE@;
    v_profile public.profiles%ROWTYPE;
    v_job public.deletion_jobs%ROWTYPE;
    v_proof public.account_deletion_proofs%ROWTYPE;
    v_request public.account_deletion_requests%ROWTYPE;
    v_first boolean;
    v_replay boolean;
    v_pass integer;
    v_table record;
    v_column record;
    v_fk record;
    v_match text;
    v_allow text;
    v_hit boolean;
BEGIN
    IF p_owner_id IS NULL OR p_operation_id IS NULL THEN RETURN false; END IF;
    -- Profile first, including replay. All subsequent barriers are NOWAIT:
    -- direct writers cannot add a semantic/FK dependency after validation.
    SELECT * INTO v_profile FROM public.profiles WHERE id=p_owner_id FOR UPDATE NOWAIT;
    FOR v_table IN
        SELECT c.oid,n.nspname,c.relname,c.relkind
        FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
        WHERE c.relkind IN ('r','p','f') AND (n.nspname='public' OR EXISTS (
            SELECT 1 FROM pg_constraint f WHERE f.contype='f'
                AND f.conrelid=c.oid AND f.confrelid='public.profiles'::regclass))
        ORDER BY c.oid
    LOOP
        IF v_table.relkind='f' THEN
            RAISE EXCEPTION 'unbounded foreign dependency' USING ERRCODE='P1624';
        END IF;
        EXECUTE format('LOCK TABLE %I.%I IN SHARE ROW EXCLUSIVE MODE NOWAIT',
            v_table.nspname,v_table.relname);
    END LOOP;
    -- Blocks Auth reinsertion until commit, and Storage uploads until the
    -- fresh 065 check and profile purge have committed. No network under locks.
    LOCK TABLE auth.users IN SHARE MODE NOWAIT;
    LOCK TABLE storage.objects IN SHARE MODE NOWAIT;

    SELECT * INTO v_job FROM public.deletion_jobs
        WHERE owner_id=p_owner_id AND operation_id=p_operation_id FOR UPDATE;
    IF FOUND AND (v_job.scope IS DISTINCT FROM 'account'
        OR v_job.target_id IS DISTINCT FROM p_owner_id
        OR v_job.encrypted_apple_ref IS NOT NULL) THEN
        RAISE EXCEPTION 'job identity hold' USING ERRCODE='P1624';
    END IF;
    v_replay := v_complete AND v_job.state='completed';
    v_replay := coalesce(v_replay,false);
    IF v_replay THEN
        IF v_profile.id IS NOT NULL OR v_job.completed_at IS NULL THEN
            RAISE EXCEPTION 'resurrected profile or invalid completion' USING ERRCODE='P1624';
        END IF;
    ELSE
        IF v_profile.id IS NULL OR v_profile.anonymous IS DISTINCT FROM false
            OR v_profile.account_state IS DISTINCT FROM 'deleting'
            OR v_job.completed_at IS NOT NULL
            OR (v_complete AND v_job.state IS DISTINCT FROM 'delete_auth')
            OR (NOT v_complete AND v_job.id IS NOT NULL
                AND v_job.state NOT IN ('purge_data','delete_auth')) THEN
            RAISE EXCEPTION 'owner/state hold' USING ERRCODE='P1624';
        END IF;
    END IF;
    IF v_complete AND EXISTS (SELECT 1 FROM auth.users WHERE id=p_owner_id) THEN
        RAISE EXCEPTION 'Auth still present' USING ERRCODE='P1624';
    END IF;
    -- A profile pointing into a remaining graph is unsupported even when the
    -- referenced job belongs to a different owner.
    IF NOT v_replay AND EXISTS (
        SELECT 1 FROM pg_constraint f
        JOIN pg_attribute a ON a.attrelid=f.conrelid AND a.attnum=ANY(f.conkey)
        WHERE f.contype='f' AND f.conrelid='public.profiles'::regclass
            AND to_jsonb(v_profile)->a.attname IS NOT NULL
            AND to_jsonb(v_profile)->a.attname<>'null'::jsonb) THEN
        RAISE EXCEPTION 'profile graph link hold' USING ERRCODE='P1624';
    END IF;
    v_first := NOT v_complete AND (v_job.id IS NULL OR v_job.state='purge_data');

    -- Pass one rejects content BEFORE 021 can purge anything. Only 021's exact
    -- installation unlink is permitted. Pass two checks the resulting graph.
    FOR v_pass IN 1..2 LOOP
        IF v_pass=2 AND NOT v_replay THEN
            IF v_first THEN
                IF NOT public.persist_account_deletion_proof_internal(p_owner_id,p_operation_id) THEN
                    RAISE EXCEPTION 'fresh 021 hold' USING ERRCODE='P1624';
                END IF;
            ELSE
                -- 020 intentionally rejects delete_auth: use fresh 065 instead.
                IF public.verify_account_deletion_storage_internal(p_owner_id,p_operation_id) IS NULL THEN
                    RAISE EXCEPTION 'fresh 065 hold' USING ERRCODE='P1624';
                END IF;
            END IF;
        END IF;
        IF v_pass=2 OR v_replay THEN
            SELECT * INTO v_job FROM public.deletion_jobs
                WHERE owner_id=p_owner_id AND operation_id=p_operation_id FOR UPDATE;
            SELECT * INTO v_proof FROM public.account_deletion_proofs
                WHERE owner_id=p_owner_id FOR UPDATE;
            IF v_job.id IS NULL OR v_proof.owner_id IS DISTINCT FROM p_owner_id
                OR v_proof.operation_id IS DISTINCT FROM p_operation_id
                OR v_proof.deletion_job_id IS DISTINCT FROM v_job.id
                OR v_job.scope IS DISTINCT FROM 'account'
                OR v_job.target_id IS DISTINCT FROM p_owner_id
                OR v_job.encrypted_apple_ref IS NOT NULL THEN
                RAISE EXCEPTION 'durable identity hold' USING ERRCODE='P1624';
            END IF;
            IF NOT v_replay THEN
                SELECT * INTO v_request FROM public.account_deletion_requests
                    WHERE owner_id=p_owner_id FOR UPDATE;
                IF v_request.owner_id IS NULL
                    OR v_request.operation_id IS DISTINCT FROM p_operation_id
                    OR v_proof.requested_at IS DISTINCT FROM v_request.requested_at
                    OR v_proof.storage_verified_at IS DISTINCT FROM v_request.storage_verified_at
                    OR v_request.storage_verified_at IS NULL
                    OR v_job.completed_at IS NOT NULL
                    OR v_job.state IS DISTINCT FROM
                        (CASE WHEN v_first THEN 'purge_data' ELSE 'delete_auth' END) THEN
                    RAISE EXCEPTION 'fresh proof/job hold' USING ERRCODE='P1624';
                END IF;
            END IF;
        END IF;

        -- Resolve incoming FKs by ordinal conkey/confkey pairs, including
        -- non-id/composite profile keys and dependencies in other schemas.
        -- This runs before any 021 mutation and again after fresh verification.
        FOR v_fk IN
            SELECT n.nspname,c.relname,
                string_agg(format('t.%I=p.%I',a.attname,b.attname),
                    ' AND ' ORDER BY k.ordinality) AS predicate,
                count(*)=1 AND bool_and(a.attname='owner_id' AND b.attname='id') AS canonical
            FROM pg_constraint f
            JOIN pg_class c ON c.oid=f.conrelid
            JOIN pg_namespace n ON n.oid=c.relnamespace
            CROSS JOIN LATERAL unnest(f.conkey) WITH ORDINALITY k(attnum,ordinality)
            JOIN pg_attribute a ON a.attrelid=f.conrelid AND a.attnum=k.attnum
            JOIN pg_attribute b ON b.attrelid=f.confrelid
                AND b.attnum=f.confkey[k.ordinality::integer]
            WHERE f.contype='f' AND f.confrelid='public.profiles'::regclass
            GROUP BY f.oid,n.nspname,c.relname
            ORDER BY f.oid
        LOOP
            v_allow := 'false';
            IF NOT v_replay AND v_fk.canonical AND v_fk.nspname='public'
                AND v_fk.relname IN ('account_deletion_requests','operation_receipts','account_quota_anchors') THEN
                v_allow := 't.owner_id=$1';
            END IF;
            EXECUTE format('SELECT EXISTS(SELECT 1 FROM %I.%I t
                JOIN public.profiles p ON %s
                WHERE p.id=$1 AND NOT coalesce((%s),false))',
                v_fk.nspname,v_fk.relname,v_fk.predicate,v_allow)
                INTO v_hit USING p_owner_id;
            IF v_hit THEN
                RAISE EXCEPTION 'unsupported incoming profile FK' USING ERRCODE='P1624';
            END IF;
        END LOOP;

        -- Discover semantic ownership independently of referenced FK values.
        -- Inspect only existence; never fetch a neighbor's payload as own data.
        FOR v_column IN
            SELECT DISTINCT n.nspname,c.relname,a.attname
            FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
            JOIN pg_attribute a ON a.attrelid=c.oid AND a.attnum>0 AND NOT a.attisdropped
            WHERE c.relkind IN ('r','p') AND (
                (n.nspname='public' AND (a.attname ~ '(^|_)owner_id$'
                    OR a.attname IN ('user_id','linked_owner_ids')
                    OR (c.oid='public.deletion_jobs'::regclass AND a.attname='target_id')
                    OR (c.oid='public.profiles'::regclass AND a.attname='id'))))
            ORDER BY n.nspname,c.relname,a.attname
        LOOP
            v_match := format(
                '(to_jsonb(t)->%1$L=to_jsonb($1::text) OR
                  (jsonb_typeof(to_jsonb(t)->%1$L)=''array'' AND
                   to_jsonb(t)->%1$L @> jsonb_build_array($1::text)) OR
                  (to_jsonb(t)->>''owner_id''=$1::text AND
                   to_jsonb(t)->%1$L IS NOT NULL AND
                   to_jsonb(t)->%1$L<>''null''::jsonb))',v_column.attname);
            IF v_column.nspname='public' AND v_column.relname='profiles'
                AND v_column.attname<>'id' THEN
                v_match := v_match || format(
                    ' OR (to_jsonb(t)->>''id''=$1::text AND
                        to_jsonb(t)->%1$L IS NOT NULL AND to_jsonb(t)->%1$L<>''null''::jsonb)',
                    v_column.attname);
                v_match := '('||v_match||')';
            END IF;
            v_allow := 'false';
            IF v_column.nspname='public' THEN
                IF v_column.relname='profiles' AND v_column.attname='id' AND NOT v_replay THEN
                    v_allow := 'true';
                ELSIF v_column.relname IN ('operation_receipts','account_quota_anchors')
                    AND v_column.attname='owner_id' AND NOT v_replay THEN
                    v_allow := 'to_jsonb(t)->>''owner_id''=$1::text';
                ELSIF v_column.relname IN ('account_deletion_requests','account_deletion_proofs')
                    AND v_column.attname='owner_id'
                    AND (NOT v_replay OR v_column.relname='account_deletion_proofs') THEN
                    v_allow := 'to_jsonb(t)->>''owner_id''=$1::text AND to_jsonb(t)->>''operation_id''=$2::text';
                ELSIF v_column.relname='deletion_jobs'
                    AND v_column.attname IN ('owner_id','target_id') THEN
                    v_allow := 'to_jsonb(t)->>''owner_id''=$1::text AND
                        to_jsonb(t)->>''operation_id''=$2::text AND
                        to_jsonb(t)->>''scope''=''account'' AND to_jsonb(t)->>''target_id''=$1::text';
                ELSIF v_column.relname='installation_access' AND v_column.attname='linked_owner_ids'
                    AND v_first AND v_pass=1 THEN
                    v_allow := 'true';
                END IF;
            END IF;
            EXECUTE format('SELECT EXISTS(SELECT 1 FROM %I.%I t WHERE %s AND NOT coalesce((%s),false))',
                v_column.nspname,v_column.relname,v_match,v_allow)
                INTO v_hit USING p_owner_id,p_operation_id;
            IF v_hit THEN
                RAISE EXCEPTION 'unsupported populated dependency' USING ERRCODE='P1624';
            END IF;
        END LOOP;
        IF v_replay THEN RETURN true; END IF;
    END LOOP;

    IF NOT v_complete THEN
        UPDATE public.deletion_jobs SET state='delete_auth'
            WHERE id=v_job.id AND state='purge_data';
        RETURN true;
    END IF;
    -- Only the two validated own FK cascades are allowed. Unknown populated
    -- edges, including SET NULL edges, have already been rejected.
    DELETE FROM public.account_deletion_requests WHERE owner_id=p_owner_id AND operation_id=p_operation_id;
    DELETE FROM public.profiles WHERE id=p_owner_id;
    UPDATE public.deletion_jobs SET state='completed',completed_at=clock_timestamp() WHERE id=v_job.id;
    RETURN true;
EXCEPTION WHEN SQLSTATE 'P1624' OR lock_not_available OR integrity_constraint_violation THEN
    -- Includes predecessor writes, proof timestamps, cascades and late failures.
    RETURN false;
END;
$body$;
BEGIN
    FOREACH v_complete IN ARRAY ARRAY[false,true] LOOP
        v_name := CASE WHEN v_complete THEN 'complete_empty_account_auth_deletion_internal'
            ELSE 'prepare_empty_account_auth_deletion_internal' END;
        EXECUTE format('CREATE FUNCTION public.%I(p_owner_id uuid,p_operation_id uuid)
            RETURNS boolean LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = %L AS %L',
            v_name,'',replace(v_body,'@COMPLETE@',v_complete::text));
        FOR v_role IN
            SELECT DISTINCT CASE WHEN a.grantee=0 THEN 'PUBLIC' ELSE quote_ident(r.rolname) END
            FROM pg_proc p
            CROSS JOIN LATERAL aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) a
            LEFT JOIN pg_roles r ON r.oid=a.grantee
            WHERE p.oid=to_regprocedure('public.'||v_name||'(uuid,uuid)') AND a.grantee<>p.proowner
        LOOP
            EXECUTE format('REVOKE ALL ON FUNCTION public.%I(uuid,uuid) FROM %s',v_name,v_role);
        END LOOP;
    END LOOP;
END;
$migration$;

COMMIT;
