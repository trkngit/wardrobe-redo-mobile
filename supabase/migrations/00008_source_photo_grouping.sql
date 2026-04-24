-- ============================================================
-- Migration 00008: per-garment multi-item capture from one photo
-- ============================================================
--
-- Context:
--   Shipping the "Save & add another garment" loop means one
--   capture (a user in a suit) can produce N wardrobe_items rows —
--   jacket, tie, shirt, pants — all cropped out of the same source
--   photo via SAM2 tap-to-select. To keep the "grouped by capture"
--   UX viable and to stop re-uploading the same unmasked original
--   N times, we record provenance on each row:
--
--     - source_photo_id   UUID:  shared across every garment cut
--                                out of the same capture.
--     - source_photo_path TEXT:  storage path to the unmasked
--                                original in the wardrobe-images
--                                bucket, under
--                                {user_id}/source/{source_photo_id}/original.jpg.
--                                Uploaded exactly once per capture
--                                and reused by every garment row.
--
--   Legacy rows — everything uploaded before this migration — stay
--   NULL on both columns. The My Wardrobe grid renders them exactly
--   as today (individual items, no grouping badge). A later UX PR
--   will light up the "Grouped from one capture" affordance for
--   non-NULL rows.
--
-- Changes:
--   - Add `source_photo_id UUID` and `source_photo_path TEXT`
--     (both nullable).
--   - Partial index on (user_id, source_photo_id) WHERE
--     source_photo_id IS NOT NULL for fast "all garments from this
--     capture" lookups without bloating the index for legacy rows.
--
-- Storage:
--   The existing `wardrobe-images` bucket RLS policy is scoped to
--   the first path segment being the owner's user_id, and the
--   `{user_id}/source/{source_photo_id}/original.jpg` prefix
--   matches that constraint — no RLS changes required.
--
-- Rollback:
--   Both columns are additive and nullable; the index is partial
--   and NOT UNIQUE. Safe to revert with:
--     DROP INDEX IF EXISTS idx_wardrobe_items_source_photo;
--     ALTER TABLE wardrobe_items
--         DROP COLUMN IF EXISTS source_photo_path,
--         DROP COLUMN IF EXISTS source_photo_id;
-- ============================================================

ALTER TABLE wardrobe_items
    ADD COLUMN IF NOT EXISTS source_photo_id   UUID,
    ADD COLUMN IF NOT EXISTS source_photo_path TEXT;

CREATE INDEX IF NOT EXISTS idx_wardrobe_items_source_photo
    ON wardrobe_items (user_id, source_photo_id)
    WHERE source_photo_id IS NOT NULL;

COMMENT ON COLUMN wardrobe_items.source_photo_id IS
    'UUID shared across every wardrobe_items row cut out of the same source capture. NULL for rows uploaded before migration 00008 and for single-item captures that never entered the multi-garment loop.';

COMMENT ON COLUMN wardrobe_items.source_photo_path IS
    'Storage path to the unmasked original JPEG in the wardrobe-images bucket, at {user_id}/source/{source_photo_id}/original.jpg. Uploaded once per capture, reused by every garment row with the same source_photo_id. NULL when source_photo_id is NULL.';
