import CoreML
import CoreVideo
import Foundation
import Testing
@testable import WardrobeReDo

/// Unit tests for `MultiGarmentProposalService.MaskTensorContext` +
/// `decodeMask(from:queryIndex:)`.
///
/// The decode path takes the segmentation head's `pred_masks` tensor
/// (`[1, Q, H, W]` Float32 logits) and produces a binary `CVPixelBuffer`
/// per query. Tests build the tensor in Swift — no model file needed —
/// and assert:
///   * Per-query foreground lands in the correct quadrant
///   * Out-of-range query indices return nil (graceful degradation)
///   * Wrong-shape tensors return nil so the caller falls through to
///     the rect-crop fallback in `compositeMaskedItem`
///
/// Build-5 was missing this decode entirely (`mask: nil` hardcoded), so
/// the rect-crop fallback ran every time and wardrobe / match / outfit
/// cards displayed source-photo backdrops. PR #32 wires the decode and
/// these tests pin the contract.
@Suite("MultiGarmentProposalService.maskDecode") struct MultiGarmentProposalServiceMaskDecodeTests {

    // MARK: - Happy-path decode

    @Test func decodeMaskQuery0HasForegroundInTopLeft() throws {
        // 4×4 mask tensor, two queries.
        // Query 0: top-left 2×2 quadrant is foreground (logit = +5,
        // sigmoid(+5) ≈ 0.993, > 0.5 → 255).
        // Query 1: bottom-right 2×2 quadrant is foreground.
        // All other pixels: logit = -5 (sigmoid ≈ 0.007 → 0).
        let masks = try #require(makeSyntheticMaskTensor())

        let ctx = try #require(MultiGarmentProposalService.MaskTensorContext(masks: masks))
        let buffer = try #require(MultiGarmentProposalService.decodeMask(from: ctx, queryIndex: 0))

        let pixels = readPixels(buffer)
        // Top-left 2×2 — all 255.
        #expect(pixels[0] == 255, "(0,0) expected 255, got \(pixels[0])")
        #expect(pixels[1] == 255, "(1,0) expected 255, got \(pixels[1])")
        #expect(pixels[4] == 255, "(0,1) expected 255, got \(pixels[4])")
        #expect(pixels[5] == 255, "(1,1) expected 255, got \(pixels[5])")
        // Top-right and bottom-left and bottom-right — all 0.
        #expect(pixels[2] == 0, "(2,0) expected 0, got \(pixels[2])")
        #expect(pixels[15] == 0, "(3,3) expected 0, got \(pixels[15])")
    }

    @Test func decodeMaskQuery1HasForegroundInBottomRight() throws {
        let masks = try #require(makeSyntheticMaskTensor())

        let ctx = try #require(MultiGarmentProposalService.MaskTensorContext(masks: masks))
        let buffer = try #require(MultiGarmentProposalService.decodeMask(from: ctx, queryIndex: 1))

        let pixels = readPixels(buffer)
        // Bottom-right 2×2 — all 255.
        #expect(pixels[10] == 255, "(2,2) expected 255, got \(pixels[10])")
        #expect(pixels[11] == 255, "(3,2) expected 255, got \(pixels[11])")
        #expect(pixels[14] == 255, "(2,3) expected 255, got \(pixels[14])")
        #expect(pixels[15] == 255, "(3,3) expected 255, got \(pixels[15])")
        // Top-left — all 0.
        #expect(pixels[0] == 0, "(0,0) expected 0, got \(pixels[0])")
        #expect(pixels[5] == 0, "(1,1) expected 0, got \(pixels[5])")
    }

    @Test func decodeMaskBufferDimensionsMatchSourceShape() throws {
        let masks = try #require(makeSyntheticMaskTensor())
        let ctx = try #require(MultiGarmentProposalService.MaskTensorContext(masks: masks))
        let buffer = try #require(MultiGarmentProposalService.decodeMask(from: ctx, queryIndex: 0))

        // Native mask resolution preserved — `compositeMaskedItem`
        // upscales via `CGAffineTransform`, so we don't pre-scale here.
        #expect(CVPixelBufferGetWidth(buffer) == 4)
        #expect(CVPixelBufferGetHeight(buffer) == 4)
        #expect(CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_OneComponent8)
    }

    // MARK: - Graceful-degradation paths

