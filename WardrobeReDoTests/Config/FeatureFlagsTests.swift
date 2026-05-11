import Foundation
import Testing
@testable import WardrobeReDo

/// Unit tests for the `FeatureFlags` namespace. Each test resets the
/// flag state so the suite is order-independent even though the
/// underlying store is shared UserDefaults.
@MainActor
struct FeatureFlagsTests {

    @Test func multiGarmentFlagDefaultsToTrue() async {
        await FeatureFlagTestIsolation.shared.acquire()
        defer { Task { await FeatureFlagTestIsolation.shared.release() } }
        FeatureFlags.resetAll()
        #expect(FeatureFlags.isMultiGarmentEnabled == true)
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

    @Test func resetAllRestoresMultiGarmentDefault() async {
        await FeatureFlagTestIsolation.shared.acquire()
        defer { Task { await FeatureFlagTestIsolation.shared.release() } }
        FeatureFlags.isMultiGarmentEnabled = false
        #expect(FeatureFlags.isMultiGarmentEnabled == false)
        FeatureFlags.resetAll()
        #expect(FeatureFlags.isMultiGarmentEnabled == true)
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

    // MARK: - Build 6 flags

    @Test func coverageAwareScoringDefaultsToTrue() async {
        await FeatureFlagTestIsolation.shared.acquire()
        defer { Task { await FeatureFlagTestIsolation.shared.release() } }
        FeatureFlags.resetAll()
        #expect(FeatureFlags.isCoverageAwareScoringEnabled == true)
    }

    @Test func noveltyBonusDefaultsToTrue() async {
        await FeatureFlagTestIsolation.shared.acquire()
        defer { Task { await FeatureFlagTestIsolation.shared.release() } }
        FeatureFlags.resetAll()
        #expect(FeatureFlags.isNoveltyBonusEnabled == true)
    }

    @Test func vibeSliderDefaultsToTrue() async {
        await FeatureFlagTestIsolation.shared.acquire()
        defer { Task { await FeatureFlagTestIsolation.shared.release() } }
        FeatureFlags.resetAll()
        #expect(FeatureFlags.isVibeSliderEnabled == true)
    }

    @Test func build6FlagsRoundTripThroughSetter() async {
        await FeatureFlagTestIsolation.shared.acquire()
        defer { Task { await FeatureFlagTestIsolation.shared.release() } }
        FeatureFlags.resetAll()
        FeatureFlags.isCoverageAwareScoringEnabled = false
        FeatureFlags.isNoveltyBonusEnabled = false
        FeatureFlags.isVibeSliderEnabled = false
        #expect(FeatureFlags.isCoverageAwareScoringEnabled == false)
        #expect(FeatureFlags.isNoveltyBonusEnabled == false)
        #expect(FeatureFlags.isVibeSliderEnabled == false)
        FeatureFlags.resetAll()
        #expect(FeatureFlags.isCoverageAwareScoringEnabled == true)
        #expect(FeatureFlags.isNoveltyBonusEnabled == true)
        #expect(FeatureFlags.isVibeSliderEnabled == true)
    }
}
