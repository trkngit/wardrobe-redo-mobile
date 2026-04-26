import CoreImage
import OSLog
import UIKit

/// Capture-pipeline telemetry. PR #26 overhauled this from RGB k-means
/// to CIELAB k-means + ΔE76 cluster merging + skin-tone suppression
/// + min-% filter. The logger remains so build-5 dogfood can observe
/// the new pipeline's merge / filter / skin-drop counts in the field.
private let colorExtractionLogger = Logger(
    subsystem: "com.wardroberedo",
    category: "ColorExtraction"
)

struct ExtractedColor: Sendable {
    let hex: String
    let hue: Double
    let saturation: Double
    let lightness: Double
    let percentage: Double
    let colorFamily: String
    let isNeutral: Bool

    func toColorProfile() -> ColorProfile {
        ColorProfile(
            hex: hex,
            hue: hue,
            saturation: saturation,
            lightness: lightness,
            percentage: percentage,
            colorFamily: colorFamily,
            isNeutral: isNeutral
        )
    }
}

/// Injection seam for color extraction. Production uses
/// `ColorExtractionService`; tests inject deterministic stubs so palette
/// assertions don't depend on the real k-means classifier.
///
/// The default value for `maxColors` lives on the protocol so callers can
/// continue calling `extractColors(from:)` without specifying the second
/// argument — preserving the existing call-site ergonomics.
protocol ColorExtracting: Sendable {
    func extractColors(from image: UIImage, maxColors: Int) async -> [ExtractedColor]
}

extension ColorExtracting {
    func extractColors(from image: UIImage) async -> [ExtractedColor] {
        await extractColors(from: image, maxColors: 5)
    }
}

// MARK: - LabColor

/// CIELAB color in D65 reference white. Used for clustering + ΔE
/// distance. RGB / HSL are kept for output formatting only — k-means
/// in RGB is not perceptually uniform and produces "5 shades of blue"
/// for single-color garments with fabric texture.
struct LabColor: Sendable, Equatable {
    let L: Double  // 0 ... 100
    let a: Double  // ~ -128 ... 127
    let b: Double  // ~ -128 ... 127
}

final class ColorExtractionService: ColorExtracting, Sendable {

    // MARK: - Tunables (PR #26)

    /// Alpha threshold for accepting a sampled pixel as "interior".
    /// Vision's `VNGenerateForegroundInstanceMaskRequest` produces
    /// soft-edged masks; pixels at α 100-200 are the anti-aliased
    /// fringe and currently leak skin-tone fragments into the
    /// palette. 200 excludes that fringe ring.
    private static let alphaThreshold: UInt8 = 200

    /// ΔE76 (Euclidean in Lab) below which two cluster centroids are
    /// merged after k-means. 8.0 is "noticeable but same color name"
    /// territory — collapses denim folds + t-shirt wrinkle clusters
    /// while keeping red-vs-pink and navy-vs-royal-blue distinct.
    private static let deltaEMergeThreshold: Double = 8.0

    /// Drop clusters that occupy less than this percentage of sampled
    /// pixels. Removes 0% / 0.4% / 0.7% slivers that surface as "0%"
    /// in the UI after rounding.
    private static let minClusterPercentage: Double = 1.0

