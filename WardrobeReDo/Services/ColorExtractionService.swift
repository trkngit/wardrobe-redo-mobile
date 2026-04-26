import CoreImage
import UIKit

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

final class ColorExtractionService: ColorExtracting, Sendable {

    /// Extract dominant colors from a UIImage using k-means clustering
    /// on downsampled pixels.
    ///
    /// When the image carries an alpha channel (e.g. the masked output
    /// of `ClothingExtractionService`), pixels with alpha < 128 are
    /// treated as background and skipped — the palette is sampled only
    /// from the clothing region. Regular JPEG input (no alpha or alpha
    /// = 255 everywhere) behaves identically to the pre-Phase-1 version.
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
        var pixels: [(r: Double, g: Double, b: Double)] = []
        pixels.reserveCapacity(totalPixels)

        for i in 0..<totalPixels {
            let offset = i * 4
            let alphaByte = buffer[offset + 3]
            // Alpha < 128 = masked-out background pixel. Skip so the
            // k-means palette doesn't include transparent-black noise.
            guard alphaByte >= 128 else { continue }

            // Un-premultiply so clustering operates on the actual
            // clothing colors, not alpha-scaled versions.
            let alpha = Double(alphaByte) / 255.0
            let rp = Double(buffer[offset]) / 255.0
            let gp = Double(buffer[offset + 1]) / 255.0
            let bp = Double(buffer[offset + 2]) / 255.0
            let r = alpha > 0 ? min(rp / alpha, 1.0) : rp
            let g = alpha > 0 ? min(gp / alpha, 1.0) : gp
            let b = alpha > 0 ? min(bp / alpha, 1.0) : bp
            pixels.append((r, g, b))
        }

        // If the mask was so aggressive that no foreground pixels
        // remain, the color palette would be empty — surface that as
        // an empty result rather than crash. Callers already handle
        // zero-color results.
        guard !pixels.isEmpty else { return [] }

        // K-means clustering
        let clusters = kMeans(pixels: pixels, k: maxColors, maxIterations: 20)

        // Sort by coverage (largest cluster first)
        let sorted = clusters.sorted { $0.count > $1.count }
        let sampledCount = pixels.count

        return sorted.map { cluster in
            let (h, s, l) = rgbToHSL(r: cluster.center.r, g: cluster.center.g, b: cluster.center.b)
            let hex = rgbToHex(r: cluster.center.r, g: cluster.center.g, b: cluster.center.b)
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

    // MARK: - K-Means

    private struct Cluster {
        var center: (r: Double, g: Double, b: Double)
        var count: Int
    }

    private func kMeans(
        pixels: [(r: Double, g: Double, b: Double)],
        k: Int,
        maxIterations: Int
    ) -> [Cluster] {
        guard !pixels.isEmpty, k > 0 else { return [] }

        let actualK = min(k, pixels.count)

        // K-means++ initialization
        var centers = kMeansPlusPlusInit(pixels: pixels, k: actualK)

        for _ in 0..<maxIterations {
            // Assignment step
            var assignments = Array(repeating: 0, count: pixels.count)
            for (i, pixel) in pixels.enumerated() {
                var minDist = Double.infinity
                for (j, center) in centers.enumerated() {
                    let dist = colorDistance(pixel, center)
                    if dist < minDist {
                        minDist = dist
                        assignments[i] = j
                    }
                }
            }

            // Update step
            var newCenters = Array(repeating: (r: 0.0, g: 0.0, b: 0.0), count: actualK)
            var counts = Array(repeating: 0, count: actualK)

            for (i, pixel) in pixels.enumerated() {
                let cluster = assignments[i]
                newCenters[cluster].r += pixel.r
                newCenters[cluster].g += pixel.g
                newCenters[cluster].b += pixel.b
                counts[cluster] += 1
            }

            var converged = true
            for j in 0..<actualK {
                if counts[j] > 0 {
                    let newCenter = (
                        r: newCenters[j].r / Double(counts[j]),
                        g: newCenters[j].g / Double(counts[j]),
                        b: newCenters[j].b / Double(counts[j])
                    )
                    if colorDistance(centers[j], newCenter) > 0.001 {
                        converged = false
                    }
                    centers[j] = newCenter
                }
            }

            if converged { break }
        }

        // Final assignment to get counts
        var finalCounts = Array(repeating: 0, count: actualK)
        for pixel in pixels {
            var minDist = Double.infinity
            var closest = 0
            for (j, center) in centers.enumerated() {
                let dist = colorDistance(pixel, center)
                if dist < minDist {
                    minDist = dist
                    closest = j
                }
            }
            finalCounts[closest] += 1
        }

        return zip(centers, finalCounts).map { Cluster(center: $0, count: $1) }
    }

    private func kMeansPlusPlusInit(
        pixels: [(r: Double, g: Double, b: Double)],
        k: Int
    ) -> [(r: Double, g: Double, b: Double)] {
        var centers: [(r: Double, g: Double, b: Double)] = []

        // First center: random pixel
        centers.append(pixels[Int.random(in: 0..<pixels.count)])

        for _ in 1..<k {
            // Weight by squared distance to nearest center
            let distances = pixels.map { pixel in
                centers.map { colorDistance(pixel, $0) }.min() ?? 0
            }
            let total = distances.reduce(0, +)
            if total == 0 { break }

            // Weighted random selection
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

    // MARK: - Color Math

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
}

private extension Double {
    func rounded(to places: Int) -> Double {
        let multiplier = pow(10, Double(places))
        return (self * multiplier).rounded() / multiplier
    }
}
