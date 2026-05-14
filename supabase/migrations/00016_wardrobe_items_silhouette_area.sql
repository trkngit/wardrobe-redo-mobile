-- Build 6 Phase 8B — per-item silhouette area as a fraction of
-- the source-photo frame.
--
-- Computed at extraction time by
-- `VisionForegroundExtractor.coverageRatio(of:)` and persisted so
-- `ColorHarmonyScorer` can modulate the category-default
-- silhouette weight by actual visual mass. An oversized top
-- (high coverage) outweighs a fitted one (low coverage) within
-- the same category.
--
-- Value is in [0, 1]. NULL for rows uploaded before this
-- migration; the iOS client decodes via `decodeIfPresent` and
-- the scorer falls back to `ClothingCategory.defaultSilhouetteFraction`
-- alone for nil rows (Phase 8A behaviour).
--
-- Pattern matches 00013_wardrobe_items_bounding_box.sql:
-- additive nullable column, `IF NOT EXISTS`, no backfill.

alter table wardrobe_items
    add column if not exists silhouette_area double precision
    check (silhouette_area is null or (silhouette_area >= 0 and silhouette_area <= 1));

comment on column wardrobe_items.silhouette_area is
    'Fraction of the source photo frame covered by the item''s extracted mask (0..1). Set at extraction time by the iOS client. NULL for pre-build-6-phase-8 rows.';