    /// Extract dominant colors from a UIImage using CIELAB k-means
    /// clustering on downsampled pixels with perceptual cluster
    /// merging (ΔE76), skin-tone suppression, and a min-percentage
    /// filter.
    ///
    /// When the image carries an alpha channel (e.g. the masked
    /// output of `ClothingExtractionService`), pixels with alpha
    /// below `alphaThreshold` are treated as background fringe and
    /// skipped. Regular JPEG input (no alpha or alpha = 255
    /// everywhere) flows through identically.
    func extractColors(from image: UIImage, maxColors: Int = 5) async -> [ExtractedColor] {
        guard let cgImage = image.cgImage else { return [] }

        // Downsample to 50x50 for performance, into a known RGBA8
        // premultiplied-last buffer so pixel offsets are predictable
        // regardless of the input image's native format.
        let sampleSize = 50
        guard let buffer = downsampleToRGBA(
            cgImage: cgImage,
            width: sampleSize,
            height: sampleSize
        ) else { return [] }

        let totalPixels = sampleSize * sampleSize
        var labPixels: [LabColor] = []
        labPixels.reserveCapacity(totalPixels)

        for i in 0..<totalPixels {
            let offset = i * 4
            let alphaByte = buffer[offset + 3]
            // PR #26: 200 (was 128). Soft-edge mask fringe at α 100-200
            // currently bleeds skin tones into the palette; raising the
            // gate excludes that ring.
            guard alphaByte >= Self.alphaThreshold else { continue }

            // Un-premultiply so clustering operates on the actual
            // clothing colors, not alpha-scaled versions.
            let alpha = Double(alphaByte) / 255.0
            let rp = Double(buffer[offset]) / 255.0
            let gp = Double(buffer[offset + 1]) / 255.0
            let bp = Double(buffer[offset + 2]) / 255.0
            let r = alpha > 0 ? min(rp / alpha, 1.0) : rp
            let g = alpha > 0 ? min(gp / alpha, 1.0) : gp
            let b = alpha > 0 ? min(bp / alpha, 1.0) : bp
            labPixels.append(srgbToLab(r: r, g: g, b: b))
        }

        // If the mask was so aggressive that no foreground pixels
        // remain, the color palette would be empty — surface that as
        // an empty result rather than crash. Callers already handle
        // zero-color results.
        let alphaRejected = totalPixels - labPixels.count
        guard !labPixels.isEmpty else {
            colorExtractionLogger.notice(
                "extractColors.empty totalPixels=\(totalPixels, privacy: .public) alphaRejected=\(alphaRejected, privacy: .public)"
            )
            return []
        }

        // K-means clustering in CIELAB (perceptually uniform — fixes
        // the "shadow region clusters as #1 dominant" bug and the
        // "5 nearly-identical shades" fragmentation).
        let rawClusters = kMeansLab(pixels: labPixels, k: maxColors, maxIterations: 20)

        // Phase 3: merge perceptually-close clusters.
        let merged = mergeSimilarClusters(rawClusters, threshold: Self.deltaEMergeThreshold)

        // Phase 4: drop skin-tone clusters (face / hand pixels that
        // bled through despite alpha=200, e.g. inside-of-sunglasses
        // case).
        let skinDropped = merged.count - merged.filter { !isSkinTone($0.center) }.count
        let nonSkin = merged.filter { !isSkinTone($0.center) }

        // If skin filtering removed everything (e.g. an actually
        // skin-toned garment), fall back to the merged set so we
        // don't return zero colors.
        let postSkin: [LabCluster] = nonSkin.isEmpty ? merged : nonSkin

        // Sort by coverage (largest first), filter min-%, keep at
        // least the top cluster regardless of percentage so a
        // uniform garment still reports a palette.
        let sortedAll = postSkin.sorted { $0.count > $1.count }
        let sampledCount = labPixels.count
        let filtered: [LabCluster]
        if sortedAll.isEmpty {
            filtered = []
        } else {
            let above = sortedAll.filter { cluster in
                let pct = (Double(cluster.count) / Double(sampledCount)) * 100.0
                return pct >= Self.minClusterPercentage
            }
            filtered = above.isEmpty ? [sortedAll[0]] : above
        }

        // Per-extraction telemetry — surfaces merge / skin / filter
        // counts so build-5 dogfood can verify the overhaul reaches
        // the field correctly.
        let droppedByMinPercent = sortedAll.count - filtered.count
        colorExtractionLogger.info(
            "extractColors.success totalPixels=\(totalPixels, privacy: .public) sampledPixels=\(sampledCount, privacy: .public) alphaRejected=\(alphaRejected, privacy: .public) rawClusters=\(rawClusters.count, privacy: .public) afterMerge=\(merged.count, privacy: .public) skinDropped=\(skinDropped, privacy: .public) afterSkin=\(postSkin.count, privacy: .public) returned=\(filtered.count, privacy: .public) maxColors=\(maxColors, privacy: .public) droppedByMinPercent=\(droppedByMinPercent, privacy: .public)"
        )

        return filtered.map { cluster in
            let rgb = labToSrgb(cluster.center)
            let (h, s, l) = rgbToHSL(r: rgb.r, g: rgb.g, b: rgb.b)
            let hex = rgbToHex(r: rgb.r, g: rgb.g, b: rgb.b)
            let percentage = (Double(cluster.count) / Double(sampledCount)) * 100.0
            let family = colorFamily(hue: h, saturation: s, lightness: l)
            let neutral = isNeutral(saturation: s, lightness: l)

            return ExtractedColor(
                hex: hex,
                hue: h,
                saturation: s,
                lightness: l,
                percentage: percentage.rounded(to: 1),
                colorFamily: family,
                isNeutral: neutral
            )
        }
    }

    // MARK: - Pixel Downsampling

