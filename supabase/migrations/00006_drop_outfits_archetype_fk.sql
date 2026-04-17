-- ============================================================
-- Migration 00006: relax outfits.archetype_id to a soft reference
-- ============================================================
--
-- Context:
--   The 00001 schema defined `outfits.archetype_id UUID NOT NULL
--   REFERENCES style_archetypes(id)`. However, the app ships with a
--   bundled JSON catalog of 50 archetypes + 200 rules that the outfit
--   generator uses as its primary source. The style_archetypes table
--   in Supabase is currently only partially seeded (12 archetypes via
--   00002_seed_style_data.sql), so most bundled UUIDs do not have a
--   matching DB row.
--
--   Result: every INSERT into outfits raised 23503
--     foreign key constraint "outfits_archetype_id_fkey"
--   and the Outfits tab surfaced "Something went wrong: PostgrestError".
--
-- Fix:
--   Drop the FK constraint. Keep the column NOT NULL so the app still
--   stores the archetype UUID for provenance / analytics, but no longer
--   require the referenced row to exist in style_archetypes. The
--   editorial_name is already denormalized onto each outfits row, so
--   rendering doesn't need the FK-resolved lookup.
--
-- When the full 50-archetype + 200-rule seed ships to Supabase, this
-- FK can be re-added — but the bundled fallback will still work
-- regardless.

ALTER TABLE outfits
    DROP CONSTRAINT IF EXISTS outfits_archetype_id_fkey;
