-- Fix: "Database error saving new user" on signup
--
-- Root cause: The handle_new_user() trigger runs as part of auth.users INSERT.
-- Even with SECURITY DEFINER, the INSERT into public.profiles can be blocked if
-- the function's owner is not the table's owner OR if search_path resolution
-- picks up the wrong schema. The Supabase-recommended pattern is to:
--   1. Pin search_path to '' and fully qualify table names
--   2. Add an explicit RLS policy that allows the trigger context (where
--      auth.uid() is NULL) to insert during user creation
--   3. Grant INSERT on profiles to supabase_auth_admin (the role that runs
--      the trigger) as a belt-and-suspenders safeguard

-- 1. Re-create the trigger function with hardened settings
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
    INSERT INTO public.profiles (id, display_name)
    VALUES (
        NEW.id,
        COALESCE(NEW.raw_user_meta_data->>'display_name', 'User')
    );
    RETURN NEW;
EXCEPTION WHEN OTHERS THEN
    -- Surface the real Postgres error in the auth API response instead of
    -- the generic "Database error saving new user" wrapper.
    RAISE WARNING 'handle_new_user failed for %: % (state %)', NEW.id, SQLERRM, SQLSTATE;
    RAISE;
END;
$$;

-- 2. Recreate the trigger to ensure it points at the new function definition
DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
    AFTER INSERT ON auth.users
    FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

-- 3. Grant the auth admin role direct INSERT/SELECT on profiles so the trigger
--    INSERT cannot be blocked by RLS even if SECURITY DEFINER bypass fails.
GRANT USAGE ON SCHEMA public TO supabase_auth_admin;
GRANT INSERT, SELECT ON public.profiles TO supabase_auth_admin;

-- 4. Add a dedicated RLS policy permitting the auth admin role to insert
--    profiles during signup. (Belt-and-suspenders — the GRANT alone is enough
--    when the role bypasses RLS via SECURITY DEFINER, but this guarantees the
--    insert succeeds in all configurations.)
DROP POLICY IF EXISTS "Auth admin can insert profiles" ON public.profiles;
CREATE POLICY "Auth admin can insert profiles"
    ON public.profiles
    FOR INSERT
    TO supabase_auth_admin
    WITH CHECK (true);
