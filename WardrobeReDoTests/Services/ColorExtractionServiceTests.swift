import CoreGraphics
import Foundation
import Testing
import UIKit
@testable import WardrobeReDo

// MARK: - ColorExtractionService Math Tests

private let service = ColorExtractionService()

// MARK: - rgbToHSL

@Test func rgbToHSLPureRed() {
    let result = service.rgbToHSL(r: 1.0, g: 0.0, b: 0.0)
    #expect(abs(result.h - 0.0) < 1.0)
    #expect(abs(result.s - 1.0) < 0.01)
    #expect(abs(result.l - 0.5) < 0.01)
}

@Test func rgbToHSLPureGreen() {
    let result = service.rgbToHSL(r: 0.0, g: 1.0, b: 0.0)
    #expect(abs(result.h - 120.0) < 1.0)
    #expect(abs(result.s - 1.0) < 0.01)
    #expect(abs(result.l - 0.5) < 0.01)
}

@Test func rgbToHSLPureBlue() {
    let result = service.rgbToHSL(r: 0.0, g: 0.0, b: 1.0)
    #expect(abs(result.h - 240.0) < 1.0)
    #expect(abs(result.s - 1.0) < 0.01)
    #expect(abs(result.l - 0.5) < 0.01)
}

@Test func rgbToHSLWhite() {
    let result = service.rgbToHSL(r: 1.0, g: 1.0, b: 1.0)
    #expect(result.s == 0.0)
    #expect(result.l == 1.0)
}

@Test func rgbToHSLBlack() {
    let result = service.rgbToHSL(r: 0.0, g: 0.0, b: 0.0)
    #expect(result.s == 0.0)
    #expect(result.l == 0.0)
}

// MARK: - colorDistance

@Test func colorDistanceIdenticalIsZero() {
    let color = (r: 0.5, g: 0.3, b: 0.7)
    let distance = service.colorDistance(color, color)
    #expect(distance == 0.0)
}

@Test func colorDistanceKnownValues() {
    let black = (r: 0.0, g: 0.0, b: 0.0)
    let white = (r: 1.0, g: 1.0, b: 1.0)
    let distance = service.colorDistance(black, white)
    // sqrt(1^2 + 1^2 + 1^2) = sqrt(3) but distance uses squared distance
    #expect(abs(distance - 3.0) < 0.001)
}

// MARK: - colorFamily

@Test func colorFamilyRedHue() {
    let family = service.colorFamily(hue: 0, saturation: 0.7, lightness: 0.5)
    #expect(family == "red")
}

@Test func colorFamilyBlueHue() {
    let family = service.colorFamily(hue: 220, saturation: 0.7, lightness: 0.5)
    #expect(family == "blue")
}

@Test func colorFamilyLowSaturationGray() {
    let family = service.colorFamily(hue: 100, saturation: 0.05, lightness: 0.5)
    #expect(family == "gray")
}

@Test func colorFamilyNavyDarkBlue() {
    let family = service.colorFamily(hue: 220, saturation: 0.7, lightness: 0.2)
    #expect(family == "navy")
}

// MARK: - isNeutral

@Test func isNeutralLowSaturation() {
    #expect(service.isNeutral(saturation: 0.1, lightness: 0.5) == true)
}

@Test func isNeutralVeryDark() {
    #expect(service.isNeutral(saturation: 0.5, lightness: 0.1) == true)
}

@Test func isNeutralVeryLight() {
    #expect(service.isNeutral(saturation: 0.5, lightness: 0.95) == true)
}

@Test func isNeutralFalseForSaturatedMidtone() {
    #expect(service.isNeutral(saturation: 0.5, lightness: 0.5) == false)
}

// MARK: - rgbToHex

@Test func rgbToHexPureRed() {
    let hex = service.rgbToHex(r: 1.0, g: 0.0, b: 0.0)
    #expect(hex == "#FF0000")
}

@Test func rgbToHexBlack() {
    let hex = service.rgbToHex(r: 0.0, g: 0.0, b: 0.0)
    #expect(hex == "#000000")
}

// MARK: - PR #26: CIELAB clustering, ΔE76 merge, skin-tone, alpha, min-%

// MARK: sRGB <-> CIELAB roundtrip sanity

