-- T161, slice 1: constrain every writer without rewriting command/claim RPCs.
-- No historical rows, receipts, memberships or quota records are changed.
CREATE FUNCTION public.enforce_plant_collection_cap()
RETURNS TRIGGER
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    v_account_state TEXT;
BEGIN
    IF TG_OP = 'UPDATE' THEN
        -- Ordinary edits/deletion of an existing instance never add capacity.
        IF NEW.owner_id IS NOT DISTINCT FROM OLD.owner_id
           AND (OLD.deleted_at IS NULL OR NEW.deleted_at IS NOT NULL) THEN
            RETURN NEW;
        END IF;
    END IF;

    -- An actual tuple update both locks the owner and makes stale REPEATABLE
    -- READ/SERIALIZABLE writers fail with a serialization error. A bare row
    -- lock would leave those writers able to count an old snapshot.
    -- Preserve the logical watermark: command RPCs already advance it.
    UPDATE public.profiles AS p
       SET updated_at = p.updated_at
     WHERE p.id = NEW.owner_id
     RETURNING p.account_state INTO v_account_state;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'owner_profile_not_found' USING ERRCODE = 'P0002';
    END IF;
    IF v_account_state <> 'active' THEN
        RAISE EXCEPTION 'account_not_active' USING ERRCODE = '42501';
    END IF;

    -- Deleted instances occupy no capacity. Check rights at server time after
    -- acquiring the lock, independently of any caller-supplied RPC p_now.
    IF NEW.deleted_at IS NULL
       AND NOT public.has_verified_paid_access(NEW.owner_id, clock_timestamp())
       AND (SELECT count(*) FROM public.plants AS p
            WHERE p.owner_id = NEW.owner_id
              AND p.deleted_at IS NULL
              AND p.id <> NEW.id) >= 3 THEN
        RAISE EXCEPTION 'COLLECTION_LIMIT_REACHED' USING ERRCODE = 'P0001';
    END IF;

    RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.enforce_plant_collection_cap()
    FROM PUBLIC, anon, authenticated;

CREATE TRIGGER trg_plants_collection_cap
    BEFORE INSERT OR UPDATE ON public.plants
    FOR EACH ROW
    EXECUTE FUNCTION public.enforce_plant_collection_cap();
