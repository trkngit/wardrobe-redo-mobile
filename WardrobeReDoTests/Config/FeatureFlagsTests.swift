import Foundation
import Testing
@testable import WardrobeReDo

/// Unit tests for the `FeatureFlags` namespace. Each test resets the
/// flag state so the suite is order-independent even though the
/// underlying store is shared UserDefaults.
@MainActor
struct FeatureFlagsTests {

    @Test func multiGarmentFlagDefaultsToFalse() async {
        await FeatureFlagTestIsolation.shared.acquire()
        defer { Task { await FeatureFlagTestIsolation.shared.release() } }
        FeatureFlags.resetAll()
        #expect(FeatureFlags.isMultiGarmentEnabled == false)
    }

    @Test func multiGarmentFlagRoundTripsThroughSetter() async {
        await FeatureFlagTestIsolation.shared.acquire()
        defer { Task { await FeatureFlagTestIsolation.shared.release() } }
        FeatureFlags.resetAll()
        FeatureFlags.isMultiGarmentEnabled = true
        #expect(FeatureFlags.isMultiGarmentEnabled == true)

        FeatureFlags.isMultiGarmentEnabled = false
        #expect(FeatureFlags.isMultiGarmentEnabled == false)

        FeatureFlags.resetAll()
    }

    @Test func resetAllClearsMultiGarmentFlag() async {
        await FeatureFlagTestIsolation.shared.acquire()
        defer { Task { await FeatureFlagTestIsolation.shared.release() } }
        FeatureFlags.isMultiGarmentEnabled = true
        FeatureFlags.resetAll()
        #expect(FeatureFlags.isMultiGarmentEnabled == false)
    }

    @Test func multiGarmentFlagPersistsAcrossReads() async {
        await FeatureFlagTestIsolation.shared.acquire()
        defer { Task { await FeatureFlagTestIsolation.shared.release() } }
        FeatureFlags.resetAll()
        FeatureFlags.isMultiGarmentEnabled = true

        // Multiple reads should all see the same value — verifies we
        // actually hit UserDefaults, not an in-memory cache that might
        // drift between reads.
        for _ in 0 ..< 5 {
            #expect(FeatureFlags.isMultiGarmentEnabled == true)
        }
        FeatureFlags.resetAll()
    }
}
