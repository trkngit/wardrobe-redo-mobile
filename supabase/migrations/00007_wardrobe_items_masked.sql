-- ============================================================
-- Migration 00007: masked-image provenance on wardrobe_items
-- ============================================================
--
-- Context:
--   Phase 1 of the extraction-engine upgrade introduces on-device
--   background removal via Vision's VNGenerateForegroundInstanceMask-
--   Request. Every new upload now gets a masked JPEG alongside the
--   original, stored at a second path under the same user folder.
--
--   We also keep a string flag recording how confident we are in the
--   mask, so the UI can render an "auto-cropped" badge when the
--   confidence is low and the user may want to touch it up.
--
-- Changes:
--   - Add `masked_image_path TEXT` — path in the wardrobe-images
--     bucket to the masked JPEG (nullable: existing rows stay NULL
--     and render from `image_path` as "legacy unmasked").
--   - Add `extraction_confidence TEXT` — one of 'high' | 'medium' |
--     'low' | 'failed'. Nullable for the same reason.
--
-- Rollback:
--   Both columns are additive and nullable, so this migration is
--   safe to revert with ALTER TABLE ... DROP COLUMN.
-- ============================================================

ALTER TABLE wardrobe_items
    ADD COLUMN IF NOT EXISTS masked_image_path       TEXT,
    ADD COLUMN IF NOT EXISTS extraction_confidence   TEXT
        CHECK (extraction_confidence IN ('high', 'medium', 'low', 'failed'));

COMMENT ON COLUMN wardrobe_items.masked_image_path IS
    'Storage path to the background-masked JPEG produced by ClothingExtractionService. NULL for rows uploaded before migration 00007.';

COMMENT ON COLUMN wardrobe_items.extraction_confidence IS
    'Synthetic confidence bucket for the mask: high | medium | low | failed. See ExtractionConfidence enum in Swift.';