    @Test func decodeMaskReturnsNilForOutOfRangeQuery() throws {
        let masks = try #require(makeSyntheticMaskTensor())
        let ctx = try #require(MultiGarmentProposalService.MaskTensorContext(masks: masks))

        // Query count is 2; index 99 must return nil so the caller
        // produces `RawDetection(mask: nil)` and the rect-crop
        // fallback runs.
        let result = MultiGarmentProposalService.decodeMask(from: ctx, queryIndex: 99)
        #expect(result == nil, "Expected nil for out-of-range query, got buffer")
    }

    @Test func decodeMaskReturnsNilForNegativeQuery() throws {
        let masks = try #require(makeSyntheticMaskTensor())
        let ctx = try #require(MultiGarmentProposalService.MaskTensorContext(masks: masks))

        let result = MultiGarmentProposalService.decodeMask(from: ctx, queryIndex: -1)
        #expect(result == nil, "Expected nil for negative query, got buffer")
    }

    @Test func contextInitReturnsNilForWrongRankTensor() throws {
        // 3-D tensor where the export is supposed to emit 4-D —
        // graceful-degradation guard.
        let bad = try MLMultiArray(shape: [1, 2, 4], dataType: .float32)
        let ctx = MultiGarmentProposalService.MaskTensorContext(masks: bad)
        #expect(ctx == nil, "Expected nil for wrong-rank tensor")
    }

    @Test func contextInitReturnsNilWhenLeadingDimNotOne() throws {
        // A batched export (batch dim != 1) is unexpected — the model
        // is only ever invoked with batch=1. Refuse to decode rather
        // than read the wrong query slice.
        let bad = try MLMultiArray(shape: [2, 1, 4, 4], dataType: .float32)
        let ctx = MultiGarmentProposalService.MaskTensorContext(masks: bad)
        #expect(ctx == nil, "Expected nil when leading dim != 1")
    }

    @Test func contextInitReturnsNilForZeroSizedTensor() throws {
        // A 4-D tensor with a zero query count is structurally valid
        // but produces an empty flat buffer — refuse to decode so the
        // caller doesn't try to slice an empty buffer.
        let bad = try MLMultiArray(shape: [1, 0, 4, 4], dataType: .float32)
        let ctx = MultiGarmentProposalService.MaskTensorContext(masks: bad)
        #expect(ctx == nil, "Expected nil for zero-query tensor")
    }

    // MARK: - Helpers

    /// Build a synthetic `[1, 2, 4, 4]` Float32 mask tensor where
    /// query 0's foreground is the top-left 2×2 quadrant and query 1's
    /// is the bottom-right 2×2 quadrant. Logits use ±5 so post-sigmoid
    /// they're firmly above / below the 0.5 threshold.
    private func makeSyntheticMaskTensor() -> MLMultiArray? {
        guard let arr = try? MLMultiArray(shape: [1, 2, 4, 4], dataType: .float32) else {
            return nil
        }
        // Initialise everything to a strong negative logit so the
        // background is firmly < 0.5 post-sigmoid.
        for q in 0..<2 {
            for y in 0..<4 {
                for x in 0..<4 {
                    arr[[NSNumber(value: 0),
                         NSNumber(value: q),
                         NSNumber(value: y),
                         NSNumber(value: x)]] = NSNumber(value: Float(-5.0))
                }
            }
        }
        // Query 0: top-left 2×2 → +5.
        for y in 0..<2 {
            for x in 0..<2 {
                arr[[0, 0, NSNumber(value: y), NSNumber(value: x)]] = NSNumber(value: Float(5.0))
            }
        }
        // Query 1: bottom-right 2×2 → +5.
        for y in 2..<4 {
            for x in 2..<4 {
                arr[[0, 1, NSNumber(value: y), NSNumber(value: x)]] = NSNumber(value: Float(5.0))
            }
        }
        return arr
    }

    /// Read every pixel of a `kCVPixelFormatType_OneComponent8` buffer
    /// into a `[UInt8]` indexed `(y * width) + x`. Honours bytesPerRow
    /// since iOS may align rows to 16- or 64-byte boundaries.
    private func readPixels(_ buffer: CVPixelBuffer) -> [UInt8] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bpr = CVPixelBufferGetBytesPerRow(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return [] }
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        var out = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                out[y * width + x] = bytes[y * bpr + x]
            }
        }
        return out
    }
}
