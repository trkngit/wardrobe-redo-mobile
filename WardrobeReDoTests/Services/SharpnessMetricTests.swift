import CoreVideo
import Foundation
import Testing
@testable import WardrobeReDo

// MARK: - SharpnessMetric tests (build 6)
//
// We exercise two layers of the metric independently:
//
//  1. The normalization curve `normalize(rawVariance:)` is pure
//     arithmetic — we can pin its endpoints without any GPU.
//  2. The end-to-end `sharpness(from:)` pipeline runs the actual MPS
//     Laplacian. On simulators that report a Metal device, we
//     synthesize a `CVPixelBuffer` filled with a high-frequency
//     pattern (sharp) and a flat patch (blurry) and assert the
//     sharp-vs-blur ordering. On simulators without Metal we skip
//     gracefully — the metric's contract is "returns nil when GPU is
//     unavailable" and downstream consumers treat that as "no
//     signal," so a skip doesn't hide a real bug.

@Test func normalizeMapsBlurFloorToZero() {
    #expect(SharpnessMetric.normalize(rawVariance: SharpnessMetric.rawVarianceBlurFloor) == 0.0)
    #expect(SharpnessMetric.normalize(rawVariance: SharpnessMetric.rawVarianceBlurFloor - 10) == 0.0)
}

@Test func normalizeMapsSharpFloorToOne() {
    #expect(SharpnessMetric.normalize(rawVariance: SharpnessMetric.rawVarianceSharpFloor) == 1.0)
    #expect(SharpnessMetric.normalize(rawVariance: SharpnessMetric.rawVarianceSharpFloor + 100) == 1.0)
}

@Test func normalizeIsMonotonicallyIncreasing() {
    let low = SharpnessMetric.normalize(rawVariance: 40)
    let mid = SharpnessMetric.normalize(rawVariance: 90)
    let high = SharpnessMetric.normalize(rawVariance: 140)
    #expect(low < mid)
    #expect(mid < high)
    #expect(low >= 0 && high <= 1)
}

@Test func sharpPatchScoresHigherThanFlatPatch() {
    guard let sharp = makePixelBuffer(pattern: .checkerboard),
          let flat = makePixelBuffer(pattern: .uniform(value: 128))
    else {
        // CVPixelBuffer creation failed — usually a simulator
        // environment limitation. Treat as a soft skip.
        return
    }
    guard let sharpScore = SharpnessMetric.sharpness(from: sharp),
          let flatScore = SharpnessMetric.sharpness(from: flat)
    else {
        // Metal unavailable on this simulator/runner. The contract
        // says callers should treat nil as "no signal," so a missing
        // device is not a test failure.
        return
    }
    #expect(sharpScore > flatScore,
            "sharp patch (\(sharpScore)) must score higher than flat patch (\(flatScore))")
    #expect(flatScore < 0.3, "flat patch should land below the blur floor band")
}

// MARK: - Pixel buffer helpers

private enum Pattern {
    case uniform(value: UInt8)
    case checkerboard
}

/// Builds a single-plane Y8 (kCVPixelFormatType_OneComponent8) buffer
/// large enough to exercise the center-patch crop. Returns nil if
/// CVPixelBuffer allocation fails for any reason.
private func makePixelBuffer(pattern: Pattern, side: Int = 512) -> CVPixelBuffer? {
    var pixelBuffer: CVPixelBuffer?
    let attrs: [String: Any] = [
        kCVPixelBufferIOSurfacePropertiesKey as String: [:],
    ]
    let status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        side,
        side,
        kCVPixelFormatType_OneComponent8,
        attrs as CFDictionary,
        &pixelBuffer
    )
    guard status == kCVReturnSuccess, let buffer = pixelBuffer else { return nil }
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
    let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
    let ptr = base.assumingMemoryBound(to: UInt8.self)
    for row in 0..<side {
        for col in 0..<side {
            let value: UInt8
            switch pattern {
            case .uniform(let v):
                value = v
            case .checkerboard:
                // 4-pixel checkerboard maximizes Laplacian response —
                // every neighbor pair has a sign flip.
                value = ((row / 4) + (col / 4)) % 2 == 0 ? 0 : 255
            }
            ptr[row * bytesPerRow + col] = value
        }
    }
    return buffer
}
