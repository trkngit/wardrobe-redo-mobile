-- Migration 00013: wardrobe_items bounding_box
--
-- Adds a nullable JSONB column to persist the normalized [0, 1]
-- bounding box of the detected garment within `source_photo_path`.
-- Item detail view uses this to dim everything outside the bbox so
-- two items captured from the same source photo (multi-pick batch)
-- look visually distinct. Null for legacy items predating the
-- multi-garment flow OR for single-item captures where no bbox was
-- recorded — the detail view falls back to a plain image render in
-- that case.
--
-- Format: {"x":0.1,"y":0.4,"width":0.3,"height":0.5}
-- Coordinates are normalized so they survive any future image
-- resize / re-encode without needing to recompute against pixel
-- dimensions.
--
-- Backward compatibility: existing rows get NULL on apply. The
-- upload-queue retry path already constructs `NewWardrobeItem`
-- without a bbox; this stays valid.
--
-- No index — bounding boxes are read on detail view only, never
-- queried or sorted on.

ALTER TABLE public.wardrobe_items
ADD COLUMN bounding_box JSONB;

COMMENT ON COLUMN public.wardrobe_items.bounding_box IS
    'Normalized [0,1] bounding box of the detected garment within '
    'source_photo_path. Null for legacy items predating the multi-'
    'garment flow OR single-item captures. Format: '
    '{"x":0.1,"y":0.4,"width":0.3,"height":0.5}.';