    /// Draw `cgImage` into a fresh RGBA8 premultiplied-last bitmap at
    /// the requested size and return the raw byte buffer. Returns nil
    /// if the CGContext couldn't be created. Result length is always
    /// `width * height * 4` bytes.
    private func downsampleToRGBA(
        cgImage: CGImage,
        width: Int,
        height: Int
    ) -> [UInt8]? {
        let bytesPerRow = width * 4
        var pixelData = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        let context = pixelData.withUnsafeMutableBytes { buffer -> CGContext? in
            guard let base = buffer.baseAddress else { return nil }
            return CGContext(
                data: base,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: bitmapInfo
            )
        }
        guard let context else { return nil }
        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixelData
    }

    // MARK: - K-Means (CIELAB)

    /// Cluster-internal struct exposed at module-internal scope so
    /// the test target's `@testable import` can drive the merge and
    /// skin-tone helpers without going through a full UIImage round-trip.
    struct LabCluster: Sendable, Equatable {
        var center: LabColor
        var count: Int
    }

    private func kMeansLab(
        pixels: [LabColor],
        k: Int,
        maxIterations: Int
    ) -> [LabCluster] {
        guard !pixels.isEmpty, k > 0 else { return [] }

        let actualK = min(k, pixels.count)

        // K-means++ initialization in Lab space.
        var centers = kMeansPlusPlusInitLab(pixels: pixels, k: actualK)

        for _ in 0..<maxIterations {
            // Assignment step (Euclidean Lab — already perceptually
            // uniform; ΔE76 is just sqrt of this).
            var assignments = Array(repeating: 0, count: pixels.count)
            for (i, pixel) in pixels.enumerated() {
                var minDist = Double.infinity
                for (j, center) in centers.enumerated() {
                    let dist = labSquaredDistance(pixel, center)
                    if dist < minDist {
                        minDist = dist
                        assignments[i] = j
                    }
                }
            }

            // Update step.
            var sumL = Array(repeating: 0.0, count: actualK)
            var sumA = Array(repeating: 0.0, count: actualK)
            var sumB = Array(repeating: 0.0, count: actualK)
            var counts = Array(repeating: 0, count: actualK)

            for (i, pixel) in pixels.enumerated() {
                let cluster = assignments[i]
                sumL[cluster] += pixel.L
                sumA[cluster] += pixel.a
                sumB[cluster] += pixel.b
                counts[cluster] += 1
            }

            var converged = true
            for j in 0..<actualK {
                if counts[j] > 0 {
                    let newCenter = LabColor(
                        L: sumL[j] / Double(counts[j]),
                        a: sumA[j] / Double(counts[j]),
                        b: sumB[j] / Double(counts[j])
                    )
                    if labSquaredDistance(centers[j], newCenter) > 0.001 {
                        converged = false
                    }
                    centers[j] = newCenter
                }
            }

            if converged { break }
        }

        // Final assignment to get counts.
        var finalCounts = Array(repeating: 0, count: actualK)
        for pixel in pixels {
            var minDist = Double.infinity
            var closest = 0
            for (j, center) in centers.enumerated() {
                let dist = labSquaredDistance(pixel, center)
                if dist < minDist {
                    minDist = dist
                    closest = j
                }
            }
            finalCounts[closest] += 1
        }

        return zip(centers, finalCounts).compactMap { center, count in
            // Drop empty clusters (k-means++ can leave one if k > unique pixels).
            count > 0 ? LabCluster(center: center, count: count) : nil
        }
    }

    private func kMeansPlusPlusInitLab(
        pixels: [LabColor],
        k: Int
    ) -> [LabColor] {
        var centers: [LabColor] = []

        // First center: random pixel.
        centers.append(pixels[Int.random(in: 0..<pixels.count)])

        for _ in 1..<k {
            // Weight by squared distance to nearest center.
            let distances = pixels.map { pixel in
                centers.map { labSquaredDistance(pixel, $0) }.min() ?? 0
            }
            let total = distances.reduce(0, +)
            if total == 0 { break }

            // Weighted random selection.
            let threshold = Double.random(in: 0..<total)
            var cumulative = 0.0
            for (i, d) in distances.enumerated() {
                cumulative += d
                if cumulative >= threshold {
                    centers.append(pixels[i])
                    break
                }
            }
        }

        return centers
    }

    // MARK: - Cluster Merging (ΔE76)

