import CoreGraphics
import Foundation
import Testing
import UIKit
@testable import WardrobeReDo

/// Phase C3 of the build-6 crash audit: expanded NaN/Inf fuzzing for
/// the PR #29 color-extraction-v2 path.
///
/// **What this catches.** The post-PR #29 pipeline runs
/// `un-premultiply → sRGB → linear → CIELAB → k-means` on every
/// extracted clothing photo. Any of those stages can produce non-finite
/// values when fed degenerate inputs:
///   * `alpha = 0` lets `r/g/b` escape `[0, 1]` (un-premultiply
///     divides by zero) — handled in build-7 hotfix #31 (B2)
///   * Very small alpha lets channel values inflate past 1.0 (un-
///     premultiplied pre-multiplied 8-bit values like rp=255, alpha=128
///     decode to 510 — would feed `pow(c, 2.4)` an out-of-range input)
///   * Solid-black images (all zeros, alpha 255) produce L = 0, a = b = 0
///     which the merge loop has historically struggled with
///   * 1×1 / 1-pixel-wide images stress the 50×50 downsample box edge
///     cases
///
/// **The contract.** `extractColors(from:)` MUST:
///   1. Never crash, no matter how degenerate the input
///   2. Return only `ExtractedColor`s with finite L, a, b, percentage
///   3. Return either an empty array or a non-trivial palette — no
///      partially-populated palettes with NaN slots
///
/// `LargeImageProcessingTests.extractColorsHandlesAlphaZeroPixelsWithoutNaN`
/// covers the alpha-zero case end-to-end. This suite expands across
/// the rest of the input edges parametrically.
@Suite("ColorExtractionService.fuzz") struct ColorExtractionServiceFuzzTests {

    // MARK: - All-zero alpha, garbage RGB

    /// Whole-image alpha = 0, garbage RGB. Production hits this when
    /// a mask zeros out every pixel.
    @Test func extractColorsAllAlphaZero() async {
        let image = makeFuzzImage(size: 64) { _, _ in
            // Garbage RGB, alpha = 0.
            (UInt8.random(in: 0...255), UInt8.random(in: 0...255), UInt8.random(in: 0...255), 0)
        }

        let palette = await ColorExtractionService().extractColors(from: image)
        // Empty palette is the correct answer — every pixel was
        // alpha-rejected. The contract is "no NaN, no crash, no
        // trivially-broken entries".
        for color in palette {
            #expect(color.lightness.isFinite)
            #expect(color.saturation.isFinite)
            #expect(color.hue.isFinite)
            #expect(color.percentage.isFinite)
        }
    }

    // MARK: - Solid-black opaque

    @Test func extractColorsSolidBlackOpaque() async {
        let image = makeFuzzImage(size: 64) { _, _ in (0, 0, 0, 255) }
        let palette = await ColorExtractionService().extractColors(from: image)
        // Solid black should produce one cluster centered near
        // L≈0, a≈0, b≈0. No NaN.
        for color in palette {
            #expect(color.lightness.isFinite)
            #expect(color.saturation.isFinite)
            #expect(color.hue.isFinite)
            #expect(color.percentage.isFinite)
        }
    }

    // MARK: - Solid-white opaque

    @Test func extractColorsSolidWhiteOpaque() async {
        let image = makeFuzzImage(size: 64) { _, _ in (255, 255, 255, 255) }
        let palette = await ColorExtractionService().extractColors(from: image)
        for color in palette {
            #expect(color.lightness.isFinite)
            #expect(color.saturation.isFinite)
            #expect(color.hue.isFinite)
            #expect(color.percentage.isFinite)
        }
    }

    // MARK: - Inflated channels (low alpha + max pre-multiplied RGB)

