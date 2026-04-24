import Foundation
import UIKit
import os.log

/// App-launch smoke test for the multi-garment pipeline. Runs in DEBUG
/// builds only, off the main actor, and writes its result into
/// `MLDiagnosticsStore` so the Developer menu can show the state.
///
/// **Purpose.** Catches "Background Assets delivered a corrupt model" /
/// "Core ML compile is broken on this OS version" / "the Fashionpedia
/// class mapping regressed" BEFORE a user taps the shutter. If inference
/// throws, we flip `FeatureFlags.isMultiGarmentEnabled` off so the next
/// capture silently runs the single-item flow instead of a broken multi-
/// pick cover.
///
/// **Skips when the model isn't bundled.** Local dev builds don't carry
/// the trained model until Commit 2 ships; a "missing model" isn't a
/// regression, it's the expected state. The smoke test records
/// `.skipped` in that case and doesn't touch the feature flag.
///
/// **DEBUG-only entry point.** Production users never pay the smoke-test
/// latency and never see the diagnostics surface. The test is dispatched
/// from `WardrobeReDoApp.init` inside a `#if DEBUG` gate.
enum MultiGarmentSmokeTest {

    private static let logger = Logger(subsystem: "com.wardroberedo", category: "MultiGarmentSmokeTest")

    /// Run the smoke test once. Safe to call repeatedly; duplicate runs
    /// overwrite the previous status rather than queueing. Returns the
    /// terminal status so tests can inspect it synchronously.
    @discardableResult
    static func run(
        extractor: MultiGarmentExtracting = MultiGarmentProposalService(),
        modelAvailable: @Sendable () -> Bool = defaultModelAvailabilityCheck
    ) async -> MLDiagnosticsStore.SmokeTestStatus {
        await MLDiagnosticsStore.shared.setSmokeTestStatus(.running)
        logger.info("smokeTest.start")

        guard modelAvailable() else {
            let status = MLDiagnosticsStore.SmokeTestStatus.skipped(
                reason: "RFDETRSegFashion.mlmodelc not in bundle"
            )
            await MLDiagnosticsStore.shared.setSmokeTestStatus(status)
            logger.notice("smokeTest.skipped model-missing")
            return status
        }

        let probe = makeProbeImage()
        let start = Date()
        do {
            _ = try await extractor.detectProposals(in: probe)
            let latencyMs = Date().timeIntervalSince(start) * 1000
            let status = MLDiagnosticsStore.SmokeTestStatus.passed(latencyMs: latencyMs)
            await MLDiagnosticsStore.shared.setSmokeTestStatus(status)
            logger.info("smokeTest.passed latencyMs=\(latencyMs, privacy: .public)")
            return status
        } catch {
            let status = MLDiagnosticsStore.SmokeTestStatus.failed(
                reason: error.localizedDescription
            )
            await MLDiagnosticsStore.shared.setSmokeTestStatus(status)
            // Auto-disable the flag so the broken model can't reach a user.
            // The Developer menu toggle still allows manual re-enable for
            // investigation. Hop to MainActor because FeatureFlags is
            // MainActor-isolated and `run(...)` is callable from any
            // actor context.
            await MainActor.run {
                FeatureFlags.isMultiGarmentEnabled = false
            }
            logger.error("smokeTest.failed \(error.localizedDescription, privacy: .public) — flag auto-disabled")
            return status
        }
    }

    /// Bundle-lookup predicate used in production. Factored out so tests
    /// can inject a stub that returns `true` without shipping a real
    /// model file.
    static let defaultModelAvailabilityCheck: @Sendable () -> Bool = {
        Bundle.main.url(
            forResource: MultiGarmentProposalService.bundledModelName,
            withExtension: "mlmodelc"
        ) != nil
    }

    /// 32×32 solid-color probe. Small enough that inference is cheap even
    /// on CPU fallback; not a real garment so the model will almost
    /// certainly return zero proposals — which is fine, the smoke test
    /// cares about "does inference complete without throwing", not about
    /// output quality.
    static func makeProbeImage() -> UIImage {
        let size = CGSize(width: 32, height: 32)
        UIGraphicsBeginImageContext(size)
        let ctx = UIGraphicsGetCurrentContext()
        ctx?.setFillColor(UIColor.systemGray.cgColor)
        ctx?.fill(CGRect(origin: .zero, size: size))
        let image = UIGraphicsGetImageFromCurrentImageContext() ?? UIImage()
        UIGraphicsEndImageContext()
        return image
    }
}
