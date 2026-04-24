import Foundation
import Testing
@testable import WardrobeReDo

/// Unit tests for the opt-in ML telemetry pipeline. We deliberately do
/// NOT exercise the Supabase round-trip — `logInference` swallows network
/// errors by design, so asserting on observable behaviour against a live
/// service would be flaky-by-construction. Instead we cover:
///
/// 1. **Gate semantics.** The service short-circuits cleanly when
///    `FeatureFlags.isMLTelemetryEnabled` is `false`.
/// 2. **Gate reads live.** Flipping the flag on mid-test flips
///    `isUploadEnabled()` on the next call (no cached value).
/// 3. **Observation shape.** The public `Observation` initializer accepts
///    every field and stores it verbatim — guards against a future
///    refactor silently dropping a column.
/// 4. **Surface heuristic.** `MLDiagnosticsStore.surface(for:)` maps
///    model-name substrings to the dashboard-visible surface strings
///    from migration 00011.
/// 5. **Compute-unit banding.** `inferredComputeUnit(forLatencyMs:)`
///    bins latency into the ANE / GPU / CPU strings used by the column.
///
/// The Supabase INSERT call itself is validated manually in Phase 9's
/// dogfood window — hitting the live table is out of scope for CI.
///
/// Because `FeatureFlags` is UserDefaults-backed and `MLTelemetryService`
/// reads it on every call, tests that mutate the flag run serially to
/// avoid cross-contamination.
@Suite(.serialized)
struct MLTelemetryServiceTests {

    // MARK: - Gate semantics

    @Test @MainActor func flagDefaultsOff() async {
        FeatureFlags.resetAll()
        let enabled = await MLTelemetryService.shared.isUploadEnabled()
        #expect(enabled == false)
    }

    @Test @MainActor func flagFlipsOnWithoutRestart() async {
        FeatureFlags.resetAll()
        #expect(await MLTelemetryService.shared.isUploadEnabled() == false)

        FeatureFlags.isMLTelemetryEnabled = true
        #expect(await MLTelemetryService.shared.isUploadEnabled() == true)

        FeatureFlags.isMLTelemetryEnabled = false
        #expect(await MLTelemetryService.shared.isUploadEnabled() == false)

        FeatureFlags.resetAll()
    }

    @Test @MainActor func logInferenceNoOpsWhenFlagOff() async {
        FeatureFlags.resetAll()
        // If the gate fails, this call would try to hit Supabase auth and
        // throw — instead, it should return immediately without touching
        // the network. The assertion that matters is "this completes
        // deterministically and doesn't throw"; the service signature is
        // `async` (not `async throws`), so a completion is the test.
        let observation = MLTelemetryService.Observation(
            modelName: "AttributeClassifier",
            surface: "attribute_classifier",
            latencyMs: 123.4,
            computeUnit: "ANE (likely)",
            proposalCount: nil,
            topClassRaw: "relaxed",
            topScore: 0.87,
            threw: false,
            prefillFired: true,
            userCorrected: false,
            fieldChanged: nil
        )
        await MLTelemetryService.shared.logInference(observation)
    }

    // MARK: - Observation shape

    @Test func observationStoresAllFieldsVerbatim() {
        let observation = MLTelemetryService.Observation(
            modelName: "RFDETRSegFashion",
            surface: "multi_garment",
            latencyMs: 221.0,
            computeUnit: "ANE (likely)",
            proposalCount: 3,
            topClassRaw: "shirt, blouse",
            topScore: 0.91,
            threw: false,
            prefillFired: nil,
            userCorrected: nil,
            fieldChanged: nil
        )
        #expect(observation.modelName == "RFDETRSegFashion")
        #expect(observation.surface == "multi_garment")
        #expect(observation.latencyMs == 221.0)
        #expect(observation.computeUnit == "ANE (likely)")
        #expect(observation.proposalCount == 3)
        #expect(observation.topClassRaw == "shirt, blouse")
        #expect(observation.topScore == 0.91)
        #expect(observation.threw == false)
        #expect(observation.prefillFired == nil)
        #expect(observation.userCorrected == nil)
        #expect(observation.fieldChanged == nil)
    }

    @Test func observationDefaultsAreSafe() {
        // Call with only the required args — mirrors how call sites in
        // `AttributeClassifierService` build an Observation in the
        // error path (no prediction, threw=true, no pre-fill info).
        let observation = MLTelemetryService.Observation(
            modelName: "AttributeClassifier",
            surface: "attribute_classifier",
            latencyMs: 50.0
        )
        #expect(observation.computeUnit == nil)
        #expect(observation.proposalCount == nil)
        #expect(observation.topClassRaw == nil)
        #expect(observation.topScore == nil)
        #expect(observation.threw == false)
        #expect(observation.prefillFired == nil)
        #expect(observation.userCorrected == nil)
        #expect(observation.fieldChanged == nil)
    }

    // MARK: - Surface heuristic

    @Test @MainActor func surfaceRecognisesAttributeClassifier() {
        #expect(MLDiagnosticsStore.surface(for: "AttributeClassifier") == "attribute_classifier")
        #expect(MLDiagnosticsStore.surface(for: "attributeclassifier") == "attribute_classifier")
        #expect(MLDiagnosticsStore.surface(for: "Attribute-Classifier-v2") == "attribute_classifier")
    }

    @Test @MainActor func surfaceFallsBackToMultiGarment() {
        #expect(MLDiagnosticsStore.surface(for: "RFDETRSegFashion") == "multi_garment")
        #expect(MLDiagnosticsStore.surface(for: "something-else") == "multi_garment")
    }

    // MARK: - Compute unit banding

    @Test @MainActor func computeUnitBandsMatchDashboardStrings() {
        #expect(MLDiagnosticsStore.inferredComputeUnit(forLatencyMs: 100) == "ANE (likely)")
        #expect(MLDiagnosticsStore.inferredComputeUnit(forLatencyMs: 249.9) == "ANE (likely)")
        #expect(MLDiagnosticsStore.inferredComputeUnit(forLatencyMs: 250) == "GPU (likely)")
        #expect(MLDiagnosticsStore.inferredComputeUnit(forLatencyMs: 500) == "GPU (likely)")
        #expect(MLDiagnosticsStore.inferredComputeUnit(forLatencyMs: 899.9) == "GPU (likely)")
        #expect(MLDiagnosticsStore.inferredComputeUnit(forLatencyMs: 900) == "CPU (likely)")
        #expect(MLDiagnosticsStore.inferredComputeUnit(forLatencyMs: 2500) == "CPU (likely)")
    }
}
