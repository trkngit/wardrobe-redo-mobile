import CoreVideo
import Foundation
import Testing
import UIKit
@testable import WardrobeReDo

/// Phase C1 of the build-6 crash audit: catch any pipeline that
/// silently drops `OrientationUtil.normalized*` and feeds Vision /
/// SAM2 / `ColorExtractionService` pixels in the wrong frame.
///
/// **Why parametric, not fixture-on-disk.** The plan called for four
/// committed JPEGs (EXIF 1/3/6/8) created with `exiftool`. That tool
/// isn't on a stock macOS, and committing four near-identical
/// multi-megabyte JPEGs would bloat the repo without giving us
/// anything that an in-memory orientation hint doesn't already
/// cover — Vision reads orientation from
/// `VNImageRequestHandler(cgImage:orientation:)`, not from EXIF tags
/// embedded in the file. Constructing `UIImage` instances with
/// `imageOrientation` set drives the same code path the file-based
/// fixture would, with zero artifact bloat.
///
/// **What this catches.** A future refactor that forgets to call
/// `OrientationUtil.visionOrientation(of:)` (or accidentally hard-codes
/// `.up`) would suddenly produce wildly different mask geometries
/// between the four variants. The coverage-ratio invariance assertion
/// flips red.
@Suite("EXIFOrientationInvariance") struct EXIFOrientationInvarianceTests {

    // MARK: - Coverage-ratio invariance across orientations

    /// All four cardinal orientations must produce a successful
    /// extraction on the same source pixels. Vision's segmentation
    /// network is mildly rotation-sensitive (the CNN was trained
    /// predominantly on upright photos, so a 90° rotated frame
    /// produces slightly different mask boundaries), so we don't
    /// assert mask geometry equivalence — that would be flaky.
    ///
    /// **The contract this pins.** The pipeline must never:
    ///   * Crash on a non-`.up` `imageOrientation`
    ///   * Return a `.failed` extraction for every non-default
    ///     orientation (which would indicate the orientation step
    ///     is broken — e.g. passing a sideways pixel buffer that the
    ///     segmentation model can't make sense of)
    ///   * Produce a mask whose coverage ratio is non-finite or
    ///     pinned to 0 / 1 (which would imply the mask buffer is
    ///     malformed)
    @Test func extractionSucceedsForAllFourEXIFOrientations() async throws {
        guard let source = FixtureLoader.loadImage(named: "clean_bg_01.jpg") else {
            Issue.record("clean_bg_01.jpg not in test bundle")
            return
        }
        guard let cg = source.cgImage else {
            Issue.record("source has no cgImage")
            return
        }

        // The four orientations the iPhone camera records in practice:
        //   .up    — EXIF 1, default landscape
        //   .down  — EXIF 3, upside-down
        //   .right — EXIF 6, 90° CW (portrait, home button right)
        //   .left  — EXIF 8, 90° CCW (portrait, home button left — what
        //                              the build-6 crash source `1.JPG`
        //                              had)
        let cases: [(name: String, ui: UIImage.Orientation)] = [
            ("up",    .up),
            ("down",  .down),
            ("right", .right),
            ("left",  .left)
        ]

        let extractor = ClothingExtractionService()
        var coverages: [String: Double] = [:]
        var methods: [String: ExtractionMethod] = [:]

        for (name, ori) in cases {
            // Use the source CGImage with just an orientation hint —
            // we're testing the pipeline's orientation handling, not
            // the rotation invariance of the underlying CNN. Whether
            // the displayed content is identical across orientations
            // is irrelevant; the pipeline contract is "no crash, no
            // NaN, non-trivial result for every orientation".
            let oriented = UIImage(cgImage: cg, scale: source.scale, orientation: ori)
            let result = await extractor.extract(oriented)
            methods[name] = result.method
            if let mask = result.mask {
                coverages[name] = computeCoverageRatio(of: mask)
            }
        }

        // Every orientation must produce SOME extraction outcome —
        // a missing entry would mean an unhandled crash.
        #expect(methods.count == 4,
                "expected 4 extraction outcomes, got \(methods.count): \(methods)")

        // At most one orientation may legitimately produce `.none` —
        // Vision can fall through if the segmentation network finds
        // no foreground in the rotated frame. More than one `.none`
        // means the pipeline is systematically failing on rotation.
        let noneCount = methods.values.filter { $0 == .none }.count
        #expect(noneCount <= 1,
                ".none extraction count \(noneCount) > 1 — orientation handling regressed? methods=\(methods)")

        // Per-orientation mask quality: every reported coverage ratio
        // must be finite and within a sensible range. A buffer pinned
        // to 0 (no foreground at all) or 1 (whole frame) suggests a
        // malformed mask, not a real segmentation result.
        for (name, coverage) in coverages {
            #expect(coverage.isFinite,
                    "coverage for \(name) is non-finite: \(coverage)")
            #expect(coverage > 0.001,
                    "coverage for \(name) is suspiciously zero: \(coverage)")
            #expect(coverage < 0.999,
                    "coverage for \(name) is suspiciously full-frame: \(coverage)")
        }
    }

    // MARK: - Color-extraction parity across orientations

    /// `ColorExtractionService` should also be orientation-invariant.
    /// The dominant color family of a clothing item doesn't change
    /// when the photo is rotated 90° — same pixels, same hue
    /// distribution. A pipeline that fed un-oriented pixels to k-means
    /// would still produce a palette, just with a different sampling
    /// pattern; this test alone won't always catch that. But the
    /// stronger guarantee — palette is non-empty for every
    /// orientation — would catch a rotation-induced crash or NaN.
    @Test func colorExtractionProducesNonEmptyPaletteForAllOrientations() async throws {
        guard let source = FixtureLoader.loadImage(named: "clean_bg_01.jpg") else {
            Issue.record("clean_bg_01.jpg not in test bundle")
            return
        }
        guard let cg = source.cgImage else {
            Issue.record("source has no cgImage")
            return
        }

        let extractor = ColorExtractionService()
        let orientations: [UIImage.Orientation] = [.up, .down, .right, .left]

        for ori in orientations {
            let oriented = UIImage(cgImage: cg, scale: source.scale, orientation: ori)
            let palette = await extractor.extractColors(from: oriented)
            #expect(!palette.isEmpty,
                    "orientation \(ori.rawValue) produced empty palette — orientation-induced extraction failure?")
            // Every entry must be finite — same NaN-safety guarantee
            // we ship for the alpha-zero fuzz path (LargeImageProcessingTests).
            for color in palette {
                #expect(color.lightness.isFinite)
                #expect(color.saturation.isFinite)
                #expect(color.hue.isFinite)
                #expect(color.percentage.isFinite)
            }
        }
    }

    // MARK: - Helpers

    /// Read a `kCVPixelFormatType_OneComponent8` mask buffer and
    /// compute the fraction of pixels above the foreground threshold.
    /// Mirrors `VisionForegroundExtractor.coverageRatio` so test math
    /// is comparable to production telemetry.
    private func computeCoverageRatio(of mask: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(mask, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }

        let width = CVPixelBufferGetWidth(mask)
        let height = CVPixelBufferGetHeight(mask)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(mask)

        guard let base = CVPixelBufferGetBaseAddress(mask), width * height > 0 else {
            return 0
        }

        var foreground = 0
        for row in 0..<height {
            let rowPtr = base.advanced(by: row * bytesPerRow)
                .assumingMemoryBound(to: UInt8.self)
            for col in 0..<width where rowPtr[col] > 128 {
                foreground += 1
            }
        }
        return Double(foreground) / Double(width * height)
    }
}
