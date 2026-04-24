-- ============================================================
-- Migration 00011: opt-in ML inference telemetry
-- ============================================================
--
-- Context:
--   `MLDiagnosticsStore` (DEBUG-only) already captures the last ten
--   multi-garment inferences in-memory. That surface is invisible to
--   us — it only helps when a developer is on the phone with a user.
--   For the attribute-classifier dogfood (Plan D, Phase 9) we need
--   production visibility: fire rate, correction rate per field,
--   latency distribution by compute unit. This migration creates an
--   opt-in, privacy-first table for that.
--
-- Privacy posture:
--   * No image bytes. No crops. No colors. Only timing + label +
--     confidence + whether the user corrected the pre-fill.
--   * RLS restricts inserts to `auth.uid() = user_id`. No SELECT
--     policy: analysis is done by the service role in the dashboard,
--     end users never read each other's telemetry.
--   * The client gate `FeatureFlags.isMLTelemetryEnabled` defaults to
--     `false`. Nothing lands in this table until a dogfooder flips it
--     on in the Developer menu.
--   * `ON DELETE CASCADE` on user_id means a deleted account wipes
--     its entire telemetry history — the GDPR right-to-erasure
--     path doesn't require any application-layer cleanup.
--
-- Down-migration:
--   `drop table if exists public.ml_inference_telemetry cascade;`
--   The CASCADE drops any policies attached. Safe because no other
--   table references this one.
--
-- ============================================================

CREATE TABLE IF NOT EXISTS public.ml_inference_telemetry (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id         UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,

    -- Model identity
    model_name      TEXT NOT NULL,
    -- "multi_garment" | "attribute_classifier" | future: "color_extractor"
    -- Free-form because each model's telemetry shape may evolve; we
    -- filter by this column at analysis time.
    surface         TEXT NOT NULL,

    -- Timing
    latency_ms      DOUBLE PRECISION NOT NULL,
    -- MLDiagnosticsStore.inferredComputeUnit ("ANE (likely)" / …).
    -- Best-effort heuristic — Apple doesn't expose lane metadata at
    -- runtime so this is a timing-band string, not a strict enum.
    compute_unit    TEXT,

    -- Outcome
    -- proposal_count is only meaningful for detection surfaces
    -- (multi_garment). NULL for classification-only surfaces.
    proposal_count  INTEGER,
    -- Top prediction's raw class label + confidence. For detection
    -- surfaces this is the hero proposal; for classifiers it's the
    -- argmax class. NULL when the call threw.
    top_class_raw   TEXT,
    top_score       REAL,
    threw           BOOLEAN NOT NULL DEFAULT FALSE,

    -- Pre-fill bookkeeping (attribute classifier)
    -- Set by the Add Item form after the user completes save:
    --   * prefill_fired = true if the model's prediction was shown
    --   * user_corrected = true if the user changed the value before save
    -- Both NULL on surfaces that don't pre-fill anything.
    prefill_fired   BOOLEAN,
    user_corrected  BOOLEAN,
    field_changed   TEXT,     -- which field (category / texture / fit / …)

    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Frequent filter: per-user + model for "how does this dogfooder do
-- on the classifier over the last 7 days" queries.
CREATE INDEX IF NOT EXISTS ml_inference_telemetry_user_model_created_idx
    ON public.ml_inference_telemetry (user_id, surface, created_at DESC);

-- Row-level security: users may only insert their own rows. No
-- SELECT policy — dashboard analysis runs with the service role,
-- which bypasses RLS by design.
ALTER TABLE public.ml_inference_telemetry ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users insert their own ML telemetry"
    ON public.ml_inference_telemetry;
CREATE POLICY "Users insert their own ML telemetry"
    ON public.ml_inference_telemetry
    FOR INSERT
    TO authenticated
    WITH CHECK (auth.uid() = user_id);

COMMENT ON TABLE public.ml_inference_telemetry IS
    'Opt-in per-inference telemetry for on-device Core ML models. '
    'Gated by FeatureFlags.isMLTelemetryEnabled on the client. '
    'No image bytes stored; only timing + label + correction flag.';