@Test func srgbToLabRoundtripPureBlue() {
    let lab = service.srgbToLab(r: 0.0, g: 0.0, b: 1.0)
    // CIE-published values for sRGB pure blue: L*≈32.30, a*≈79.19, b*≈-107.86
    #expect(abs(lab.L - 32.30) < 0.5)
    #expect(abs(lab.a - 79.19) < 0.5)
    #expect(abs(lab.b - (-107.86)) < 0.5)

    let rgb = service.labToSrgb(lab)
    #expect(abs(rgb.r - 0.0) < 0.01)
    #expect(abs(rgb.g - 0.0) < 0.01)
    #expect(abs(rgb.b - 1.0) < 0.01)
}

@Test func srgbToLabWhiteIsL100() {
    let lab = service.srgbToLab(r: 1.0, g: 1.0, b: 1.0)
    #expect(abs(lab.L - 100.0) < 0.5)
    #expect(abs(lab.a) < 1.0)
    #expect(abs(lab.b) < 1.0)
}

// MARK: ΔE76

@Test func deltaE76IdenticalIsZero() {
    let lab = LabColor(L: 50, a: 10, b: 20)
    #expect(service.deltaE76(lab, lab) == 0.0)
}

@Test func deltaE76OnLAxis() {
    // ΔE76 is plain Euclidean: two points differing only in L by 10
    // should produce a distance of 10.
    let a = LabColor(L: 40, a: 0, b: 0)
    let b = LabColor(L: 50, a: 0, b: 0)
    #expect(abs(service.deltaE76(a, b) - 10.0) < 0.001)
}

// MARK: Cluster merging

@Test func mergesSimilarClustersInLab() {
    // Five nearly-identical blues — the canonical "5 shades of blue"
    // case from build-4 dogfood. Each centroid is within ΔE76 ≈ 3 of
    // its neighbors, well below the 8.0 merge threshold.
    let clusters: [ColorExtractionService.LabCluster] = [
        .init(center: LabColor(L: 30, a: 20, b: -50), count: 200),
        .init(center: LabColor(L: 32, a: 21, b: -51), count: 180),
        .init(center: LabColor(L: 34, a: 22, b: -52), count: 160),
        .init(center: LabColor(L: 36, a: 23, b: -53), count: 140),
        .init(center: LabColor(L: 38, a: 24, b: -54), count: 120),
    ]

    let merged = service.mergeSimilarClusters(clusters, threshold: 8.0)

    #expect(merged.count == 1, "Expected one cluster after merging 5 near-identical blues; got \(merged.count)")
    #expect(merged[0].count == 800, "Merged count should be the sum of all five inputs")
    // Centroid should land somewhere in the input span — sanity check it's still blue.
    let merged0 = merged[0].center
    #expect(merged0.L >= 30 && merged0.L <= 38)
    #expect(merged0.b < 0, "Merged blue should retain negative b* (yellow-blue axis)")
}

@Test func mergeKeepsDistinctColorsApart() {
    // Red vs blue — far apart in Lab. Threshold 8.0 must not merge them.
    let clusters: [ColorExtractionService.LabCluster] = [
        .init(center: LabColor(L: 53, a: 80, b: 67), count: 100),    // red
        .init(center: LabColor(L: 32, a: 79, b: -107), count: 100),  // blue
    ]
    let merged = service.mergeSimilarClusters(clusters, threshold: 8.0)
    #expect(merged.count == 2, "Red and blue must not merge under ΔE76 ≤ 8")
}

@Test func mergeWeightedByPopulation() {
    // 90% near one centroid, 10% at the edge of the merge ring.
    // The merged centroid must be pulled toward the heavier input.
    let big = ColorExtractionService.LabCluster(
        center: LabColor(L: 50, a: 0, b: 0),
        count: 900
    )
    let small = ColorExtractionService.LabCluster(
        center: LabColor(L: 56, a: 0, b: 0),  // ΔE76 = 6 → merges
        count: 100
    )
    let merged = service.mergeSimilarClusters([big, small], threshold: 8.0)
    #expect(merged.count == 1)
    let centroidL = merged[0].center.L
    // Weighted average: 50 * 0.9 + 56 * 0.1 = 50.6
    #expect(abs(centroidL - 50.6) < 0.001)
    #expect(merged[0].count == 1000)
}

