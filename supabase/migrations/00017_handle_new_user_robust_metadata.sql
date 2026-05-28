-- Build 39 — make `handle_new_user` robust to provider-specific metadata
-- shapes so Apple / Google / future OIDC providers all land with a
-- sensible `display_name` instead of falling through to the literal
-- 'User' fallback.
--
-- Previous behaviour (migration 00004): only read
-- `raw_user_meta_data->>'display_name'`. Apple Sign In populates
-- `full_name` (or `name.firstName` + `name.lastName`), so every
-- Apple sign-up landed with `display_name = 'User'` until the user
-- went into Profile and edited it.
--
-- New behaviour: coalesce across the metadata shapes we've actually
-- seen Supabase Auth emit, then fall back to the email prefix, then
-- to 'User' if everything else is null. Each text expression is
-- wrapped in `NULLIF(..., '')` so empty strings (e.g. concat of two
-- null name parts) don't shadow the next candidate.
--
-- Importantly this migration ONLY changes the function body. The
-- trigger binding, RLS policy, and grants from 00004 are preserved.

CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    candidate text;
    apple_name text;
BEGIN
    -- Apple raw name object: {"firstName": "...", "lastName": "..."}.
    -- COALESCE each part with '' so `concat` doesn't yield NULL if
    -- only one half is present; then TRIM + NULLIF squashes the
    -- "two empty halves" → empty-string case so the outer COALESCE
    -- moves on to the next candidate cleanly.
    apple_name := NULLIF(
        TRIM(
            COALESCE(NEW.raw_user_meta_data->'name'->>'firstName', '') || ' ' ||
            COALESCE(NEW.raw_user_meta_data->'name'->>'lastName',  '')
        ),
        ''
    );

    candidate := COALESCE(
        NULLIF(NEW.raw_user_meta_data->>'full_name',    ''),  -- Apple (when iOS forwards) / Google / Facebook
        apple_name,                                            -- Apple raw `name` object
        NULLIF(NEW.raw_user_meta_data->>'name',         ''),  -- generic OIDC providers
        NULLIF(NEW.raw_user_meta_data->>'display_name', ''),  -- our email signup form
        NULLIF(split_part(NEW.email, '@', 1),           ''),  -- email prefix as last-resort identity
        'User'                                                 -- terminal fallback
    );

    INSERT INTO public.profiles (id, display_name)
    VALUES (NEW.id, candidate);

    RETURN NEW;
EXCEPTION WHEN OTHERS THEN
    -- Same surface-the-real-error pattern as 00004. The auth API
    -- response otherwise reads "Database error saving new user"
    -- and we can't tell from the client which fallback failed.
    RAISE WARNING 'handle_new_user failed for %: % (state %)', NEW.id, SQLERRM, SQLSTATE;
    RAISE;
END;
$$;