    /// Merge clusters whose centroids are within `threshold` ΔE76 of
    /// each other, weighted by population. Repeats until no pair is
    /// below threshold. ΔE76 is plain Euclidean in Lab — already
    /// perceptually-uniform-ish, and at the merge step (≤5 centroids)
    /// there's no reason to pull in the heavier CIEDE2000 cross-terms.
    func mergeSimilarClusters(
        _ clusters: [LabCluster],
        threshold: Double = 8.0
    ) -> [LabCluster] {
        var merged = clusters
        var changed = true
        while changed {
            changed = false
            outer: for i in 0..<merged.count {
                for j in (i + 1)..<merged.count {
                    if deltaE76(merged[i].center, merged[j].center) <= threshold {
                        let totalCount = merged[i].count + merged[j].count
                        let wi = Double(merged[i].count) / Double(totalCount)
                        let wj = Double(merged[j].count) / Double(totalCount)
                        let newCenter = LabColor(
                            L: merged[i].center.L * wi + merged[j].center.L * wj,
                            a: merged[i].center.a * wi + merged[j].center.a * wj,
                            b: merged[i].center.b * wi + merged[j].center.b * wj
                        )
                        merged[i] = LabCluster(center: newCenter, count: totalCount)
                        merged.remove(at: j)
                        changed = true
                        break outer
                    }
                }
            }
        }
        return merged
    }

    // MARK: - Skin-tone Exclusion

    /// Conservative skin-gamut filter in CIELAB. Build-5 dogfood
    /// confirmed face-skin pixels around sunglasses leaking into
    /// item palettes — those pixels land squarely in this band
    /// (warm/light Caucasian to medium tan).
    ///
    /// Trade-off: a clothing item that happens to be skin-toned
    /// (e.g. a peach top) will lose that color from the palette.
    /// Acceptable — those items still get a palette from non-skin
    /// clusters via the empty-after-skin fallback in `extractColors`.
    /// Cooler / darker / very-pale skin tones are not covered by
    /// this band; the trade-off is documented but a wider gamut
    /// would catch more legitimate clothing colors.
    func isSkinTone(_ lab: LabColor) -> Bool {
        return lab.L >= 40 && lab.L <= 85 &&
               lab.a >= 10 && lab.a <= 25 &&
               lab.b >= 10 && lab.b <= 30
    }

    // MARK: - Color Math (RGB / HSL — for output)

    func colorDistance(
        _ a: (r: Double, g: Double, b: Double),
        _ b: (r: Double, g: Double, b: Double)
    ) -> Double {
        let dr = a.r - b.r
        let dg = a.g - b.g
        let db = a.b - b.b
        return dr * dr + dg * dg + db * db
    }

    func rgbToHSL(r: Double, g: Double, b: Double) -> (h: Double, s: Double, l: Double) {
        let maxC = max(r, g, b)
        let minC = min(r, g, b)
        let l = (maxC + minC) / 2.0

        guard maxC != minC else {
            return (h: 0, s: 0, l: l)
        }

        let d = maxC - minC
        let s = l > 0.5 ? d / (2.0 - maxC - minC) : d / (maxC + minC)

        var h: Double
        if maxC == r {
            h = (g - b) / d + (g < b ? 6 : 0)
        } else if maxC == g {
            h = (b - r) / d + 2
        } else {
            h = (r - g) / d + 4
        }
        h *= 60

        return (h: h, s: s, l: l)
    }

    func rgbToHex(r: Double, g: Double, b: Double) -> String {
        let ri = Int((r * 255).rounded())
        let gi = Int((g * 255).rounded())
        let bi = Int((b * 255).rounded())
        return String(format: "#%02X%02X%02X", ri, gi, bi)
    }

    func colorFamily(hue: Double, saturation: Double, lightness: Double) -> String {
        // Achromatic check
        if saturation < 0.1 {
            if lightness < 0.15 { return "black" }
            if lightness > 0.85 { return "white" }
            return "gray"
        }

        if lightness < 0.12 { return "black" }
        if lightness > 0.9 { return "white" }

        // Low saturation warm tones
        if saturation < 0.25 && lightness > 0.6 {
            if hue >= 20 && hue <= 50 { return "cream" }
            if hue >= 10 && hue <= 30 { return "beige" }
        }

        // Hue-based families
        switch hue {
        case 0..<15, 345...360: return "red"
        case 15..<35: return "orange"
        case 35..<55: return "yellow"
        case 55..<75: return "olive"
        case 75..<150: return "green"
        case 150..<190: return "teal"
        case 190..<250:
            if lightness < 0.3 { return "navy" }
            return "blue"
        case 250..<290: return "purple"
        case 290..<345: return "pink"
        default: return "unknown"
        }
    }

    func isNeutral(saturation: Double, lightness: Double) -> Bool {
        saturation < 0.15 || lightness < 0.12 || lightness > 0.88
    }

    // MARK: - sRGB <-> CIELAB

