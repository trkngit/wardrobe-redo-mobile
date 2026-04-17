# Welcome Email Setup

After signup, users receive a branded welcome email. Sent asynchronously via Resend so a Resend outage cannot block account creation.

## One-time setup (~5 minutes)

### 1. Disable email confirmation
Supabase dashboard → **Authentication → Providers → Email** → uncheck **Confirm email** → Save.

Result: signup returns a session immediately. Users are logged in without clicking a link.

### 2. Enable pg_net
Supabase dashboard → **Database → Extensions** → search `pg_net` → toggle Enable.

### 3. Get a Resend API key
1. Sign up at [resend.com](https://resend.com) (free tier: 3,000 emails/month, 100/day)
2. Dashboard → **API Keys** → Create API Key → copy it (starts with `re_`)

### 4. Store the key in Supabase Vault
Supabase dashboard → **SQL Editor** → New query → run:
```sql
SELECT vault.create_secret('re_YOUR_KEY_HERE', 'resend_api_key');
```
Replace `re_YOUR_KEY_HERE` with the key from step 3. The secret is encrypted at rest.

### 5. Apply the migration
SQL Editor → New query → paste the contents of `supabase/migrations/00005_send_welcome_email.sql` → Run.

### 6. Test it
Sign up a new account in the iOS app using **your own email**. The welcome email should arrive within 5 seconds.

If it doesn't arrive:
- Check Resend dashboard → **Logs** for the API call
- Check Supabase dashboard → **Database → Logs** for warnings from `send_welcome_email`

## Production: use your own domain

The default `onboarding@resend.dev` from-address only delivers to **your own** verified Resend account email. To send to other users:

1. Buy/own a domain (e.g., `wardroberedo.app`)
2. Resend dashboard → **Domains** → Add Domain → follow the DNS verification steps (~5 min)
3. Once verified, update the from-address:
```sql
UPDATE public.app_config
SET value = 'Wardrobe <welcome@wardroberedo.app>'
WHERE key = 'welcome_from_address';
```

## Customizing the email

Edit the `html_body` block inside `public.send_welcome_email()` (in `00005_send_welcome_email.sql`). The current template uses the brand colors (`#8B6F3D` brass, `#FAF8F5` cream, Cormorant Garamond serif).

To change the subject line:
```sql
UPDATE public.app_config SET value = 'Your new subject' WHERE key = 'welcome_subject';
```

## Rotating the Resend key

```sql
SELECT vault.update_secret(
    (SELECT id FROM vault.secrets WHERE name = 'resend_api_key'),
    'new_key_here'
);
```

## Disabling welcome emails temporarily

```sql
ALTER TABLE auth.users DISABLE TRIGGER welcome_email_on_signup;
-- Re-enable later:
ALTER TABLE auth.users ENABLE TRIGGER welcome_email_on_signup;
```
