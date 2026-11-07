-- The API resolves the current session with the user's JWT. RLS restricts rows
-- to the active owner. Keep all other profile fields outside this grant.
GRANT SELECT (id, account_state, anonymous) ON public.profiles TO authenticated;
