import Foundation
import Testing
@testable import WardrobeReDo

/// Unit tests for `MultiGarmentSmokeTest.run(extractor:modelAvailable:)`.
/// The test doesn't care whether a real Core ML model is bundled — we
/// inject `MockMultiGarmentExtractor` so each code path is exercised
/// deterministically without a GPU-hours dependency.
///
/// `@Suite(.serialized)` because the smoke test writes to the
/// `MLDiagnosticsStore` singleton AND (on the failure path) to the
/// global `FeatureFlags` UserDefaults. Cross-suite isolation is enforced
/// via `MLDiagnosticsTestIsolation` (every test mutates the store) and
/// `FeatureFlagTestIsolation` (only the failure-path test also toggles
/// the flag). Without the diagnostics mutex, `MLDiagnosticsStoreTests`
/// could race a `resetAll()` into the middle of our smoke-test body and
/// flip `smokeTestStatus` back to `.notRun`.
@MainActor
@Suite(.serialized)
struct MultiGarmentSmokeTestTests {

    // MARK: - Skipped path (model not present)

    @Test func smokeTestSkipsWhenModelMissing() async {
        await MLDiagnosticsTestIsolation.shared.acquire()
        defer { Task { await MLDiagnosticsTestIsolation.shared.release() } }

        MLDiagnosticsStore.shared.resetAll()
        let extractor = MockMultiGarmentExtractor()

        let status = await MultiGarmentSmokeTest.run(
            extractor: extractor,
            modelAvailable: { false }
        )

        guard case .skipped(let reason) = status else {
            Issue.record("Expected .skipped, got \(status)")
            return
        }
        #expect(reason.contains("RFDETRSegFashion"),
                "Skipped reason should reference the model filename so developers immediately know why")
        #expect(extractor.detectCallCount == 0,
                "Skipped path must not invoke the extractor")
    }

    // MARK: - Passed path

    @Test func smokeTestPassesOnSuccessfulInference() async {
        await MLDiagnosticsTestIsolation.shared.acquire()
        defer { Task { await MLDiagnosticsTestIsolation.shared.release() } }

        MLDiagnosticsStore.shared.resetAll()
        let extractor = MockMultiGarmentExtractor()
        extractor.detectResult = []  // zero proposals is still success

        let status = await MultiGarmentSmokeTest.run(
            extractor: extractor,
            modelAvailable: { true }
        )

        guard case .passed(let latencyMs) = status else {
            Issue.record("Expected .passed, got \(status)")
            return
        }
        #expect(latencyMs >= 0)
        #expect(extractor.detectCallCount == 1)
        #expect(MLDiagnosticsStore.shared.smokeTestStatus == status,
                "Store should mirror the terminal status so the Developer menu can render it without re-running")
    }

    // MARK: - Failed path

    @Test func smokeTestFailsAndDisablesFlagOnThrow() async {
        await FeatureFlagTestIsolation.shared.acquire()
        defer { Task { await FeatureFlagTestIsolation.shared.release() } }
        await MLDiagnosticsTestIsolation.shared.acquire()
        defer { Task { await MLDiagnosticsTestIsolation.shared.release() } }

        MLDiagnosticsStore.shared.resetAll()
        FeatureFlags.resetAll()
        FeatureFlags.isMultiGarmentEnabled = true

        let extractor = MockMultiGarmentExtractor()
        extractor.detectError = MultiGarmentError.inferenceFailed(reason: "simulated crash")

        let status = await MultiGarmentSmokeTest.run(
            extractor: extractor,
            modelAvailable: { true }
        )

        guard case .failed(let reason) = status else {
            Issue.record("Expected .failed, got \(status)")
            return
        }
        #expect(reason.contains("Inference failed"),
                "Failed reason should carry enough detail for diagnostics")
        #expect(FeatureFlags.isMultiGarmentEnabled == false,
                "A thrown smoke test must auto-disable the feature flag so users never hit it")

        FeatureFlags.resetAll()
    }

    // MARK: - Idempotency

    @Test func smokeTestCanBeRunMultipleTimes() async {
        await MLDiagnosticsTestIsolation.shared.acquire()
        defer { Task { await MLDiagnosticsTestIsolation.shared.release() } }

        MLDiagnosticsStore.shared.resetAll()
        let extractor = MockMultiGarmentExtractor()
        extractor.detectResult = []

        _ = await MultiGarmentSmokeTest.run(
            extractor: extractor,
            modelAvailable: { true }
        )
        _ = await MultiGarmentSmokeTest.run(
            extractor: extractor,
            modelAvailable: { true }
        )

        #expect(extractor.detectCallCount == 2)
        if case .passed = MLDiagnosticsStore.shared.smokeTestStatus {
            // Good — last run's terminal status is what's recorded
        } else {
            Issue.record("Expected last-run status to be .passed")
        }
    }
}
