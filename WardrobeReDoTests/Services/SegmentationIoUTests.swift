import CoreVideo
import Foundation
import Testing
import UIKit
@testable import WardrobeReDo

// MARK: - Segmentation IoU rig
//
// Runs `ClothingExtractionService` against each fixture declared in
// `Fixtures/Extraction/manifest.json` and asserts the returned mask IoUs
// against the hand-traced ground truth by at least `expected_iou_min`.
// Thresholds are tuned per fixture (see `capture-brief.md`).
//
// The rig is **device-only**: `VNGenerateForegroundInstanceMaskRequest`
// requires a Neural Engine and the SAM2 path needs real bundle resources
// to be present. On the simulator we short-circuit every `@Test` with
// `Issue.record(...)`-free skips so CI runs stay green. When the manifest
// is empty (fresh checkout, no traces yet) the rig also skips with a
// clear message instead of failing.

@Test func manifestLoadsAndIsValid() {
    #if targetEnvironment(simulator)
    // Manifest parsing works on simulator — only actual extraction is gated.
    guard let manifest = FixtureLoader.loadManifest() else {
        return  // no manifest in bundle yet; deliberately silent
    }
    #expect(manifest.version >= 1)
    for fixture in manifest.fixtures {
        #expect(!fixture.image.isEmpty)
        #expect(!fixture.mask.isEmpty)
        #expect(fixture.expectedIoUMin > 0)
        #expect(fixture.expectedIoUMin <= 1)
        #expect(!fixture.scenario.isEmpty)
    }
    #else
    // On device, same invariants but we also verify each referenced file
    // actually loads so a typo in the manifest shows up as a clear test
    // failure instead of a silent zero-IoU.
    guard let manifest = FixtureLoader.loadManifest() else {
        Issue.record("manifest.json missing from test bundle — see Fixtures/Extraction/capture-brief.md")
        return
    }
    for fixture in manifest.fixtures {
        #expect(FixtureLoader.loadImage(named: fixture.image) != nil, "missing fixture image: \(fixture.image)")
        #expect(FixtureLoader.loadMask(at: fixture.mask) != nil, "missing ground-truth mask: \(fixture.mask)")
    }
    #endif
}

@Test func extractionMeetsPerFixtureIoUFloor() async {
    #if targetEnvironment(simulator)
    // Silent skip — see header comment. Device runs do the real work.
    return
    #else
    guard let manifest = FixtureLoader.loadManifest(), !manifest.fixtures.isEmpty else {
        // Nothing to measure yet. The capture-brief explains how to drop
        // photos + masks in. We don't fail; we report so it's visible.
        Issue.record("No fixtures in manifest — add traces per Fixtures/Extraction/capture-brief.md")
        return
    }

    let service = ClothingExtractionService()
    for fixture in manifest.fixtures {
        guard let image = FixtureLoader.loadImage(named: fixture.image),
              let gtMask = FixtureLoader.loadMask(at: fixture.mask) else {
            Issue.record("fixture resources missing: \(fixture.image) / \(fixture.mask)")
            continue
        }

        let result = await service.extract(image)
        guard let predicted = result.mask else {
            Issue.record("\(fixture.image): extractor returned no mask (method=\(result.method.rawValue))")
            continue
        }

        let score = MaskIoU.score(prediction: predicted, groundTruth: gtMask)
        #expect(
            score >= fixture.expectedIoUMin,
            "\(fixture.image) [\(fixture.scenario)]: IoU \(String(format: "%.3f", score)) < floor \(fixture.expectedIoUMin) (method=\(result.method.rawValue), conf=\(result.confidence.rawValue))"
        )
    }
    #endif
}

// MARK: - Rig smoke tests (cross-platform)
//
// These exercise the IoU math + fixture loader without touching Vision or
// SAM2, so they run everywhere and catch rig regressions early.

@Test func iouOfIdenticalMasksIsOne() {
    let mask = makeSyntheticMask(filledRect: CGRect(x: 2, y: 2, width: 4, height: 4), size: 8)
    #expect(MaskIoU.score(prediction: mask, groundTruth: mask) == 1.0)
}

@Test func iouOfDisjointMasksIsZero() {
    let a = makeSyntheticMask(filledRect: CGRect(x: 0, y: 0, width: 4, height: 4), size: 8)
    let b = makeSyntheticMask(filledRect: CGRect(x: 4, y: 4, width: 4, height: 4), size: 8)
    #expect(MaskIoU.score(prediction: a, groundTruth: b) == 0.0)
}

@Test func iouOfHalfOverlapMasksIsOneThird() {
    // Two 4×4 rectangles overlapping on a 2×4 strip.
    //   A: columns 0..<4, rows 0..<4  → 16 pixels
    //   B: columns 2..<6, rows 0..<4  → 16 pixels
    // Intersection = 2×4 = 8. Union = 16 + 16 - 8 = 24. IoU = 8/24 = 0.333…
    let a = makeSyntheticMask(filledRect: CGRect(x: 0, y: 0, width: 4, height: 4), size: 8)
    let b = makeSyntheticMask(filledRect: CGRect(x: 2, y: 0, width: 4, height: 4), size: 8)
    let score = MaskIoU.score(prediction: a, groundTruth: b)
    #expect(abs(score - (1.0 / 3.0)) < 0.01)
}

@Test func iouResizesGroundTruthToMatchPrediction() {
    // Fully-white 8×8 prediction, fully-white 4×4 ground truth.
    // After nearest-neighbour upscale they cover the same area → IoU 1.
    let prediction = makeSyntheticMask(filledRect: CGRect(x: 0, y: 0, width: 8, height: 8), size: 8)
    let gt = makeSyntheticMask(filledRect: CGRect(x: 0, y: 0, width: 4, height: 4), size: 4)
    let score = MaskIoU.score(prediction: prediction, groundTruth: gt)
    #expect(score == 1.0)
}

// MARK: - Test helpers

private func makeSyntheticMask(filledRect rect: CGRect, size: Int) -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        size,
        size,
        kCVPixelFormatType_OneComponent8,
        nil,
        &buffer
    )
    precondition(status == kCVReturnSuccess)
    let pb = buffer!
    CVPixelBufferLockBaseAddress(pb, [])
    defer { CVPixelBufferUnlockBaseAddress(pb, []) }
    let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
    let bytesPerRow = CVPixelBufferGetBytesPerRow(pb)
    memset(base, 0, bytesPerRow * size)
    for y in Int(rect.minY)..<Int(rect.maxY) {
        for x in Int(rect.minX)..<Int(rect.maxX) {
            guard y >= 0, y < size, x >= 0, x < size else { continue }
            base[y * bytesPerRow + x] = 255
        }
    }
    return pb
}