    /// Convert sRGB (each channel 0...1, gamma-encoded) to CIELAB
    /// using the D65 reference white (sRGB-aligned). Matches the
    /// reference pipeline in `F-color-extraction-soa.md`.
    func srgbToLab(r: Double, g: Double, b: Double) -> LabColor {
        // 1. sRGB → linear RGB (gamma decode).
        func linearize(_ c: Double) -> Double {
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let lr = linearize(r), lg = linearize(g), lb = linearize(b)

        // 2. Linear RGB → XYZ (D65, sRGB primaries). Output in 0...100.
        let x = (lr * 0.4124564 + lg * 0.3575761 + lb * 0.1804375) * 100.0
        let y = (lr * 0.2126729 + lg * 0.7151522 + lb * 0.0721750) * 100.0
        let z = (lr * 0.0193339 + lg * 0.1191920 + lb * 0.9503041) * 100.0

        // 3. XYZ → Lab (D65 white-point normalization + piecewise
        //    nonlinearity). Constants per CIE 1976.
        func f(_ t: Double) -> Double {
            return t > 0.008856 ? pow(t, 1.0 / 3.0) : (7.787 * t) + (16.0 / 116.0)
        }
        let xn = 95.047, yn = 100.000, zn = 108.883
        let fx = f(x / xn), fy = f(y / yn), fz = f(z / zn)
        return LabColor(
            L: (116.0 * fy) - 16.0,
            a: 500.0 * (fx - fy),
            b: 200.0 * (fy - fz)
        )
    }

    /// Inverse of `srgbToLab`. Lab → XYZ (D65) → linear RGB → sRGB
    /// gamma encode. Output channels are clamped to 0...1; any
    /// out-of-gamut centroid (rare for cluster centroids of real
    /// clothing pixels) is silently clipped rather than producing
    /// negative RGB values that downstream `rgbToHex` would mangle.
    func labToSrgb(_ lab: LabColor) -> (r: Double, g: Double, b: Double) {
        // 1. Lab → XYZ.
        let fy = (lab.L + 16.0) / 116.0
        let fx = lab.a / 500.0 + fy
        let fz = fy - lab.b / 200.0

        func fInverse(_ t: Double) -> Double {
            let t3 = t * t * t
            return t3 > 0.008856 ? t3 : (t - 16.0 / 116.0) / 7.787
        }
        let xn = 95.047, yn = 100.000, zn = 108.883
        let x = fInverse(fx) * xn / 100.0
        let y = fInverse(fy) * yn / 100.0
        let z = fInverse(fz) * zn / 100.0

        // 2. XYZ → linear RGB (sRGB primaries, D65). Inverse matrix.
        let lr =  x * 3.2404542 + y * -1.5371385 + z * -0.4985314
        let lg =  x * -0.9692660 + y * 1.8760108 + z * 0.0415560
        let lb =  x * 0.0556434 + y * -0.2040259 + z * 1.0572252

        // 3. Linear RGB → sRGB (gamma encode). Clamp to 0...1; an
        //    out-of-gamut Lab centroid (rare for real cluster
        //    centroids) gets clipped rather than producing negative
        //    or super-bright RGB.
        func encode(_ c: Double) -> Double {
            let clamped = min(max(c, 0.0), 1.0)
            return clamped <= 0.0031308
                ? 12.92 * clamped
                : 1.055 * pow(clamped, 1.0 / 2.4) - 0.055
        }
        return (
            r: min(max(encode(lr), 0.0), 1.0),
            g: min(max(encode(lg), 0.0), 1.0),
            b: min(max(encode(lb), 0.0), 1.0)
        )
    }

    /// CIE76 ΔE — plain Euclidean distance in CIELAB. Used for
    /// cluster merging. Already perceptually-uniform-ish; the more
    /// elaborate CIEDE2000 cross-terms aren't needed at the merge
    /// stage (≤5 centroids) and would break k-means convergence
    /// guarantees if used inside the assignment loop.
    func deltaE76(_ a: LabColor, _ b: LabColor) -> Double {
        let dL = a.L - b.L
        let da = a.a - b.a
        let db = a.b - b.b
        return sqrt(dL * dL + da * da + db * db)
    }

    /// Squared-Lab distance for the inner k-means assignment loop.
    /// Square-rooting per pixel × 5 centroids × 20 iterations is
    /// gratuitous; compare squared distances and only sqrt at the
    /// merge step.
    private func labSquaredDistance(_ a: LabColor, _ b: LabColor) -> Double {
        let dL = a.L - b.L
        let da = a.a - b.a
        let db = a.b - b.b
        return dL * dL + da * da + db * db
    }
}

private extension Double {
    func rounded(to places: Int) -> Double {
        let multiplier = pow(10, Double(places))
        return (self * multiplier).rounded() / multiplier
    }
}
