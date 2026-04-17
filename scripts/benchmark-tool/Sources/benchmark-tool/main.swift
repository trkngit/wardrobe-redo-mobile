import AppKit
import CoreImage
import CoreVideo
import Foundation
import Vision

// MARK: - Wardrobe Re-Do Benchmark Harness (macOS, Vision-only)
//
// Reads the DeepFashion2 benchmark manifest built by `build_benchmark.py`,
// runs each image through `VNGenerateForegroundInstanceMaskRequest`, and
// emits a JSON report (IoU per image, latency, category breakdown) to
// `~/wardrobe-benchmark/reports/<UTC>-<commit>.json`.
//
// This tool is Vision-only by design. SAM2 needs iOS Neural Engine
// inference, which you get from `ExtractionPerformanceTests` on device.
// For on-the-Mac dev-loop iteration, Vision IoU is a proxy for the floor
// of what production extraction delivers on the same photos.
//
// Usage (from the repo root):
//   swift run --package-path scripts/benchmark-tool benchmark-tool
//
// Exit codes:
//   0  report written
//   1  manifest missing — run build_benchmark.py first
//   2  I/O or inference error

// MARK: - Manifest

struct BenchmarkManifest: Decodable {
    let version: Int
    let seed: String
    let count: Int
    let entries: [BenchmarkEntry]
}

struct BenchmarkEntry: Decodable {
    let image: String
    let annotation: String?
    let categories: [String]
}

struct BenchmarkResult: Encodable {
    let image: String
    let categories: [String]
    let instanceCount: Int
    let coverageRatio: Double
    let latencySeconds: Double
    /// IoU against the annotation-derived mask, if we could build one from
    /// DeepFashion2's segmentation polygons. Null when the annotation was
    /// missing or malformed.
    let iou: Double?
}

struct BenchmarkReport: Encodable {
    let generatedAt: String
    let commit: String?
    let platform: String
    let version: Int
    let entryCount: Int
    let meanIoU: Double?
    let meanLatencySeconds: Double
    let perCategory: [String: CategorySummary]
    let results: [BenchmarkResult]
}

struct CategorySummary: Encodable {
    let count: Int
    let meanIoU: Double?
}

// MARK: - Main

let homeURL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
let benchmarkRoot = homeURL.appendingPathComponent("wardrobe-benchmark", isDirectory: true)
let manifestURL = benchmarkRoot.appendingPathComponent("benchmark_manifest.json")
let reportsDir = benchmarkRoot.appendingPathComponent("reports", isDirectory: true)

guard let manifestData = try? Data(contentsOf: manifestURL),
      let manifest = try? JSONDecoder().decode(BenchmarkManifest.self, from: manifestData) else {
    FileHandle.standardError.write(Data(
        "Manifest not found at \(manifestURL.path). Run: python3 scripts/build_benchmark.py\n".utf8
    ))
    exit(1)
}

try? FileManager.default.createDirectory(at: reportsDir, withIntermediateDirectories: true)

var results: [BenchmarkResult] = []
results.reserveCapacity(manifest.entries.count)

for (index, entry) in manifest.entries.enumerated() {
    let imageURL = benchmarkRoot.appendingPathComponent(entry.image)
    guard let predicted = runVision(on: imageURL) else {
        continue
    }
    let iou = iouAgainstAnnotation(entry: entry, benchmarkRoot: benchmarkRoot, predicted: predicted.mask)

    results.append(BenchmarkResult(
        image: entry.image,
        categories: entry.categories,
        instanceCount: predicted.instanceCount,
        coverageRatio: predicted.coverageRatio,
        latencySeconds: predicted.latencySeconds,
        iou: iou
    ))

    if (index + 1) % 25 == 0 {
        FileHandle.standardError.write(Data("  processed \(index + 1)/\(manifest.entries.count)\n".utf8))
    }
}

let report = BenchmarkReport(
    generatedAt: ISO8601DateFormatter().string(from: Date()),
    commit: readCommit(),
    platform: "macOS Vision-only",
    version: 1,
    entryCount: results.count,
    meanIoU: mean(results.compactMap(\.iou)),
    meanLatencySeconds: mean(results.map(\.latencySeconds)) ?? 0,
    perCategory: categoryBreakdown(results),
    results: results
)

let filename = "\(filenameTimestamp())-\(report.commit ?? "nocommit").json"
let reportURL = reportsDir.appendingPathComponent(filename)
do {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(report)
    try data.write(to: reportURL)
    print("Wrote \(reportURL.path)")
} catch {
    FileHandle.standardError.write(Data("Failed to write report: \(error)\n".utf8))
    exit(2)
}

// MARK: - Vision extraction

struct VisionPrediction {
    let mask: CVPixelBuffer
    let instanceCount: Int
    let coverageRatio: Double
    let latencySeconds: Double
}

