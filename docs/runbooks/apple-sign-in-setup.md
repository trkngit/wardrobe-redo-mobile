# Apple Sign In — Supabase + Apple Developer setup

The iOS code is wired (Build 32). For the button to actually
authenticate users, two dashboards need ~10 minutes of one-time
configuration.

## 1. Apple Developer portal

Sign in at <https://developer.apple.com/account/>.

### 1a. Enable the capability on the App ID

1. **Identifiers** → pick `com.digitalatelier.wardroberedo`.
2. Tick **Sign In with Apple** → **Save** → **Continue** → **Save**.
3. (Provisioning profiles regenerate automatically next build.)

### 1b. Create a Services ID + private key for the OAuth handshake

Supabase needs an OAuth client to verify the JWT Apple returns.
This is separate from the iOS capability.

1. **Identifiers** → **+** → **Services IDs** → **Continue**.
   - Description: `Wardrobe Web Auth`
   - Identifier: `com.digitalatelier.wardroberedo.web` (any unique
     reverse-DNS string is fine; remember it for step 2c).
   - **Continue → Register**.
2. Open the new Services ID, tick **Sign In with Apple**,
   **Configure**.
   - Primary App ID: `com.digitalatelier.wardroberedo`
   - Domains and Subdomains: `<your-supabase-project-ref>.supabase.co`
     (e.g. `xavxlsutdcvllbvmxoma.supabase.co`)
   - Return URLs: `https://<your-supabase-project-ref>.supabase.co/auth/v1/callback`
   - **Next → Done → Continue → Save**.
3. **Keys** → **+** → name `Wardrobe Sign In with Apple Key`.
   - Tick **Sign In with Apple**, **Configure**, pick the App ID
     `com.digitalatelier.wardroberedo`, **Save**.
   - **Continue → Register → Download** (the `.p8` file —
     **Apple lets you download it once**, save somewhere safe).
   - Note the **Key ID** (10 characters) and your **Team ID** (top
     right corner of the developer portal — 10 characters).

## 2. Supabase dashboard

Open <https://supabase.com/dashboard/project/xavxlsutdcvllbvmxoma>
(replace with your project ref).

### 2a. Enable the Apple provider

1. **Authentication** → **Providers** → **Apple** → toggle **Enable
   Sign in with Apple**.

### 2b. Fill in the credentials

| Field | Value |
|---|---|
| Services ID (or Client ID) | `com.digitalatelier.wardroberedo` (the **App ID**, not the Services ID — for native iOS Sign In with Apple, Supabase verifies against the App ID's `aud` claim) |
| Secret Key (for OAuth) | Paste the entire contents of the `.p8` file from step 1b |
| Key ID | The 10-char Key ID from step 1b |
| Team ID | Your Apple developer Team ID (10 chars) |

3. **Save**.

### 2c. (Optional) Authorized client IDs for native + web

If you ever add a web client, paste both the App ID and the
Services ID into **Authorized Client IDs**. For TestFlight today
the App ID alone is enough.

## 3. Verify

1. Run TestFlight build with the Apple Sign In capability (Build
   32+ / TF36+).
2. Open the app on a real device.
3. Tap **Sign in with Apple**.
4. Authenticate with Face ID / Touch ID.
5. The app should navigate into the main tabs immediately — no
   email confirmation step, no password.

If the sheet appears but sign-in fails after Face ID:

- **"Invalid token"** in `[Auth] appleSignIn failed: …` Console
  log → the Services ID / Key ID / Team ID in Supabase is wrong.
  Re-check step 2b.
- **"Audience mismatch"** → Supabase's Client ID field needs to
  match the iOS App ID (`com.digitalatelier.wardroberedo`), not
  the Services ID.
- **Network errors** → Supabase project URL is wrong or DNS is
  down. Check `WardrobeReDo/Secrets.plist` matches the dashboard.

## 4. Auto-creating profiles

Supabase's default Apple flow creates a row in `auth.users` but
NOT in `profiles`. Wardrobe's profile-load path expects every
authenticated user to have a profile row.

Existing trigger `handle_new_user` (in the migrations folder)
already runs on `auth.users` insert and creates a profile with
a fallback display name. For Apple Sign In, the trigger reads
`raw_user_meta_data->'full_name'` if present; otherwise it
falls back to the email prefix. No changes needed for now —
verify by signing in once and checking that a new row appears
in `public.profiles`.

If signing in succeeds but the app sits on the loading screen
afterwards, the trigger may have failed. Check Supabase logs:
**Logs Explorer** → **postgres** → look for `handle_new_user`.
