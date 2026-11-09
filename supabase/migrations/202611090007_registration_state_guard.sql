-- T163 forward fix for a permanent legacy owner whose anchor is unresolved.
BEGIN;
CREATE FUNCTION public.guard_permanent_registration_state()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
  IF NOT OLD.anonymous AND NEW.anonymous THEN
    RAISE EXCEPTION 'REGISTRATION_ANCHOR_IMMUTABLE' USING ERRCODE='55000';
  END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.guard_permanent_registration_state() FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.guard_permanent_registration_state() TO service_role;
CREATE TRIGGER trg_permanent_registration_state
BEFORE UPDATE OF anonymous ON public.profiles
FOR EACH ROW EXECUTE FUNCTION public.guard_permanent_registration_state();
COMMIT;
