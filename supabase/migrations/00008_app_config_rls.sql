-- ============================================================
-- Migration 00008: lock down public.app_config
-- ============================================================
--
-- Context:
--   The Supabase security advisor (lint 0013_rls_disabled_in_public)
--   flagged public.app_config as PostgREST-exposed without RLS. The
--   table was created in migration 00005 to hold two key/value pairs
--   used by the send_welcome_email() trigger:
--     - welcome_from_address
--     - welcome_subject
--
--   Because the table is in the `public` schema, PostgREST exposes it,
--   and Supabase's default grants give `anon` and `authenticated` full
--   CRUD + TRUNCATE. Combined with RLS disabled, that means anyone with
--   the anon key could read, edit, or wipe the table.
--
--   The only legitimate caller is public.send_welcome_email(), which
--   is SECURITY DEFINER, owned by `postgres`, and therefore bypasses
--   RLS (postgres has rolbypassrls = true). Enabling RLS with zero
--   policies is safe for the trigger and default-denies anon /
--   authenticated access through PostgREST.
--
-- Changes:
--   1. Revoke the broad CRUD grants from `anon` and `authenticated`.
--   2. Enable row-level security on public.app_config.
--   3. Force RLS even for the table owner when reading through
--      PostgREST-facing roles (belt-and-suspenders; the trigger still
--      works because SECURITY DEFINER runs as postgres, which bypasses
--      RLS unconditionally).
--   4. Deliberately add NO policies — default-deny.
--
--   service_role keeps its grants intact for server-side maintenance
--   (dashboard SQL editor, edge functions using the service key, etc.).
--
-- Rollback:
--   ALTER TABLE public.app_config DISABLE ROW LEVEL SECURITY;
--   GRANT SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER
--     ON public.app_config TO anon, authenticated;
-- ============================================================

REVOKE ALL ON public.app_config FROM anon;
REVOKE ALL ON public.app_config FROM authenticated;

ALTER TABLE public.app_config ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.app_config FORCE  ROW LEVEL SECURITY;

COMMENT ON TABLE public.app_config IS
    'Key/value config read by SECURITY DEFINER triggers only (e.g. send_welcome_email). Default-deny for anon/authenticated: no policies, grants revoked. Manage via the Supabase dashboard or a service-role connection.';