// MARK: Skin-tone exclusion

@Test func skinToneCentralBandIsDetected() {
    // Mid-warm Caucasian / tan skin: L≈65, a≈18, b≈22 — squarely in band.
    let skin = LabColor(L: 65, a: 18, b: 22)
    #expect(service.isSkinTone(skin) == true)
}

@Test func skinToneBoundaryNotDetected() {
    // Just outside the gamut on the a* axis (a < 10).
    let notSkin = LabColor(L: 65, a: 5, b: 22)
    #expect(service.isSkinTone(notSkin) == false)
}

@Test func skinToneCorePalettesNotDetected() {
    // Pure red, pure blue, pure white, neutral gray must NEVER be
    // mistaken for skin — those are core palette colors that any
    // garment may legitimately contain.
    let red = service.srgbToLab(r: 1.0, g: 0.0, b: 0.0)
    let blue = service.srgbToLab(r: 0.0, g: 0.0, b: 1.0)
    let white = service.srgbToLab(r: 1.0, g: 1.0, b: 1.0)
    let gray = service.srgbToLab(r: 0.5, g: 0.5, b: 0.5)

    #expect(service.isSkinTone(red) == false)
    #expect(service.isSkinTone(blue) == false)
    #expect(service.isSkinTone(white) == false)
    #expect(service.isSkinTone(gray) == false)
}

// MARK: End-to-end via UIImage fixtures

@Test func dropsSkinToneCluster() async {
    // 50% skin-tone (warm tan, RGB ≈ 200,150,120 → squarely in skin gamut)
    // + 50% blue. Pipeline should drop the skin cluster.
    let image = ColorTestImage.halfHalf(
        topRGB: (200, 150, 120),  // skin
        bottomRGB: (50, 80, 200), // blue
        size: 50
    )

    let svc = ColorExtractionService()
    let colors = await svc.extractColors(from: image, maxColors: 5)

    #expect(!colors.isEmpty, "Pipeline must return at least one color")
    let families = Set(colors.map { $0.colorFamily })
    // Blue should remain.
    #expect(
        families.contains("blue") || families.contains("navy"),
        "Expected blue / navy in palette; got \(families)"
    )
    // Orange (the named family for skin-band hues) must not be top result.
    if let dominant = colors.first {
        #expect(
            dominant.colorFamily != "orange",
            "Skin-tone cluster leaked through as dominant: \(dominant.colorFamily) \(dominant.hex)"
        )
    }
}

@Test func dropsBelowOnePercentCluster() async {
    // 99% blue + ~1% red sliver. After merging-sized blues into one
    // cluster the red would otherwise survive at < 1% — the min-%
    // filter must drop it. Render the red as a single 5x5 patch
    // (25 pixels = 1% of 2500) so it sits right on the boundary.
    let image = ColorTestImage.dominantWithSliver(
        dominantRGB: (50, 80, 200),  // blue
        sliverRGB: (220, 30, 30),    // red
        size: 50,
        sliverSize: 4                // 16 px = 0.64% — below 1.0% floor
    )

    let svc = ColorExtractionService()
    let colors = await svc.extractColors(from: image, maxColors: 5)

    #expect(!colors.isEmpty)
    // No returned cluster should be below the 1.0% floor (the
    // dominant cluster is allowed to surface even if it ends up
    // below 1% in pathological cases, but the red sliver here is
    // dominated by the blue and must be filtered out).
    let nonDominant = colors.dropFirst()
    for color in nonDominant {
        #expect(color.percentage >= 1.0, "Cluster below 1% slipped through: \(color.hex) at \(color.percentage)%")
    }
    // Red (the sliver) must not appear at all.
    let families = Set(colors.map { $0.colorFamily })
    #expect(!families.contains("red"), "Red sliver < 1% must be filtered; got \(families)")
}

