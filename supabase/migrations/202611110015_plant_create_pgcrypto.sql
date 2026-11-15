-- Resolve pgcrypto in both the public and hosted Supabase extensions layouts.
ALTER FUNCTION public.execute_plant_create_command(UUID, UUID, JSONB, TIMESTAMPTZ)
  SET search_path = public, extensions;
