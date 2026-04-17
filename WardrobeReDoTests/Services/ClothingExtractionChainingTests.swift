import CoreVideo
import Foundation
import Testing
import UIKit
@testable import WardrobeReDo

// MARK: - Vision → SAM2 fallback chaining
//
// Phase 3 wires `ClothingExtractionService` to run Vision first, then
// automatically run SAM2-tiny when Vision confidence is `.low` or
// `.failed`. These tests substitute both services with in-process mocks
// so the chaining logic is exercised without a real Neural Engine or
// Core ML model. Device-only IoU tests (Phase 4) will validate the
// actual segmentation quality.

/// Minimal 1×1 placeholder pixel buffer shared across tests so the
/// `ExtractionResult` holds a real CVPixelBuffer when a mock extractor
/// produced one.
private func makeTestPixelBuffer() -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        1,
        1,
        kCVPixelFormatType_OneComponent8,
        nil,
        &buffer
    )
    precondition(status == kCVReturnSuccess)
    return buffer!
}

private func makePixelUIImage(color: UIColor = .systemBlue) -> UIImage {
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2))
    return renderer.image { ctx in
        color.setFill()
        ctx.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
    }
}

// MARK: - Mocks

final class MockVisionForegroundExtractor: VisionForegroundExtracting, @unchecked Sendable {
    var result: ForegroundMaskResult?
    var callCount = 0

    init(result: ForegroundMaskResult?) {
        self.result = result
    }

    func extractForeground(from image: UIImage) async -> ForegroundMaskResult? {
        callCount += 1
        return result
    }
}

final class MockSAM2Extractor: SAM2Extracting, @unchecked Sendable {
    var autoResult: SAM2Result?
    var manualResult: SAM2Result?
    var autoCallCount = 0
    var manualCallCount = 0
    var lastPoints: [SAM2TapPoint] = []
    var prewarmCallCount = 0

    func autoSegment(from image: UIImage) async -> SAM2Result? {
        autoCallCount += 1
        return autoResult
    }

    func segment(image: UIImage, points: [SAM2TapPoint]) async -> SAM2Result? {
        manualCallCount += 1
        lastPoints = points
        return manualResult
    }

    func prewarm() async {
        prewarmCallCount += 1
    }
}

// MARK: - Tests

@Test func chainingSkipsSAM2WhenVisionIsHighConfidence() async {
    // Single instance with 50% coverage → synthesized `.high`.
    let vision = MockVisionForegroundExtractor(result: ForegroundMaskResult(
        mask: makeTestPixelBuffer(),
        maskedImage: makePixelUIImage(color: .systemRed),
        instanceCount: 1,
        coverageRatio: 0.50
    ))
    let sam2 = MockSAM2Extractor()

    let service = ClothingExtractionService(visionExtractor: vision, sam2Extractor: sam2)
    let result = await service.extract(makePixelUIImage())

    #expect(result.method == .vision)
    #expect(result.confidence == .high)
    #expect(sam2.autoCallCount == 0)
}

@Test func chainingSkipsSAM2WhenVisionIsMediumConfidence() async {
    // Single instance at 8% coverage → `.medium`, still high-trust.
    let vision = MockVisionForegroundExtractor(result: ForegroundMaskResult(
        mask: makeTestPixelBuffer(),
        maskedImage: makePixelUIImage(),
        instanceCount: 1,
        coverageRatio: 0.08
    ))
    let sam2 = MockSAM2Extractor()

    let service = ClothingExtractionService(visionExtractor: vision, sam2Extractor: sam2)
    let result = await service.extract(makePixelUIImage())

    #expect(result.method == .vision)
    #expect(result.confidence == .medium)
    #expect(sam2.autoCallCount == 0)
}

@Test func chainingRunsSAM2WhenVisionIsLowConfidence() async {
    // Multiple instances → `.low`; SAM2 returns a replacement mask.
    let vision = MockVisionForegroundExtractor(result: ForegroundMaskResult(
        mask: makeTestPixelBuffer(),
        maskedImage: makePixelUIImage(color: .systemYellow),
        instanceCount: 3,
        coverageRatio: 0.40
    ))
    let sam2 = MockSAM2Extractor()
    sam2.autoResult = SAM2Result(
        maskedImage: makePixelUIImage(color: .systemGreen),
        mask: makeTestPixelBuffer(),
        coverageRatio: 0.35
    )

    let service = ClothingExtractionService(visionExtractor: vision, sam2Extractor: sam2)
    let result = await service.extract(makePixelUIImage())

    #expect(result.method == .sam2Auto)
    #expect(sam2.autoCallCount == 1)
}

@Test func chainingFallsBackToVisionWhenSAM2UnavailableAtLowConfidence() async {
    // Vision is `.low` but SAM2 returns nil (model missing, inference
    // fails, etc.). Keep Vision's mask rather than collapsing to unmasked.
    let vision = MockVisionForegroundExtractor(result: ForegroundMaskResult(
        mask: makeTestPixelBuffer(),
        maskedImage: makePixelUIImage(color: .systemPink),
        instanceCount: 3,
        coverageRatio: 0.40
    ))
    let sam2 = MockSAM2Extractor() // autoResult is nil by default

    let service = ClothingExtractionService(visionExtractor: vision, sam2Extractor: sam2)
    let result = await service.extract(makePixelUIImage())

    #expect(result.method == .vision)
    #expect(result.confidence == .low)
    #expect(sam2.autoCallCount == 1)
}

