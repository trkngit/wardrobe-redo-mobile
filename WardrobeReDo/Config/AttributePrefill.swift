import Foundation

/// Confidence thresholds for auto-attribute pre-fill on the Add Item
/// form. Predictions below the threshold are treated as "no prediction"
/// — the picker stays empty / falls back to the legacy default rather
/// than showing a low-confidence guess the user has to immediately
/// override.
///
/// Threshold calibrated in the Phase 3 attribute-classifier training
/// notebook (`eval_attributes.py`): at 0.80 softmax the per-head realized
/// accuracy is ≥0.90 on held-out Fashionpedia val, which is the "don't
/// annoy the user with wrong guesses" floor set in the plan's Q3 answer.
///
/// See [2026-04-19-auto-attribute-detection.md](../../docs/plans/2026-04-19-auto-attribute-detection.md)
/// Phase 0 for the full rationale.
enum AttributePrefill {
    /// Minimum softmax confidence required for a prediction to pre-fill
    /// a user-facing picker. Applied per-field, independently.
    static let minConfidence: Float = 0.80

    /// True when `confidence` passes the pre-fill bar. 0.0 is the
    /// "no prediction" sentinel used by `MaskProposal` fields that
    /// haven't been populated yet (e.g. before the attribute classifier
    /// ships) — it always returns false.
    static func shouldPrefill(_ confidence: Float) -> Bool {
        confidence >= minConfidence
    }
}
