import Foundation
import os.log

/// Lightweight, UserDefaults-backed feature-flag namespace.
///
/// Used as an in-app kill switch for features that ship behind a gate
/// (e.g. multi-garment detection) so we can disable them without an app
/// update if the model misbehaves in the wild. Flags default to `false`
/// until explicitly toggled by a user in the Developer menu.
///
/// A scheduled successor may layer remote-config on top — for v1 a
/// local flag is enough, because the model ships inside the bundle and
/// any fix requires an App Store update anyway.
@MainActor
enum FeatureFlags {
    private static let defaults = UserDefaults.standard
    private static let logger = Logger(subsystem: "com.wardroberedo", category: "FeatureFlags")

    // MARK: - Keys (centralised so typos are caught at compile time)

    private enum Key {
        static let multiGarmentEnabled = "feature.multiGarment.enabled"
        static let attributeDetectionEnabled = "feature.attributeDetection.enabled"
        static let fastAddEnabled = "feature.fastAdd.enabled"
        static let mlTelemetryEnabled = "feature.mlTelemetry.enabled"
        // Build 6 — engine-feature kill switches
        static let coverageAwareScoringEnabled = "feature.coverageAwareScoring.enabled"
        static let noveltyBonusEnabled = "feature.noveltyBonus.enabled"
        static let vibeSliderEnabled = "feature.vibeSlider.enabled"
    }

    // MARK: - Flags

    /// Master switch for multi-garment detection + multi-pick save loop.
    ///
    /// Default: `true`. Trained Core ML model ships inside the bundle and
    /// real-weights inference is validated end-to-end. When explicitly
    /// toggled off via the Developer menu the persisted value wins; the
    /// default only applies when the key has never been written.
    static var isMultiGarmentEnabled: Bool {
        get {
            if defaults.object(forKey: Key.multiGarmentEnabled) == nil { return true }
            return defaults.bool(forKey: Key.multiGarmentEnabled)
        }
        set {
            defaults.set(newValue, forKey: Key.multiGarmentEnabled)
            logger.info("multiGarment toggled -> \(newValue, privacy: .public)")
        }
    }

    /// Master switch for auto-attribute pre-fill (texture, fit, seasons,
    /// occasions) on the Add Item form. Gate separate from
    /// `isMultiGarmentEnabled` so we can roll out category-only pre-fill
    /// via the rules engine while the attribute classifier is still
    /// baking in Phase 3 training.
    ///
    /// Default: `true`. Phase 9 flip — the rules engine ships in the
    /// bundle, the attribute classifier gracefully no-ops when its
    /// model file is missing, and the rules-derived seasons / occasions
    /// (PR #10) and texture (PR #11) are validated end-to-end. Existing
    /// users who explicitly toggled the flag off in the Developer menu
    /// keep their setting because the persisted value wins; the default
    /// only applies when the key has never been written (clean install
    /// or first launch after this change).
    static var isAttributeDetectionEnabled: Bool {
        get {
            if defaults.object(forKey: Key.attributeDetectionEnabled) == nil { return true }
            return defaults.bool(forKey: Key.attributeDetectionEnabled)
        }
        set {
            defaults.set(newValue, forKey: Key.attributeDetectionEnabled)
            logger.info("attributeDetection toggled -> \(newValue, privacy: .public)")
        }
    }

    /// Master switch for the Build 52 "Fast Add" flow — best-guess
    /// auto-fill (always commit the model's top category / subcategory /
    /// fit guess instead of gating on 0.90 confidence) plus the collapsed
    /// Fast Confirm card, where Occasion is the only surfaced input and
    /// everything else is auto-derived and tucked behind "Edit details".
    /// Reverses the TF47 strict-prefill behavior in favor of speed: the
    /// user fixes a wrong category in one tap, and `detectedAttributes`
    /// provenance still records AI vs user.
    ///
    /// Default: `true` (the new flow is the point of the build). Toggling
    /// off in the Developer menu restores the TF47 strict gate + full form.
    static var isFastAddEnabled: Bool {
        get {
            if defaults.object(forKey: Key.fastAddEnabled) == nil { return true }
            return defaults.bool(forKey: Key.fastAddEnabled)
        }
        set {
            defaults.set(newValue, forKey: Key.fastAddEnabled)
            logger.info("fastAdd toggled -> \(newValue, privacy: .public)")
        }
    }

