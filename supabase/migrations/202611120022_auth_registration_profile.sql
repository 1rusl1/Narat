BEGIN;

-- Auth owns registration and identity conversion. Profiles own quota and sync state.
CREATE FUNCTION public.sync_auth_owner_profile()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        IF NEW.is_anonymous IS NOT NULL THEN
            INSERT INTO public.profiles (id, anonymous, created_at)
            VALUES (NEW.id, NEW.is_anonymous, coalesce(NEW.created_at, clock_timestamp()))
            ON CONFLICT (id) DO NOTHING;
        END IF;
    ELSE
        -- The profile anchor trigger records the conversion instant under the owner lock.
        UPDATE public.profiles
        SET anonymous = false,
            updated_at = greatest(clock_timestamp(), updated_at + interval '1 microsecond')
        WHERE id = NEW.id AND anonymous AND account_state = 'active';
    END IF;
    RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.sync_auth_owner_profile() FROM PUBLIC, anon, authenticated, service_role;

DROP TRIGGER narat_guest_profile_after_signup ON auth.users;
DROP FUNCTION public.create_guest_profile();

CREATE TRIGGER narat_owner_profile_after_signup
AFTER INSERT ON auth.users
FOR EACH ROW EXECUTE FUNCTION public.sync_auth_owner_profile();

CREATE TRIGGER narat_owner_profile_after_conversion
AFTER UPDATE OF is_anonymous ON auth.users
FOR EACH ROW WHEN (OLD.is_anonymous IS TRUE AND NEW.is_anonymous IS FALSE)
EXECUTE FUNCTION public.sync_auth_owner_profile();

COMMIT;
