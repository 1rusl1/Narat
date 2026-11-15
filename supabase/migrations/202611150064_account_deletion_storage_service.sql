BEGIN;

-- Only the bounded plan becomes callable by internal service maintenance.
-- T082/T083 remain open for scheduling and DB/Auth purge.
REVOKE ALL ON FUNCTION public.read_account_deletion_storage_work_plan(uuid)
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.read_account_deletion_storage_work_plan(uuid)
    TO service_role;
COMMENT ON FUNCTION public.read_account_deletion_storage_work_plan(uuid)
    IS '064: account storage work plan service-only execution';

COMMIT;