    /// Gate for uploading on-device ML inference telemetry to the
    /// Supabase `ml_inference_telemetry` table (migration 00011).
    ///
    /// Default: `false`. Opt-in per device via the Developer menu.
    /// When off, `MLTelemetryService.logInference(...)` no-ops and no
    /// network call is made — the in-memory `MLDiagnosticsStore` ring
    /// buffer is unaffected so developers still get their DEBUG
    /// surface.
    ///
    /// When on, each inference (multi-garment detector + attribute
    /// classifier) fires a single INSERT with timing + top class +
    /// pre-fill correction flags. No image bytes leave the device —
    /// see `supabase/migrations/00011_ml_inference_telemetry.sql` for
    /// the full privacy rationale.
    static var isMLTelemetryEnabled: Bool {
        get {
            if defaults.object(forKey: Key.mlTelemetryEnabled) == nil { return false }
            return defaults.bool(forKey: Key.mlTelemetryEnabled)
        }
        set {
            defaults.set(newValue, forKey: Key.mlTelemetryEnabled)
            logger.info("mlTelemetry toggled -> \(newValue, privacy: .public)")
        }
    }

    // MARK: - Build 6 kill switches

    /// Master switch for the coverage-aware outfit-score aggregation
    /// (Phase 3). When `false`, callers should fall back to the
    /// pre-build-6 raw weighted sum `Σ wᵢ · sᵢ`. Default `true`;
    /// flip off via the Developer menu if user feedback shows the
    /// renormalized scores rank outfits worse than the legacy
    /// formula. Reading this flag inside `OutfitScore.init` is a
    /// follow-up — for now it documents the kill-switch intent.
    static var isCoverageAwareScoringEnabled: Bool {
        get {
            if defaults.object(forKey: Key.coverageAwareScoringEnabled) == nil { return true }
            return defaults.bool(forKey: Key.coverageAwareScoringEnabled)
        }
        set {
            defaults.set(newValue, forKey: Key.coverageAwareScoringEnabled)
            logger.info("coverageAwareScoring toggled -> \(newValue, privacy: .public)")
        }
    }

    /// Gate for `VersatilityScorer`'s novel-combination bonus
    /// (Phase 5.1). Default `true`. Disable if the novelty math
    /// over-penalizes long-time users whose entire wardrobe has
    /// been paired against itself.
    static var isNoveltyBonusEnabled: Bool {
        get {
            if defaults.object(forKey: Key.noveltyBonusEnabled) == nil { return true }
            return defaults.bool(forKey: Key.noveltyBonusEnabled)
        }
        set {
            defaults.set(newValue, forKey: Key.noveltyBonusEnabled)
            logger.info("noveltyBonus toggled -> \(newValue, privacy: .public)")
        }
    }

    /// Gate for the Phase 6 vibe slider. When `false` the UI hides
    /// the selector and the engine defaults every generation to
    /// `.balanced`. Default `true`.
    static var isVibeSliderEnabled: Bool {
        get {
            if defaults.object(forKey: Key.vibeSliderEnabled) == nil { return true }
            return defaults.bool(forKey: Key.vibeSliderEnabled)
        }
        set {
            defaults.set(newValue, forKey: Key.vibeSliderEnabled)
            logger.info("vibeSlider toggled -> \(newValue, privacy: .public)")
        }
    }

    // MARK: - Test / Preview helpers

    /// Reset every flag to its compiled-in default. Used by tests so the
    /// suite can run in any order without leaking UserDefaults state.
    static func resetAll() {
        defaults.removeObject(forKey: Key.multiGarmentEnabled)
        defaults.removeObject(forKey: Key.attributeDetectionEnabled)
        defaults.removeObject(forKey: Key.fastAddEnabled)
        defaults.removeObject(forKey: Key.mlTelemetryEnabled)
        defaults.removeObject(forKey: Key.coverageAwareScoringEnabled)
        defaults.removeObject(forKey: Key.noveltyBonusEnabled)
        defaults.removeObject(forKey: Key.vibeSliderEnabled)
        logger.debug("all flags reset")
    }
}