@Test func chainingRunsSAM2WhenVisionFailsEntirely() async {
    // Vision returns nil (simulator, no foreground detected). SAM2 rescues.
    let vision = MockVisionForegroundExtractor(result: nil)
    let sam2 = MockSAM2Extractor()
    sam2.autoResult = SAM2Result(
        maskedImage: makePixelUIImage(color: .systemIndigo),
        mask: makeTestPixelBuffer(),
        coverageRatio: 0.20
    )

    let service = ClothingExtractionService(visionExtractor: vision, sam2Extractor: sam2)
    let result = await service.extract(makePixelUIImage())

    #expect(result.method == .sam2Auto)
    #expect(sam2.autoCallCount == 1)
}

@Test func chainingFallsThroughToUnmaskedWhenBothFail() async {
    let vision = MockVisionForegroundExtractor(result: nil)
    let sam2 = MockSAM2Extractor() // autoResult is nil

    let service = ClothingExtractionService(visionExtractor: vision, sam2Extractor: sam2)
    let result = await service.extract(makePixelUIImage())

    #expect(result.method == .none)
    #expect(result.confidence == .failed)
    #expect(result.mask == nil)
}

// MARK: - Manual tap-points path

@Test func manualTapPointsUseSAM2AndReportSam2Manual() async {
    let vision = MockVisionForegroundExtractor(result: nil)
    let sam2 = MockSAM2Extractor()
    sam2.manualResult = SAM2Result(
        maskedImage: makePixelUIImage(color: .systemTeal),
        mask: makeTestPixelBuffer(),
        coverageRatio: 0.25
    )

    let service = ClothingExtractionService(visionExtractor: vision, sam2Extractor: sam2)
    let points = [
        SAM2TapPoint.positive(CGPoint(x: 0.5, y: 0.5)),
        SAM2TapPoint.negative(CGPoint(x: 0.1, y: 0.1))
    ]
    let result = await service.extract(makePixelUIImage(), tapPoints: points)

    #expect(result.method == .sam2Manual)
    #expect(sam2.manualCallCount == 1)
    #expect(sam2.lastPoints.count == 2)
    #expect(sam2.lastPoints.first?.isPositive == true)
}

@Test func manualTapPointsFallBackToAutomaticWhenSAM2Unavailable() async {
    // SAM2 unavailable → the manual path should still return *something*
    // (by delegating to the normal automatic pipeline) rather than
    // leaving the UI stuck on a broken mask.
    let vision = MockVisionForegroundExtractor(result: ForegroundMaskResult(
        mask: makeTestPixelBuffer(),
        maskedImage: makePixelUIImage(color: .systemGray),
        instanceCount: 1,
        coverageRatio: 0.40
    ))
    let sam2 = MockSAM2Extractor() // manualResult is nil

    let service = ClothingExtractionService(visionExtractor: vision, sam2Extractor: sam2)
    let points = [SAM2TapPoint.positive(CGPoint(x: 0.5, y: 0.5))]
    let result = await service.extract(makePixelUIImage(), tapPoints: points)

    // Fell back to automatic extraction — Vision-high-confidence path.
    #expect(result.method == .vision)
    #expect(sam2.manualCallCount == 1)
}

@Test func manualTapPointsWithEmptyArrayFallsBackToAutomatic() async {
    let vision = MockVisionForegroundExtractor(result: nil)
    let sam2 = MockSAM2Extractor()

    let service = ClothingExtractionService(visionExtractor: vision, sam2Extractor: sam2)
    let result = await service.extract(makePixelUIImage(), tapPoints: [])

    // Empty points → fall back to automatic path, not a SAM2 manual call.
    #expect(sam2.manualCallCount == 0)
    #expect(result.method == .none || result.method == .sam2Auto || result.method == .vision)
}

// MARK: - Prewarm

@Test func prewarmDelegatesToSAM2() async {
    let vision = MockVisionForegroundExtractor(result: nil)
    let sam2 = MockSAM2Extractor()
    let service = ClothingExtractionService(visionExtractor: vision, sam2Extractor: sam2)

    await service.prewarm()

    #expect(sam2.prewarmCallCount == 1)
}

// MARK: - ExtractionMethod raw values (schema contract for the DB column)

@Test func extractionMethodRawValuesAreStable() {
    // `wardrobe_items.extraction_method` persists these strings. Changing
    // a case name is a DB migration, not a silent refactor.
    #expect(ExtractionMethod.vision.rawValue == "vision")
    #expect(ExtractionMethod.sam2Auto.rawValue == "sam2Auto")
    #expect(ExtractionMethod.sam2Manual.rawValue == "sam2Manual")
    #expect(ExtractionMethod.none.rawValue == "none")
}

@Test func isHighTrustMatchesSpec() {
    #expect(ClothingExtractionService.isHighTrust(.high) == true)
    #expect(ClothingExtractionService.isHighTrust(.medium) == true)
    #expect(ClothingExtractionService.isHighTrust(.low) == false)
    #expect(ClothingExtractionService.isHighTrust(.failed) == false)
}
