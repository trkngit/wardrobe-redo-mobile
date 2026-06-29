-- 00018_formality_unit_scale.sql
-- TF52 — Align the database formality contract with the app's canonical
-- [0, 1] scale and make the client (`FormalityFormula`) the single source
-- of truth.
--
-- Background: the initial schema (00001) shipped a 0–10 formality model —
-- `compute_formality(jsonb)` plus an `auto_compute_formality` trigger that
-- recomputed `formality_computed` whenever `formality_components` changed,
-- with a 0–10 CHECK added in 00003. The app never wired any of it up: it
-- never sent `formality_components`/`formality_computed`, so the columns
-- stayed NULL and the Swift scorer always computed formality on its own
-- [0, 1] scale. Two formality models on different scales, only one live.
--
-- TF52 starts persisting client-computed formality at add time, so we
-- retire the dormant 0–10 machinery here rather than let the trigger
-- overwrite the client's [0, 1] value with a 0–10 recomputation on insert.

-- 1. Retire the server-side recompute. Drop the trigger first (it depends
--    on the function), then the now-orphaned functions.
DROP TRIGGER IF EXISTS wardrobe_items_compute_formality ON wardrobe_items;
DROP FUNCTION IF EXISTS auto_compute_formality();
DROP FUNCTION IF EXISTS compute_formality(JSONB);

-- 2. Re-scale the stored value to [0, 1]. Every existing row has
--    formality_computed = NULL (it was never written), so dropping the old
--    0–10 bound, widening precision, and tightening the range to [0, 1]
--    cannot truncate or invalidate live data. NUMERIC(4,3) keeps 3 decimals
--    of fidelity for the scorer's spread thresholds (0.1 / 0.2 / 0.35).
ALTER TABLE wardrobe_items
    DROP CONSTRAINT IF EXISTS chk_formality_computed;

ALTER TABLE wardrobe_items
    ALTER COLUMN formality_computed TYPE NUMERIC(4,3);

ALTER TABLE wardrobe_items
    ADD CONSTRAINT chk_formality_computed CHECK (
        formality_computed IS NULL OR (formality_computed >= 0 AND formality_computed <= 1)
    );

-- `formality_components` stays a free-form JSONB column. It is now written
-- by the client (`FormalityFormula`) as normalized [0, 1] component signals
-- (color_brightness, texture_smoothness, pattern_scale, structural_score)
-- for explainability, and is no longer read back by any server logic.

-- NOTE: `style_archetypes.formality_min/max` (00001) are likewise on the
-- legacy 0–10 default scale but are dormant — archetypes load from the
-- bundled archetypes.json ([0, 1]) at runtime, not from this table. Left
-- untouched here to keep this migration scoped to the live write path.
