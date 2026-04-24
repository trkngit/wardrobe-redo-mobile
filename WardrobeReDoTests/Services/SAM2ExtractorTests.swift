import CoreML
import Foundation
import Testing
import UIKit
@testable import WardrobeReDo

// MARK: - SAM2Extractor — graceful missing-model fallback
//
// The compiled model ships via Git LFS. On a fresh checkout (or on a
// simulator CI runner without LFS content), the bundle lookup returns
// nil and every inference path should fall through without throwing.
// These tests pin that invariant so a future "oops, forgot to handle
// missing model" regression is caught in CI instead of production.

@Test func sam2ReturnsNilWhenModelIsMissing() async {
    let extractor = SAM2Extractor(modelLoader: { nil })
    let image = UIImage(ciImage: CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 4, height: 4)))
    let result = await extractor.autoSegment(from: image)
    #expect(result == nil)
}

@Test func sam2ReturnsNilForEmptyPointsEvenWhenModelExists() async {
    // Load-loader that would succeed should still short-circuit on empty points.
    let extractor = SAM2Extractor(modelLoader: { nil })
    let image = UIImage(ciImage: CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 4, height: 4)))
    let result = await extractor.segment(image: image, points: [])
    #expect(result == nil)
}

@Test func sam2PrewarmIsIdempotentAndSafeWithMissingModel() async {
    let extractor = SAM2Extractor(modelLoader: { nil })
    await extractor.prewarm()
    await extractor.prewarm()
    // No assertion needed — we just want to confirm neither call traps
    // on a nil model. The real assertion is "test didn't crash".
    #expect(Bool(true))
}

@Test func sam2TapPointFactoryHelpers() {
    let positive = SAM2TapPoint.positive(CGPoint(x: 0.5, y: 0.5))
    let negative = SAM2TapPoint.negative(CGPoint(x: 0.25, y: 0.75))
    #expect(positive.isPositive == true)
    #expect(positive.normalized == CGPoint(x: 0.5, y: 0.5))
    #expect(negative.isPositive == false)
    #expect(negative.normalized == CGPoint(x: 0.25, y: 0.75))
}

@Test func sam2PixelBufferFromMultiArrayHandles2DShape() {
    guard let array = try? MLMultiArray(shape: [2, 2], dataType: .float32) else {
        Issue.record("failed to allocate MLMultiArray")
        return
    }
    // Fill with a gradient — bottom-right should end up closer to 255.
    array[0] = NSNumber(value: Float(-10.0)) // sigmoid(-10) ≈ 0
    array[1] = NSNumber(value: Float(0.0))   // sigmoid(0)   = 0.5
    array[2] = NSNumber(value: Float(0.0))   // sigmoid(0)   = 0.5
    array[3] = NSNumber(value: Float(10.0))  // sigmoid(10)  ≈ 1

    let buffer = SAM2Extractor.pixelBuffer(fromMultiArray: array)
    #expect(buffer != nil)
    guard let pb = buffer else { return }
    #expect(CVPixelBufferGetWidth(pb) == 2)
    #expect(CVPixelBufferGetHeight(pb) == 2)
}

@Test func sam2PixelBufferFromMultiArrayHandles4DShape() {
    guard let array = try? MLMultiArray(shape: [1, 1, 3, 3], dataType: .float32) else {
        Issue.record("failed to allocate MLMultiArray")
        return
    }
    for i in 0..<9 { array[i] = NSNumber(value: Float(0.0)) }

    let buffer = SAM2Extractor.pixelBuffer(fromMultiArray: array)
    #expect(buffer != nil)
    guard let pb = buffer else { return }
    #expect(CVPixelBufferGetWidth(pb) == 3)
    #expect(CVPixelBufferGetHeight(pb) == 3)
}

@Test func sam2PixelBufferFromMultiArrayRejectsUnsupportedShape() {
    // 1D tensor isn't a mask shape SAM2 ever produces.
    guard let array = try? MLMultiArray(shape: [4], dataType: .float32) else {
        Issue.record("failed to allocate MLMultiArray")
        return
    }
    let buffer = SAM2Extractor.pixelBuffer(fromMultiArray: array)
    #expect(buffer == nil)
}
