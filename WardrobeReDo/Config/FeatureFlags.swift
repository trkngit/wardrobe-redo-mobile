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

    // MARK: - Test / Preview helpers

    /// Reset every flag to its compiled-in default. Used by tests so the
    /// suite can run in any order without leaking UserDefaults state.
    static func resetAll() {
        defaults.removeObject(forKey: Key.multiGarmentEnabled)
        logger.debug("all flags reset")
    }
}