    /// In a `premultipliedLast` bitmap, the encoded byte is
    /// `r * alpha / 255`. When alpha is very small (e.g. 1), even a
    /// fully-saturated logical color encodes as 0/0/0/1 — round-trip
    /// is fine. The dangerous case is *invalid* premultiplication
    /// (a buffer where the encoded RGB exceeds the encoded alpha),
    /// which can happen if upstream code stamps a pixel without
    /// honouring the format. Un-premultiply then divides
    /// `rp / alpha` and produces a value > 1.0.
    ///
    /// Build-7 hotfix B2 added an explicit `min(rp / alpha, 1.0)` clamp;
    /// this test verifies that clamp holds when the input is
    /// malformed-on-purpose.
    @Test func extractColorsHandlesInvalidPremultiplication() async {
        // Construct a buffer where each pixel has rp=255, gp=255, bp=255,
        // alpha=64. Logically that's r/g/b = 255/64 ≈ 4.0 — way out of
        // range. The clamp must rescue.
        let image = makeFuzzImage(size: 64) { _, _ in (255, 255, 255, 64) }

        let palette = await ColorExtractionService().extractColors(from: image)
        for color in palette {
            #expect(color.lightness.isFinite,
                    "lightness was non-finite (\(color.lightness)) for invalid-premul input")
            #expect(color.saturation.isFinite,
                    "saturation was non-finite (\(color.saturation)) for invalid-premul input")
            #expect(color.hue.isFinite,
                    "hue was non-finite (\(color.hue)) for invalid-premul input")
            #expect(color.percentage.isFinite,
                    "percentage was non-finite (\(color.percentage)) for invalid-premul input")
        }
    }

    // MARK: - 1×1 minimum-size

    @Test func extractColorsOnSinglePixelImage() async {
        let image = makeFuzzImage(size: 1) { _, _ in (200, 50, 50, 255) }
        let palette = await ColorExtractionService().extractColors(from: image)
        // Either empty (downsample collapsed the lone pixel) or one
        // entry. Both are correct; non-finite is not.
        for color in palette {
            #expect(color.lightness.isFinite)
            #expect(color.saturation.isFinite)
            #expect(color.hue.isFinite)
            #expect(color.percentage.isFinite)
        }
    }

    // MARK: - Half-and-half (opaque foreground, alpha-0 background)

    /// The most common production shape: a masked clothing photo —
    /// some opaque pixels (the garment) and some alpha-0 pixels (the
    /// rejected background). Cover the case where the rejection
    /// pattern is exactly 50/50 to flush out any divisor-going-to-zero
    /// edges in the percentage normalization.
    @Test func extractColorsHalfMasked() async {
        let size = 80
        let image = makeFuzzImage(size: size) { x, y in
            if y < size / 2 {
                return (40, 90, 200, 255) // opaque blue garment
            }
            return (UInt8.random(in: 0...255), UInt8.random(in: 0...255), UInt8.random(in: 0...255), 0)
        }
        let palette = await ColorExtractionService().extractColors(from: image)
        // Should yield exactly one non-trivial entry (blue family).
        // Don't assert the exact hue family — k-means clustering is
        // sensitive to seeding — but assert finite-valued + non-empty.
        #expect(!palette.isEmpty, "half-masked solid-blue should produce a palette")
        for color in palette {
            #expect(color.lightness.isFinite)
            #expect(color.saturation.isFinite)
            #expect(color.hue.isFinite)
            #expect(color.percentage.isFinite)
            // `ExtractedColor.percentage` is reported as 0–100 (a
            // share-of-frame in percent), not a [0, 1] fraction.
            #expect(color.percentage >= 0 && color.percentage <= 100.0,
                    "percentage \(color.percentage) outside [0, 100]")
        }
    }

    // MARK: - Extreme aspect-ratio (1×512)

    /// Pathological aspect ratios stress the downsample box. A 1-pixel
    /// strip is the geometric edge case most likely to trip an
    /// off-by-one in the pixel-iteration loop.
    @Test func extractColorsTallStripImage() async {
        let width = 1
        let height = 512
        let image = makeFuzzImage(width: width, height: height) { _, y in
            // Vertical hue gradient — each row a different color.
            (UInt8(y % 256), UInt8((y * 2) % 256), UInt8((y * 3) % 256), 255)
        }
        let palette = await ColorExtractionService().extractColors(from: image)
        for color in palette {
            #expect(color.lightness.isFinite)
            #expect(color.saturation.isFinite)
            #expect(color.hue.isFinite)
            #expect(color.percentage.isFinite)
        }
    }

    // MARK: - Helpers

    /// Build a square premultiplied-RGBA `UIImage` whose pixel values
    /// come from the closure. The closure receives `(x, y)` and
    /// returns a `(r, g, b, alpha)` byte tuple in **premultiplied**
    /// form (the same layout `CGImageAlphaInfo.premultipliedLast`
    /// expects on the wire — the test does not mediate; if you pass
    /// `(255, 255, 255, 64)` you get a bitmap with that encoded byte
    /// pattern, valid or otherwise).
    private func makeFuzzImage(
        size: Int,
        _ pixel: (_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8, UInt8)
    ) -> UIImage {
        makeFuzzImage(width: size, height: size, pixel)
    }

    private func makeFuzzImage(
        width: Int,
        height: Int,
        _ pixel: (_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8, UInt8)
    ) -> UIImage {
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b, a) = pixel(x, y)
                let idx = (y * width + x) * 4
                rgba[idx + 0] = r
                rgba[idx + 1] = g
                rgba[idx + 2] = b
                rgba[idx + 3] = a
            }
        }
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: &rgba,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let cg = ctx.makeImage()!
        return UIImage(cgImage: cg)
    }
}