@Test func usesAlphaThreshold200() async {
    // Two-band image: top half blue at α=255 ("interior"), bottom
    // half red at α=150 ("soft-edge fringe"). With the new
    // threshold of 200, only the blue cluster should reach k-means.
    let image = ColorTestImage.alphaSplit(
        topRGB: (50, 80, 200),
        topAlpha: 255,
        bottomRGB: (220, 30, 30),
        bottomAlpha: 150,
        size: 50
    )

    let svc = ColorExtractionService()
    let colors = await svc.extractColors(from: image, maxColors: 5)

    #expect(!colors.isEmpty)
    let families = Set(colors.map { $0.colorFamily })
    // Blue/navy must remain; red must be excluded by the α=200 gate.
    #expect(
        families.contains("blue") || families.contains("navy"),
        "Blue must survive; got \(families)"
    )
    #expect(
        !families.contains("red"),
        "Red at α=150 must be filtered by the α≥200 threshold; got \(families)"
    )
}

// MARK: - Test Image Fixtures (PR #26)

/// Synthetic UIImage helpers for ColorExtractionService end-to-end
/// tests. Each builds a small RGBA8 buffer with deterministic pixel
/// content, wraps it in a CGImage, and returns a UIImage. Kept inline
/// so this test file is self-contained — the existing fixture loader
/// is for on-disk Vision masks, not synthetic palettes.
private enum ColorTestImage {

    /// Top half = `topRGB`, bottom half = `bottomRGB`. Both fully
    /// opaque (α=255).
    static func halfHalf(
        topRGB: (UInt8, UInt8, UInt8),
        bottomRGB: (UInt8, UInt8, UInt8),
        size: Int
    ) -> UIImage {
        var bytes = [UInt8](repeating: 0, count: size * size * 4)
        for y in 0..<size {
            for x in 0..<size {
                let i = (y * size + x) * 4
                let rgb = y < size / 2 ? topRGB : bottomRGB
                bytes[i] = rgb.0
                bytes[i + 1] = rgb.1
                bytes[i + 2] = rgb.2
                bytes[i + 3] = 255
            }
        }
        return makeImage(bytes: bytes, size: size)
    }

    /// Whole image = `dominantRGB`, except a `sliverSize`×`sliverSize`
    /// patch in the corner painted in `sliverRGB`. Both opaque.
    static func dominantWithSliver(
        dominantRGB: (UInt8, UInt8, UInt8),
        sliverRGB: (UInt8, UInt8, UInt8),
        size: Int,
        sliverSize: Int
    ) -> UIImage {
        var bytes = [UInt8](repeating: 0, count: size * size * 4)
        for y in 0..<size {
            for x in 0..<size {
                let i = (y * size + x) * 4
                let inSliver = x < sliverSize && y < sliverSize
                let rgb = inSliver ? sliverRGB : dominantRGB
                bytes[i] = rgb.0
                bytes[i + 1] = rgb.1
                bytes[i + 2] = rgb.2
                bytes[i + 3] = 255
            }
        }
        return makeImage(bytes: bytes, size: size)
    }

    /// Top half RGB at `topAlpha`, bottom half RGB at `bottomAlpha`.
    /// Used to exercise the α-threshold gate. Bytes are stored
    /// premultiplied (matches the `premultipliedLast` CGContext the
    /// service uses for downsampling, so the un-premult math
    /// recovers the input).
    static func alphaSplit(
        topRGB: (UInt8, UInt8, UInt8),
        topAlpha: UInt8,
        bottomRGB: (UInt8, UInt8, UInt8),
        bottomAlpha: UInt8,
        size: Int
    ) -> UIImage {
        var bytes = [UInt8](repeating: 0, count: size * size * 4)
        for y in 0..<size {
            for x in 0..<size {
                let i = (y * size + x) * 4
                let isTop = y < size / 2
                let rgb = isTop ? topRGB : bottomRGB
                let alpha = isTop ? topAlpha : bottomAlpha
                let af = Double(alpha) / 255.0
                bytes[i] = UInt8(min(Double(rgb.0) * af, 255.0))
                bytes[i + 1] = UInt8(min(Double(rgb.1) * af, 255.0))
                bytes[i + 2] = UInt8(min(Double(rgb.2) * af, 255.0))
                bytes[i + 3] = alpha
            }
        }
        return makeImage(bytes: bytes, size: size)
    }

    private static func makeImage(bytes: [UInt8], size: Int) -> UIImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        let cgImage = CGImage(
            width: size,
            height: size,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: size * 4,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!
        return UIImage(cgImage: cgImage)
    }
}
