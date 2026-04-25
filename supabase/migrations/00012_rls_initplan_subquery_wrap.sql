-- 00012_rls_initplan_subquery_wrap.sql
--
-- Wrap auth.uid() and auth.role() calls in (select ...) subqueries so the
-- PostgreSQL planner evaluates the auth function once per query instead of
-- once per row. Resolves all 10 `auth_rls_initplan` WARN-level findings
-- from Supabase's performance advisor.
--
-- See: https://supabase.com/docs/guides/database/postgres/row-level-security#call-functions-with-select
--
-- RLS semantics are unchanged — the wrap is purely a planner hint.
-- Each policy is dropped and recreated with the new predicate; `DROP POLICY
-- IF EXISTS` makes the migration safe to rerun.
--
-- Affected policies (10):
--   profiles                * Users can view own profile
--   profiles                * Users can update own profile
--   profiles                * Users can insert own profile
--   wardrobe_items          * Users can CRUD own items
--   item_style_tags         * Users can access own item tags
--   outfits                 * Users can CRUD own outfits
--   outfit_slots            * Users can access own outfit slots
--   style_archetypes        * Authenticated users can read archetypes
--   style_rules             * Authenticated users can read rules
--   ml_inference_telemetry  * Users insert their own ML telemetry
--
-- Roles preserved per pg_policies snapshot taken 2026-04-25:
--   ml_inference_telemetry  → TO authenticated
--   all others              → no TO clause (defaults to PUBLIC)

-- ============================================================================
-- profiles
-- ============================================================================

DROP POLICY IF EXISTS "Users can view own profile" ON public.profiles;
CREATE POLICY "Users can view own profile" ON public.profiles
  FOR SELECT
  USING ((select auth.uid()) = id);

DROP POLICY IF EXISTS "Users can update own profile" ON public.profiles;
CREATE POLICY "Users can update own profile" ON public.profiles
  FOR UPDATE
  USING ((select auth.uid()) = id);

DROP POLICY IF EXISTS "Users can insert own profile" ON public.profiles;
CREATE POLICY "Users can insert own profile" ON public.profiles
  FOR INSERT
  WITH CHECK ((select auth.uid()) = id);

-- ============================================================================
-- wardrobe_items
-- ============================================================================

DROP POLICY IF EXISTS "Users can CRUD own items" ON public.wardrobe_items;
CREATE POLICY "Users can CRUD own items" ON public.wardrobe_items
  FOR ALL
  USING ((select auth.uid()) = user_id);

-- ============================================================================
-- item_style_tags
-- ============================================================================

DROP POLICY IF EXISTS "Users can access own item tags" ON public.item_style_tags;
CREATE POLICY "Users can access own item tags" ON public.item_style_tags
  FOR ALL
  USING (
    EXISTS (
      SELECT 1
      FROM public.wardrobe_items
      WHERE wardrobe_items.id = item_style_tags.wardrobe_item_id
        AND wardrobe_items.user_id = (select auth.uid())
    )
  );

-- ============================================================================
-- outfits
-- ============================================================================

DROP POLICY IF EXISTS "Users can CRUD own outfits" ON public.outfits;
CREATE POLICY "Users can CRUD own outfits" ON public.outfits
  FOR ALL
  USING ((select auth.uid()) = user_id);

-- ============================================================================
-- outfit_slots
-- ============================================================================

DROP POLICY IF EXISTS "Users can access own outfit slots" ON public.outfit_slots;
CREATE POLICY "Users can access own outfit slots" ON public.outfit_slots
  FOR ALL
  USING (
    EXISTS (
      SELECT 1
      FROM public.outfits
      WHERE outfits.id = outfit_slots.outfit_id
        AND outfits.user_id = (select auth.uid())
    )
  );

-- ============================================================================
-- style_archetypes
-- ============================================================================

DROP POLICY IF EXISTS "Authenticated users can read archetypes" ON public.style_archetypes;
CREATE POLICY "Authenticated users can read archetypes" ON public.style_archetypes
  FOR SELECT
  USING ((select auth.role()) = 'authenticated');

-- ============================================================================
-- style_rules
-- ============================================================================

DROP POLICY IF EXISTS "Authenticated users can read rules" ON public.style_rules;
CREATE POLICY "Authenticated users can read rules" ON public.style_rules
  FOR SELECT
  USING ((select auth.role()) = 'authenticated');

-- ============================================================================
-- ml_inference_telemetry
-- ============================================================================

DROP POLICY IF EXISTS "Users insert their own ML telemetry" ON public.ml_inference_telemetry;
CREATE POLICY "Users insert their own ML telemetry" ON public.ml_inference_telemetry
  FOR INSERT
  TO authenticated
  WITH CHECK ((select auth.uid()) = user_id);
