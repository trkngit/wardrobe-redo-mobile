-- ============================================================
-- Migration 00009: ML correction telemetry on wardrobe_items
-- ============================================================
--
-- Context:
--   Phase 7 of `docs/plans/2026-04-19-auto-attribute-detection.md`
--   introduces auto pre-fill for category / subcategory / texture /
--   fit / seasons / occasions on the Add Item form. Each field is
--   seeded from ML output (≥0.80 confidence) and remains user-
--   editable. To know whether the pre-fill is helping — and which
--   fields need the rules table / classifier tuned — we need to know
--   for every wardrobe_items row:
--
--     - did the ML pre-fill a value, or did the user type it from
--       scratch?
--     - did the user accept the ML value, or override it?
--
--   A single JSONB column captures that without requiring a
--   per-field schema: the map is keyed by field name (the same
--   strings the iOS code already uses — "category", "subcategory",
--   "texture", "fit", "seasons", "occasions") and the value is one
--   of three provenance markers:
--
--     - "ai"                    — pre-fill cleared the ≥0.80 bar AND
--                                 the final user-saved value matches
--                                 the pre-fill
--     - "user"                  — ML never pre-filled this field
--                                 (below threshold or no prediction);
--                                 whatever the user saved is their
--                                 own answer
--     - "user_changed_from_ai"  — pre-fill landed but the user
--                                 touched the picker before saving;
--                                 the saved value is explicitly an
--                                 override
--
--   Legacy rows (uploaded before this migration) default to '{}' —
--   the My Wardrobe grid does not render anything about provenance,
--   so the NULL-to-'{}' move is cosmetic and invisible to users.
--
-- Changes:
--   - Add `detected_attributes JSONB NOT NULL DEFAULT '{}'::jsonb`.
--
-- Rollback:
--   Column is additive + NULL-safe; no indexes hang off it.
--     ALTER TABLE wardrobe_items DROP COLUMN IF EXISTS detected_attributes;
-- ============================================================

ALTER TABLE wardrobe_items
    ADD COLUMN IF NOT EXISTS detected_attributes JSONB NOT NULL DEFAULT '{}'::jsonb;

COMMENT ON COLUMN wardrobe_items.detected_attributes IS
    'Map of {field_name: "ai" | "user" | "user_changed_from_ai"} recording whether each auto-detected picker value (category / subcategory / texture / fit / seasons / occasions) came from the ML pre-fill, from the user typing from scratch, or from a user override of a pre-fill. Empty map for rows created before migration 00009. Powers correction-rate telemetry for the attribute classifier + rules table.';
