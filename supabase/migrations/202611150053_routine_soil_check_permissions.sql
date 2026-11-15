BEGIN;

REVOKE ALL ON FUNCTION public.execute_routine_soil_check(UUID,UUID,UUID,INT,UUID,DATE,TIMESTAMPTZ,TEXT)
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.execute_routine_soil_check(UUID,UUID,UUID,INT,UUID,DATE,TIMESTAMPTZ,TEXT)
TO service_role;
COMMENT ON FUNCTION public.execute_routine_soil_check(UUID,UUID,UUID,INT,UUID,DATE,TIMESTAMPTZ,TEXT)
IS 'private:routine-soil-check-owner-http:053';

COMMIT;
