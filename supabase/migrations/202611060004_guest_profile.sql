-- Guest sessions need an owner row before the first private API call.
CREATE FUNCTION public.create_guest_profile()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
    INSERT INTO public.profiles (id, anonymous)
    VALUES (NEW.id, true)
    ON CONFLICT (id) DO NOTHING;
    RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.create_guest_profile() FROM PUBLIC, anon, authenticated;

CREATE TRIGGER narat_guest_profile_after_signup
AFTER INSERT ON auth.users
FOR EACH ROW WHEN (NEW.is_anonymous)
EXECUTE FUNCTION public.create_guest_profile();

INSERT INTO public.profiles (id, anonymous)
SELECT id, true FROM auth.users WHERE is_anonymous
ON CONFLICT (id) DO NOTHING;
