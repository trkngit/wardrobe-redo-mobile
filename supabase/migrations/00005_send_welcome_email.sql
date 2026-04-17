-- Welcome email after signup
--
-- Approach: when a row is inserted into auth.users, fire an async HTTP POST
-- to Resend's email API via pg_net. Runs out-of-band from the signup
-- transaction so a Resend outage cannot block account creation.
--
-- Prerequisites (one-time setup, see SETUP_WELCOME_EMAIL.md):
--   1. Disable "Confirm email" in Supabase dashboard (Auth → Providers → Email)
--   2. Enable pg_net extension (Database → Extensions → pg_net → Enable)
--   3. Create a Resend account, get an API key
--   4. Store the key in Vault:
--        SELECT vault.create_secret('YOUR_RESEND_KEY', 'resend_api_key');
--   5. Set your verified sending domain in app_config below
--   6. Run this migration

-- ============================================================
-- 1. Configuration table for the from-address
-- ============================================================
CREATE TABLE IF NOT EXISTS public.app_config (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);

-- Default values — UPDATE these in app_config to match your verified domain.
-- 'onboarding@resend.dev' works only for testing (sends to your own email only).
INSERT INTO public.app_config (key, value) VALUES
    ('welcome_from_address', 'Wardrobe <onboarding@resend.dev>'),
    ('welcome_subject',      'Welcome to Wardrobe')
ON CONFLICT (key) DO NOTHING;

-- ============================================================
-- 2. Trigger function — POST to Resend
-- ============================================================
CREATE OR REPLACE FUNCTION public.send_welcome_email()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    api_key       TEXT;
    from_address  TEXT;
    subject_line  TEXT;
    display_name  TEXT;
    html_body     TEXT;
BEGIN
    -- Fetch Resend key from Vault. If missing, log and skip silently — a
    -- missing welcome email must never block signup.
    BEGIN
        SELECT decrypted_secret INTO api_key
        FROM vault.decrypted_secrets
        WHERE name = 'resend_api_key'
        LIMIT 1;
    EXCEPTION WHEN OTHERS THEN
        api_key := NULL;
    END;

    IF api_key IS NULL OR api_key = '' THEN
        RAISE WARNING 'send_welcome_email: resend_api_key not configured in Vault, skipping for %', NEW.id;
        RETURN NEW;
    END IF;

    SELECT value INTO from_address FROM public.app_config WHERE key = 'welcome_from_address';
    SELECT value INTO subject_line FROM public.app_config WHERE key = 'welcome_subject';
    display_name := COALESCE(NEW.raw_user_meta_data->>'display_name', 'there');

    html_body := '<!DOCTYPE html><html><head><meta charset="UTF-8"></head>'
        || '<body style="font-family:Georgia,''Cormorant Garamond'',serif;background:#FAF8F5;padding:48px 24px;color:#2A2620;">'
        || '<div style="max-width:520px;margin:0 auto;background:#FFFFFF;border-radius:12px;padding:48px 36px;border:1px solid #E8E2D8;">'
        || '<h1 style="font-size:32px;font-weight:400;margin:0 0 8px 0;color:#8B6F3D;letter-spacing:-0.5px;">Welcome to Wardrobe</h1>'
        || '<p style="font-size:14px;color:#7A7268;margin:0 0 32px 0;font-style:italic;">Your daily style, curated.</p>'
        || '<p style="font-size:16px;line-height:1.6;margin:0 0 16px 0;">Hi ' || display_name || ',</p>'
        || '<p style="font-size:16px;line-height:1.6;margin:0 0 16px 0;">Your account is ready. Start by photographing a few wardrobe pieces — even five items is enough for the engine to begin suggesting outfits.</p>'
        || '<p style="font-size:16px;line-height:1.6;margin:0 0 32px 0;">Each suggestion is scored across seven dimensions of style theory: proportion, color harmony, texture mix, formality, formula, versatility, and occasion. Over time it learns what you actually wear.</p>'
        || '<p style="font-size:16px;line-height:1.6;margin:0 0 8px 0;">Welcome aboard.</p>'
        || '<p style="font-size:16px;line-height:1.6;margin:0;color:#8B6F3D;">— The Wardrobe team</p>'
        || '<hr style="border:none;border-top:1px solid #E8E2D8;margin:36px 0 24px 0;">'
        || '<p style="font-size:12px;color:#A39B8E;margin:0;">You received this because you created an account at Wardrobe Re-Do.</p>'
        || '</div></body></html>';

    -- Fire-and-forget POST to Resend. pg_net is async — does not block
    -- the auth.users INSERT transaction.
    PERFORM net.http_post(
        url     := 'https://api.resend.com/emails',
        headers := jsonb_build_object(
            'Authorization', 'Bearer ' || api_key,
            'Content-Type',  'application/json'
        ),
        body    := jsonb_build_object(
            'from',    from_address,
            'to',      ARRAY[NEW.email],
            'subject', subject_line,
            'html',    html_body
        )
    );

    RETURN NEW;
EXCEPTION WHEN OTHERS THEN
    -- Never block signup on email failure.
    RAISE WARNING 'send_welcome_email failed for %: % (state %)', NEW.id, SQLERRM, SQLSTATE;
    RETURN NEW;
END;
$$;

-- ============================================================
-- 3. Trigger — fires AFTER INSERT so the user row exists first
-- ============================================================
DROP TRIGGER IF EXISTS welcome_email_on_signup ON auth.users;
CREATE TRIGGER welcome_email_on_signup
    AFTER INSERT ON auth.users
    FOR EACH ROW EXECUTE FUNCTION public.send_welcome_email();
