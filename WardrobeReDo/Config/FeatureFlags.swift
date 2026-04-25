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
        static let mlTelemetryEnabled = "feature.mlTelemetry.enabled"
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

    // MARK: - Test / Preview helpers

    /// Reset every flag to its compiled-in default. Used by tests so the
    /// suite can run in any order without leaking UserDefaults state.
    static func resetAll() {
        defaults.removeObject(forKey: Key.multiGarmentEnabled)
        defaults.removeObject(forKey: Key.attributeDetectionEnabled)
        defaults.removeObject(forKey: Key.mlTelemetryEnabled)
        logger.debug("all flags reset")
    }
}