func runVision(on imageURL: URL) -> VisionPrediction? {
    guard let nsImage = NSImage(contentsOf: imageURL),
          let cgImage = cgImage(from: nsImage) else {
        return nil
    }
    let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
    let request = VNGenerateForegroundInstanceMaskRequest()
    let start = Date()
    do {
        try handler.perform([request])
    } catch {
        return nil
    }
    let latency = Date().timeIntervalSince(start)
    guard let observation = request.results?.first else { return nil }
    do {
        let maskedPixelBuffer = try observation.generateMaskedImage(
            ofInstances: observation.allInstances,
            from: handler,
            croppedToInstancesExtent: false
        )
        let (coverage, maskBuffer) = coverage(from: maskedPixelBuffer)
        return VisionPrediction(
            mask: maskBuffer ?? maskedPixelBuffer,
            instanceCount: observation.allInstances.count,
            coverageRatio: coverage,
            latencySeconds: latency
        )
    } catch {
        return nil
    }
}

func cgImage(from nsImage: NSImage) -> CGImage? {
    var rect = CGRect(origin: .zero, size: nsImage.size)
    return nsImage.cgImage(forProposedRect: &rect, context: nil, hints: nil)
}

/// Extracts the alpha plane of a Vision-produced masked image back into a
/// grayscale pixel buffer we can feed to the IoU math. Also returns the
/// coverage ratio (fraction of pixels above threshold) so we can log it.
func coverage(from pixelBuffer: CVPixelBuffer) -> (Double, CVPixelBuffer?) {
    let width = CVPixelBufferGetWidth(pixelBuffer)
    let height = CVPixelBufferGetHeight(pixelBuffer)
    guard width > 0, height > 0 else { return (0, nil) }

    var out: CVPixelBuffer?
    let status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        width,
        height,
        kCVPixelFormatType_OneComponent8,
        nil,
        &out
    )
    guard status == kCVReturnSuccess, let outBuffer = out else { return (0, nil) }

    CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
    CVPixelBufferLockBaseAddress(outBuffer, [])
    defer {
        CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
        CVPixelBufferUnlockBaseAddress(outBuffer, [])
    }

    guard let srcBase = CVPixelBufferGetBaseAddress(pixelBuffer),
          let dstBase = CVPixelBufferGetBaseAddress(outBuffer) else {
        return (0, nil)
    }
    let srcBytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
    let dstBytesPerRow = CVPixelBufferGetBytesPerRow(outBuffer)
    let dst = dstBase.assumingMemoryBound(to: UInt8.self)

    let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
    var on = 0
    let total = width * height

    switch pixelFormat {
    case kCVPixelFormatType_32BGRA, kCVPixelFormatType_32ARGB, kCVPixelFormatType_32RGBA:
        let src = srcBase.assumingMemoryBound(to: UInt8.self)
        let alphaOffset: Int = (pixelFormat == kCVPixelFormatType_32ARGB) ? 0 : 3
        for y in 0..<height {
            for x in 0..<width {
                let pixel = src[y * srcBytesPerRow + x * 4 + alphaOffset]
                let flag: UInt8 = pixel > 127 ? 255 : 0
                dst[y * dstBytesPerRow + x] = flag
                if flag == 255 { on += 1 }
            }
        }
    case kCVPixelFormatType_OneComponent8:
        let src = srcBase.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width {
                let pixel = src[y * srcBytesPerRow + x]
                let flag: UInt8 = pixel > 127 ? 255 : 0
                dst[y * dstBytesPerRow + x] = flag
                if flag == 255 { on += 1 }
            }
        }
    default:
        return (0, nil)
    }
    return (Double(on) / Double(total), outBuffer)
}

// MARK: - IoU (against DeepFashion2 polygon annotations)

func iouAgainstAnnotation(entry: BenchmarkEntry, benchmarkRoot: URL, predicted: CVPixelBuffer) -> Double? {
    guard let annotationRel = entry.annotation else { return nil }
    let annotationURL = benchmarkRoot.appendingPathComponent(annotationRel)
    guard let data = try? Data(contentsOf: annotationURL),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return nil
    }

    let width = CVPixelBufferGetWidth(predicted)
    let height = CVPixelBufferGetHeight(predicted)
    guard let gt = rasterizeAnnotation(root, width: width, height: height) else { return nil }

    return iou(predicted, gt)
}

