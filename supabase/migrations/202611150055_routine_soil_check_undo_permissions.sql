BEGIN;

REVOKE ALL ON FUNCTION public.execute_routine_soil_check_undo(UUID,UUID,UUID,UUID)
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.execute_routine_soil_check_undo(UUID,UUID,UUID,UUID)
TO service_role;
COMMENT ON FUNCTION public.execute_routine_soil_check_undo(UUID,UUID,UUID,UUID)
IS 'private:routine-soil-check-undo-owner-http:055';

COMMIT;
