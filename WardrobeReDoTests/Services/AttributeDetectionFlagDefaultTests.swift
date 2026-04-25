import Foundation
import Testing
@testable import WardrobeReDo

/// Coverage for the Phase 9 flip — `FeatureFlags.isAttributeDetectionEnabled`
/// must default to `true` for users who haven't toggled it. Without this
/// flip, every multi-pick capture lands the per-item form on legacy
/// defaults (Tops / T-Shirt / blank texture / blank fit / all-seasons /
/// casual) — which was the dogfood-blocking regression in build 2.
///
/// We verify two contracts:
///   1. Fresh install (no UserDefaults key) returns `true`.
///   2. An existing user who explicitly toggled the flag off keeps
///      their setting — the persisted value wins, the default only
///      applies when the key has never been written.
@MainActor
@Suite("AttributeDetection flag default", .serialized)
struct AttributeDetectionFlagDefaultTests {

    @Test func defaultsToTrueWhenKeyHasNeverBeenWritten() async {
        await FeatureFlagTestIsolation.shared.acquire()
        defer { Task { await FeatureFlagTestIsolation.shared.release() } }

        // Wipe any persisted value so the default fallback path runs.
        UserDefaults.standard.removeObject(forKey: "feature.attributeDetection.enabled")

        #expect(FeatureFlags.isAttributeDetectionEnabled == true)
    }

    @Test func explicitlyDisabledStaysDisabled() async {
        await FeatureFlagTestIsolation.shared.acquire()
        defer { Task { await FeatureFlagTestIsolation.shared.release() } }

        FeatureFlags.isAttributeDetectionEnabled = false
        #expect(FeatureFlags.isAttributeDetectionEnabled == false)

        // Cleanup so subsequent tests start from the default again.
        UserDefaults.standard.removeObject(forKey: "feature.attributeDetection.enabled")
    }

    @Test func explicitlyEnabledStaysEnabled() async {
        await FeatureFlagTestIsolation.shared.acquire()
        defer { Task { await FeatureFlagTestIsolation.shared.release() } }

        FeatureFlags.isAttributeDetectionEnabled = true
        #expect(FeatureFlags.isAttributeDetectionEnabled == true)

        UserDefaults.standard.removeObject(forKey: "feature.attributeDetection.enabled")
    }
}
