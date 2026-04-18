import Foundation
import Testing
import UIKit
@testable import WardrobeReDo

/// Tests that ImageService's `processImage` correctly wires up the
/// multi-garment extractor behind the `FeatureFlags.isMultiGarmentEnabled`
/// gate.
///
/// These tests use a mock `MultiGarmentExtracting` — we don't need the
/// real RFDETR model to be bundled. The contract we're enforcing is
/// entirely about the integration glue, not inference quality.
///
/// `.serialized` is required because `FeatureFlags` is
/// `UserDefaults.standard`-backed global mutable state. Swift Testing
/// runs tests in parallel by default; without serialization, one test's
/// `FeatureFlags.isMultiGarmentEnabled = true` races with another's
/// `FeatureFlags.resetAll()` and the "flag off" assertions flake.
@MainActor
@Suite(.serialized)
struct ImageServiceProposalsTests {

    // MARK: - Feature flag gating

    @Test func processImageSkipsMultiGarmentWhenFlagOff() async {
        await FeatureFlagTestIsolation.shared.acquire()
        defer { Task { await FeatureFlagTestIsolation.shared.release() } }
        FeatureFlags.resetAll()
        #expect(FeatureFlags.isMultiGarmentEnabled == false)

        let multi = MockMultiGarmentExtractor()
        multi.detectResult = [
            MaskProposalFixture.make(predictedCategory: .top),
            MaskProposalFixture.make(predictedCategory: .bottom),
        ]

        let service = ImageService(
            clothingExtractor: passThroughExtractor(),
            multiGarmentExtractor: multi
        )

        let image = makeTestImage()
        _ = await service.processImage(image)

        #expect(multi.detectCallCount == 0, "multi-garment should not fire when flag is off")
    }

    @Test func processImageInvokesMultiGarmentWhenFlagOn() async {
        await FeatureFlagTestIsolation.shared.acquire()
        defer { Task { await FeatureFlagTestIsolation.shared.release() } }
        FeatureFlags.resetAll()
        FeatureFlags.isMultiGarmentEnabled = true
        defer { FeatureFlags.resetAll() }

        let multi = MockMultiGarmentExtractor()
        multi.detectResult = [
            MaskProposalFixture.make(predictedCategory: .top),
            MaskProposalFixture.make(predictedCategory: .outerwear),
            MaskProposalFixture.make(predictedCategory: .bottom),
        ]

        let service = ImageService(
            clothingExtractor: passThroughExtractor(),
            multiGarmentExtractor: multi
        )

        let processed = await service.processImage(makeTestImage())

        #expect(multi.detectCallCount == 1)
        #expect(processed?.proposals?.count == 3)
    }

    // MARK: - Single-proposal fall-through

    @Test func processImageReturnsNilProposalsWhenOnlyOneDetected() async {
        await FeatureFlagTestIsolation.shared.acquire()
        defer { Task { await FeatureFlagTestIsolation.shared.release() } }
        FeatureFlags.resetAll()
        FeatureFlags.isMultiGarmentEnabled = true
        defer { FeatureFlags.resetAll() }

        let multi = MockMultiGarmentExtractor()
        multi.detectResult = [MaskProposalFixture.make()]

        let service = ImageService(
            clothingExtractor: passThroughExtractor(),
            multiGarmentExtractor: multi
        )

        let processed = await service.processImage(makeTestImage())
        #expect(processed?.proposals == nil,
               "Single proposal should route to single-item flow (proposals=nil)")
    }

    @Test func processImageReturnsNilProposalsWhenNoneDetected() async {
        await FeatureFlagTestIsolation.shared.acquire()
        defer { Task { await FeatureFlagTestIsolation.shared.release() } }
        FeatureFlags.resetAll()
        FeatureFlags.isMultiGarmentEnabled = true
        defer { FeatureFlags.resetAll() }

        let multi = MockMultiGarmentExtractor()
        multi.detectResult = []

        let service = ImageService(
            clothingExtractor: passThroughExtractor(),
            multiGarmentExtractor: multi
        )

        let processed = await service.processImage(makeTestImage())
        #expect(processed?.proposals == nil)
    }

    // MARK: - Error resilience

    @Test func processImageSwallowsMultiGarmentErrors() async {
        await FeatureFlagTestIsolation.shared.acquire()
        defer { Task { await FeatureFlagTestIsolation.shared.release() } }
        FeatureFlags.resetAll()
        FeatureFlags.isMultiGarmentEnabled = true
        defer { FeatureFlags.resetAll() }

        let multi = MockMultiGarmentExtractor()
        multi.detectError = MultiGarmentError.modelLoadFailed(
            reason: "missing from bundle", modelPath: nil
        )

        let service = ImageService(
            clothingExtractor: passThroughExtractor(),
            multiGarmentExtractor: multi
        )

        let processed = await service.processImage(makeTestImage())
        // Single-item flow still produced a valid ProcessedImage
        // (original + thumbnail + colors); proposals is nil because the
        // model failed to load. User never sees a broken state.
        #expect(processed != nil)
        #expect(processed?.proposals == nil)
    }

    // MARK: - Helpers

    private func passThroughExtractor() -> MockClothingExtractionService {
        let mock = MockClothingExtractionService()
        // Leave extractResult nil → passthrough returns input image.
        return mock
    }

    private func makeTestImage() -> UIImage {
        UIGraphicsBeginImageContext(CGSize(width: 4, height: 4))
        let ctx = UIGraphicsGetCurrentContext()
        ctx?.setFillColor(UIColor.red.cgColor)
        ctx?.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        let img = UIGraphicsGetImageFromCurrentImageContext() ?? UIImage()
        UIGraphicsEndImageContext()
        return img
    }
}
