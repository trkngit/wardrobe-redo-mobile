import CoreGraphics
import CoreVideo
import Foundation
import UIKit

// MARK: - FixtureLoader
//
// Resolves paths inside `WardrobeReDoTests/Fixtures/` against the current
// test bundle. The bundle is whichever `.xctest` the test runner loaded — it
// picks up everything wired into the test target's Copy Bundle Resources
// phase. We deliberately do NOT use `Bundle.main` here; that's the app
// bundle and won't see test-only fixtures.
//
// Everything returns optional. When a fixture is missing (e.g., on a fresh
// checkout where the owner hasn't traced masks yet) the caller decides
// whether to skip gracefully or fail — see `SegmentationIoUTests` for the
// pattern.

enum FixtureLoader {
    /// Bundle that contains the compiled test target, including any files in
    /// `WardrobeReDoTests/Fixtures/` that were added to the target's Copy
    /// Bundle Resources build phase.
    static let testBundle: Bundle = Bundle(for: FixtureLoaderBundleToken.self)

    /// Decoded manifest. Returns `nil` if `manifest.json` isn't in the test
    /// bundle (the capture brief explains how to add one).
    static func loadManifest() -> ExtractionFixtureManifest? {
        guard let url = testBundle.url(
            forResource: "manifest",
            withExtension: "json",
            subdirectory: "Fixtures/Extraction"
        ) ?? testBundle.url(forResource: "manifest", withExtension: "json") else {
            return nil
        }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ExtractionFixtureManifest.self, from: data)
    }

    /// Load a source photo (e.g. `clean_bg_01.jpg`) from the fixtures folder.
    static func loadImage(named name: String) -> UIImage? {
        guard let url = resourceURL(forFilename: name) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }

    /// Load a large-image stress fixture (e.g.
    /// `iphone15plus_3840x2160_exif8.jpg`) from
    /// `WardrobeReDoTests/Fixtures/Large/`. Same return contract as
    /// `loadImage(named:)` — falls back to a flat-bundle lookup so
    /// xcodegen folder-reference quirks don't break callers.
    static func loadLargeImage(named name: String) -> UIImage? {
        guard let url = largeImageURL(forFilename: name) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }

    /// Load a ground-truth alpha mask PNG. Returns the mask as a monochrome
    /// `CVPixelBuffer` (same format `VisionForegroundExtractor` emits) so IoU
    /// math can compare like-for-like. Pixels with alpha > 127 in the source
    /// PNG are treated as "clothing" (white) and everything else as
    /// background (black).
    static func loadMask(at relativePath: String) -> CVPixelBuffer? {
        guard let url = resourceURL(forFilename: relativePath) else { return nil }
        guard let cgImage = UIImage(contentsOfFile: url.path)?.cgImage else {
            return nil
        }
        return alphaMaskPixelBuffer(from: cgImage)
    }

    // MARK: - Private

    private static func resourceURL(forFilename name: String) -> URL? {
        let url = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        if ext.isEmpty {
            return testBundle.url(
                forResource: url,
                withExtension: nil,
                subdirectory: "Fixtures/Extraction"
            ) ?? testBundle.url(forResource: url, withExtension: nil)
        }
        return testBundle.url(
            forResource: url,
            withExtension: ext,
            subdirectory: "Fixtures/Extraction"
        ) ?? testBundle.url(forResource: url, withExtension: ext)
    }

    private static func largeImageURL(forFilename name: String) -> URL? {
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        let extensionOrNil: String? = ext.isEmpty ? nil : ext
        return testBundle.url(
            forResource: stem,
            withExtension: extensionOrNil,
            subdirectory: "Fixtures/Large"
        ) ?? testBundle.url(forResource: stem, withExtension: extensionOrNil)
    }

    private static func alphaMaskPixelBuffer(from cgImage: CGImage) -> CVPixelBuffer? {
        let width = cgImage.width
        let height = cgImage.height

        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_OneComponent8,
            nil,
            &buffer
        )
        guard status == kCVReturnSuccess, let pb = buffer else { return nil }

        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }

        guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        memset(base, 0, CVPixelBufferGetBytesPerRow(pb) * height)

        // Draw the source PNG into a temporary RGBA buffer so we can read the
        // alpha channel, then threshold into the mask.
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let rgbColorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &rgba,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: rgbColorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        let bytesPerRow = CVPixelBufferGetBytesPerRow(pb)
        let dst = base.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width {
                let alpha = rgba[(y * width + x) * 4 + 3]
                dst[y * bytesPerRow + x] = alpha > 127 ? 255 : 0
            }
        }
        return pb
    }
}

// MARK: - Manifest types

struct ExtractionFixtureManifest: Decodable {
    let version: Int
    let fixtures: [ExtractionFixture]
}

struct ExtractionFixture: Decodable {
    let image: String
    let mask: String
    let category: String
    let scenario: String
    let expectedIoUMin: Double
    let notes: String?

    enum CodingKeys: String, CodingKey {
        case image, mask, category, scenario, notes
        case expectedIoUMin = "expected_iou_min"
    }
}

// MARK: - Private bundle token

/// Empty class that lives in the test target. We pass its type to
/// `Bundle(for:)` to grab the test bundle without coupling the loader to
/// any particular test's name.
private final class FixtureLoaderBundleToken {}
