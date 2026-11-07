-- T147: restrict snapshot activation to the release table and its final state.
-- In a transactional migration, take the publisher's lock before trigger DDL.
SELECT pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext('public.catalogue_releases_mutex'));

CREATE OR REPLACE FUNCTION public.activate_catalogue_release_snapshot()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_snap public.catalogue_release_species;
BEGIN
    -- Revoking EXECUTE prevents new attachments. This also rejects any old ones.
    IF TG_RELID <> 'public.catalogue_releases'::regclass
       OR TG_LEVEL <> 'ROW' OR TG_WHEN <> 'AFTER' OR TG_OP NOT IN ('INSERT', 'UPDATE') THEN
        RAISE EXCEPTION 'invalid_catalogue_activation_trigger' USING ERRCODE = '42501';
    END IF;

    IF NEW.state <> 'published' OR (TG_OP = 'UPDATE' AND OLD.state = 'published') THEN
        RETURN NEW;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.catalogue_release_species WHERE release_id = NEW.id) THEN
        RETURN NEW;
    END IF;

    UPDATE public.catalogue_taxa t SET status = 'draft', updated_at = clock_timestamp()
    WHERE NOT EXISTS (
        SELECT 1 FROM public.catalogue_release_species s
        WHERE s.release_id = NEW.id AND s.taxon_id = t.id
    );

    UPDATE public.catalogue_media m SET review_state = 'pending'
    WHERE NOT EXISTS (
        SELECT 1 FROM public.catalogue_release_species s
        WHERE s.release_id = NEW.id AND s.taxon_id = m.taxon_id AND s.status = 'published'
    );

    FOR v_snap IN SELECT * FROM public.catalogue_release_species WHERE release_id = NEW.id LOOP
        PERFORM public.validate_catalogue_skeleton_species_record(to_jsonb(v_snap));
        PERFORM public.sync_active_catalogue_taxon_from_snapshot(NEW.id, NEW.version, v_snap);
    END LOOP;
    RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.activate_catalogue_release_snapshot() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.lock_catalogue_releases_mutex() FROM PUBLIC, anon, authenticated;

-- sync_release_state_status runs BEFORE the row is stored. Observe the resulting
-- state even if the original UPDATE only named its status alias.
CREATE OR REPLACE TRIGGER trg_catalogue_releases_activate_snapshot
    AFTER INSERT OR UPDATE ON public.catalogue_releases
    FOR EACH ROW EXECUTE FUNCTION public.activate_catalogue_release_snapshot();

-- Reapply an already published snapshot if the old trigger left its rows hidden
-- or pointing at another release. Both state transitions are in one transaction.
DO $$
DECLARE
    v_release_id uuid;
BEGIN
    PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext('public.catalogue_releases_mutex'));
    SELECT r.id INTO v_release_id FROM public.catalogue_releases r
    WHERE r.state = 'published' AND EXISTS (
        SELECT 1 FROM public.catalogue_release_species s
        JOIN public.catalogue_taxa t ON t.id = s.taxon_id
        WHERE s.release_id = r.id
          AND (t.release_id IS DISTINCT FROM r.id OR t.status IS DISTINCT FROM s.status)
    );
    IF FOUND THEN
        UPDATE public.catalogue_releases SET state = 'retired' WHERE id = v_release_id;
        UPDATE public.catalogue_releases SET state = 'published' WHERE id = v_release_id;
    END IF;
END;
$$;