/// DeepFashion2 annotations encode segmentation as `item*.segmentation`,
/// which is an array-of-arrays of [x, y] polygon vertices in pixel units.
/// We rasterize every polygon for every item into a combined binary mask.
func rasterizeAnnotation(_ root: [String: Any], width: Int, height: Int) -> CVPixelBuffer? {
    var output: CVPixelBuffer?
    let status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        width,
        height,
        kCVPixelFormatType_OneComponent8,
        nil,
        &output
    )
    guard status == kCVReturnSuccess, let buffer = output else { return nil }

    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
    let dst = base.assumingMemoryBound(to: UInt8.self)
    let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
    memset(base, 0, bytesPerRow * height)

    for (key, value) in root where key.hasPrefix("item") {
        guard let item = value as? [String: Any],
              let polygons = item["segmentation"] as? [[Double]] else { continue }
        for polygon in polygons {
            rasterize(polygon: polygon, into: dst, width: width, height: height, bytesPerRow: bytesPerRow)
        }
    }
    return buffer
}

/// Flat [x0, y0, x1, y1, …] polygon. Scanline rasterizer, good enough for
/// test-time IoU (we don't need SIMD or antialiasing).
func rasterize(polygon: [Double], into buffer: UnsafeMutablePointer<UInt8>, width: Int, height: Int, bytesPerRow: Int) {
    guard polygon.count >= 6, polygon.count.isMultiple(of: 2) else { return }
    let pointCount = polygon.count / 2
    var xs = [Double](repeating: 0, count: pointCount)
    var ys = [Double](repeating: 0, count: pointCount)
    for i in 0..<pointCount {
        xs[i] = polygon[i * 2]
        ys[i] = polygon[i * 2 + 1]
    }

    let minY = max(0, Int(ys.min() ?? 0))
    let maxY = min(height - 1, Int(ys.max() ?? 0))

    for y in minY...maxY {
        var crossings: [Double] = []
        for i in 0..<pointCount {
            let j = (i + 1) % pointCount
            let yi = ys[i]
            let yj = ys[j]
            let xi = xs[i]
            let xj = xs[j]
            let yd = Double(y) + 0.5
            if (yi <= yd && yj > yd) || (yj <= yd && yi > yd) {
                let t = (yd - yi) / (yj - yi)
                crossings.append(xi + t * (xj - xi))
            }
        }
        crossings.sort()
        var i = 0
        while i + 1 < crossings.count {
            let start = max(0, Int(crossings[i]))
            let end = min(width - 1, Int(crossings[i + 1]))
            if end >= start {
                for x in start...end {
                    buffer[y * bytesPerRow + x] = 255
                }
            }
            i += 2
        }
    }
}

func iou(_ a: CVPixelBuffer, _ b: CVPixelBuffer) -> Double {
    let width = CVPixelBufferGetWidth(a)
    let height = CVPixelBufferGetHeight(a)
    guard width == CVPixelBufferGetWidth(b), height == CVPixelBufferGetHeight(b) else { return 0 }

    CVPixelBufferLockBaseAddress(a, .readOnly)
    CVPixelBufferLockBaseAddress(b, .readOnly)
    defer {
        CVPixelBufferUnlockBaseAddress(a, .readOnly)
        CVPixelBufferUnlockBaseAddress(b, .readOnly)
    }
    guard let aBase = CVPixelBufferGetBaseAddress(a),
          let bBase = CVPixelBufferGetBaseAddress(b) else { return 0 }
    let aRow = CVPixelBufferGetBytesPerRow(a)
    let bRow = CVPixelBufferGetBytesPerRow(b)
    let aPtr = aBase.assumingMemoryBound(to: UInt8.self)
    let bPtr = bBase.assumingMemoryBound(to: UInt8.self)

    var intersection = 0
    var union = 0
    for y in 0..<height {
        for x in 0..<width {
            let ax = aPtr[y * aRow + x] > 127
            let bx = bPtr[y * bRow + x] > 127
            if ax && bx { intersection += 1 }
            if ax || bx { union += 1 }
        }
    }
    guard union > 0 else { return 0 }
    return Double(intersection) / Double(union)
}

// MARK: - Reporting utilities

func mean(_ values: [Double]) -> Double? {
    guard !values.isEmpty else { return nil }
    return values.reduce(0, +) / Double(values.count)
}

func categoryBreakdown(_ results: [BenchmarkResult]) -> [String: CategorySummary] {
    var buckets: [String: [Double?]] = [:]
    for r in results {
        for c in r.categories {
            buckets[c, default: []].append(r.iou)
        }
    }
    var out: [String: CategorySummary] = [:]
    for (category, ious) in buckets {
        let filtered = ious.compactMap { $0 }
        out[category] = CategorySummary(count: ious.count, meanIoU: mean(filtered))
    }
    return out
}

func readCommit() -> String? {
    let task = Process()
    task.launchPath = "/usr/bin/env"
    task.arguments = ["git", "rev-parse", "--short", "HEAD"]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = Pipe()
    do {
        try task.run()
        task.waitUntilExit()
    } catch {
        return nil
    }
    guard task.terminationStatus == 0 else { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
}

func filenameTimestamp() -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    return formatter.string(from: Date())
}
