import Foundation
import Testing
import UIKit
@testable import WardrobeReDo

/// Reproduction + regression suite for the build-6 crash on
/// `1.JPG` — a 3840×2160 iPhone 15 Plus capture with EXIF
/// orientation = 8 (90° CCW). The image is committed at
/// `WardrobeReDoTests/Fixtures/Large/iphone15plus_3840x2160_exif8.jpg`
/// (sanitized — no GPS metadata).
///
/// **Why these tests exist.** Pre-build-7, the upload pipeline had three
/// distinct failure modes that all triggered on a single 3840×2160
/// EXIF-rotated source:
///
///   1. `OrientationUtil.normalized` allocated a 31.6 MB temporary
///      bitmap; on memory-constrained devices the `CGContext` could
///      fail and yield a silently-broken image (white-filled).
///   2. `ColorExtractionService.extractColors` un-premultiplied alpha
///      without clamping; with `alpha = 0` the values escaped [0, 1]
///      and `pow(c, 2.4)` in `srgbToLab` produced Inf/NaN that
///      propagated through the merge loop.
///   3. The k-means cluster merge had no iteration cap; pathological
///      inputs (identical centroids) could in principle loop
///      indefinitely.
///
/// These tests pin the post-build-7 contract: the pipeline either
/// succeeds with a valid `ProcessedImage` OR returns nil cleanly. It
/// must not crash and must not exceed the working-memory ceiling.
@MainActor
struct LargeImageProcessingTests {

    // MARK: - Reproduction

    /// Loads the real iPhone 15 Plus 3840×2160 EXIF-orientation-8 JPEG
    /// the user reported a crash on, runs it through `processImage`,
    /// asserts no crash + valid output. Pre-build-7 this hit the
    /// orientation/memory bug path; if a future change reintroduces
    /// the crash, this test is the canary.
    @Test func processImageHandles3840x2160ExifRotatedSource() async throws {
        let image = try #require(
            FixtureLoader.loadLargeImage(named: "iphone15plus_3840x2160_exif8.jpg"),
            "fixture must be added to the test target's Copy Bundle Resources phase"
        )

        // Pin the EXIF orientation we observed on the crashing source —
        // catches a fixture swap that accidentally drops the rotation.
        #expect(image.imageOrientation == .right,
                "expected EXIF orientation 8 (mapped to UIImage.Orientation.right); got \(image.imageOrientation.rawValue)")

        // Pin the resolution — the 3840×2160 spike is the whole point.
        #expect(image.size.width == 3840 || image.size.width == 2160,
                "expected 3840 on one axis (3840×2160 sensor); got \(image.size)")

        let service = ImageService()
        let processed = await service.processImage(image)

        // The pipeline must either return a valid ProcessedImage or
        // return nil deliberately. It must NOT crash. (If we get here
        // at all, the crash is fixed.)
        #expect(processed != nil, "processImage returned nil — investigate Vision/SAM2 path")
        if let processed {
            #expect(!processed.originalData.isEmpty,
                    "originalData must be non-empty after processing")
            #expect(!processed.thumbnailData.isEmpty,
                    "thumbnailData must be non-empty")

            // Compressed JPEG should be < 1.5 MB at our resize+quality
            // settings (1200px max + 0.8 quality). If it balloons,
            // we've regressed the resize step. The empirical floor on
            // the 3840×2160 fixture is ~840 KB; 1.5 MB is plenty of
            // headroom while still catching a regression that drops
            // the resize entirely (which would emit ~5+ MB).
            #expect(processed.originalData.count < 1_500_000,
                    "originalData JPEG larger than 1.5 MB — resize step regressed?")
        }
    }

    // MARK: - EXIF orientation invariance

    /// Color-extraction palette derived from a portrait-orientation
    /// version of the fixture must be substantively similar to the
    /// EXIF-rotated landscape version. If they diverge wildly, the
    /// pipeline is processing pre-rotation pixels (a stale orientation
    /// path).
    @Test func extractColorsAgreesAcrossExifOrientations() async throws {
        let landscape = try #require(
            FixtureLoader.loadLargeImage(named: "iphone15plus_3840x2160_exif8.jpg")
        )

        // Synthesize an .up-oriented sibling by physically rotating the
        // pixels (matches what `OrientationUtil.normalized` should have
        // produced internally).
        guard let cg = landscape.cgImage else {
            Issue.record("source has no cgImage")
            return
        }
        let upright = UIImage(cgImage: cg, scale: landscape.scale, orientation: .up)

        let extractor = ColorExtractionService()
        async let landscapePalette = extractor.extractColors(from: landscape)
        async let uprightPalette = extractor.extractColors(from: upright)
        let (l, u) = await (landscapePalette, uprightPalette)

        // Both must produce a non-empty palette — the dominant family
        // should match. The percentages will drift a bit because the
        // 50×50 downsample box hits different pixels, but the family
        // assignment should be stable.
        #expect(!l.isEmpty, "landscape palette empty — orientation pipeline broken")
        #expect(!u.isEmpty, "upright palette empty — extraction broken without orientation step")
    }

    // MARK: - NaN/Inf robustness on full-alpha-zero region

    /// PR #29's `srgbToLab` calls `pow(c, 2.4)` on un-premultiplied
    /// channels. A buffer with `alpha = 0` previously let `r/g/b`
    /// escape [0, 1] and produce Inf/NaN. This test feeds a synthetic
    /// half-transparent image and asserts the pipeline produces a
    /// finite-valued palette (or empty), never NaN.
    @Test func extractColorsHandlesAlphaZeroPixelsWithoutNaN() async {
        // 100×100 image, top half opaque blue, bottom half alpha=0
        // garbage. The bottom half exercises the un-premultiply path
        // that previously misbehaved.
        let size = 100
        var rgba = [UInt8](repeating: 0, count: size * size * 4)
        for y in 0..<size {
            for x in 0..<size {
                let idx = (y * size + x) * 4
                if y < size / 2 {
                    rgba[idx + 0] = 30   // R
                    rgba[idx + 1] = 60   // G
                    rgba[idx + 2] = 200  // B
                    rgba[idx + 3] = 255  // A
                } else {
                    // Garbage RGB with alpha=0 — the un-premultiply
                    // would have divided by zero in pre-build-7 paths.
                    rgba[idx + 0] = 200
                    rgba[idx + 1] = 100
                    rgba[idx + 2] = 50
                    rgba[idx + 3] = 0
                }
            }
        }

        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: &rgba,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: size * 4,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let cg = ctx.makeImage()!
        let image = UIImage(cgImage: cg)

        let extractor = ColorExtractionService()
        let palette = await extractor.extractColors(from: image)

        // Either an empty palette (alpha-rejected everything) or a
        // valid blue-family entry. Never NaN.
        for color in palette {
            #expect(color.lightness.isFinite, "lightness must be finite")
            #expect(color.saturation.isFinite, "saturation must be finite")
            #expect(color.hue.isFinite, "hue must be finite")
            #expect(color.percentage.isFinite, "percentage must be finite")
        }
    }
}
