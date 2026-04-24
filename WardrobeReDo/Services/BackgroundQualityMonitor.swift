import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Observation

/// Steady-state classification of the live camera preview's background.
/// Drives the capture HUD (`CameraOverlay`) traffic light and coaching
/// copy. `.unknown` is the pre-first-sample state so the UI can show a
/// neutral placeholder.
enum BackgroundQuality: String, Sendable, Equatable {
    case unknown
    case good
    case tooDark
    case tooBright
    case tooBusy
    case tooTextured
}

extension BackgroundQuality {
    /// One-line coaching text rendered under the traffic-light dot.
    var coachingText: String {
        switch self {
        case .unknown:     return "Framing up…"
        case .good:        return "Looks great — hold still"
        case .tooDark:     return "Too dark — add light"
        case .tooBright:   return "Too bright — turn away from light"
        case .tooBusy:     return "Too busy — try a plainer background"
        case .tooTextured: return "Textured background — try a flat wall or sheet"
        }
    }

    /// Traffic-light color family. Consumer maps this to a concrete
    /// `Theme.Colors.*` value — we keep this file UI-framework-agnostic.
    var semanticColor: SemanticColor {
        switch self {
        case .unknown: return .neutral
        case .good:    return .positive
        default:       return .warning
        }
    }

    enum SemanticColor: Sendable, Equatable {
        case neutral
        case positive
        case warning
    }
}

/// Raw metrics sampled from a single frame, before classification.
/// Separating metrics from classification lets unit tests exercise the
/// thresholds without needing a live capture session.
struct BackgroundQualityMetrics: Sendable, Equatable {
    /// Mean luminance across the 4 corner patches, in [0, 1].
    let meanLuminance: Double
    /// Maximum per-patch standard deviation of luminance, in [0, 1].
    /// High stddev means the "clean" background isn't clean — gradients,
    /// fiber texture, patterns.
    let maxStddev: Double
    /// Maximum per-patch edge density, in [0, 1]. Measured as the
    /// fraction of pixels where the simple 4-neighbor gradient
    /// magnitude exceeds a fixed threshold.
    let maxEdgeDensity: Double
}

/// Thresholds for mapping metrics → quality bucket. Defaults are tuned
/// from the 30-photo fixture set; exposing them here keeps the door open
/// for per-lighting-condition overrides later.
struct BackgroundQualityThresholds: Sendable, Equatable {
    let darkCeiling: Double
    let brightFloor: Double
    let stddevCeiling: Double
    let edgeDensityCeiling: Double

    /// 2026-04-18: `edgeDensityCeiling` raised from 0.12 → 0.22 after
    /// device testing. The monitor publishes `.max()` across 4 corner
    /// patches, so even one corner clipping a bookshelf / tiled floor
    /// / plant trips the ceiling. 0.12 was over-strict for real-world
    /// indoor captures; 0.22 keeps `.tooBusy` reserved for genuinely
    /// cluttered frames while letting the common "furnished room"
    /// case through as `.good`. Darkness / brightness / stddev
    /// thresholds untouched — each surfaces a different failure mode
    /// the HUD still needs to coach on.
    static let `default` = BackgroundQualityThresholds(
        darkCeiling: 0.25,
        brightFloor: 0.85,
        stddevCeiling: 0.15,
        edgeDensityCeiling: 0.22
    )
}

enum BackgroundQualityClassifier {
    /// Pure function: metrics + thresholds → quality. Easy to unit test.
    /// Order of checks matters — darkness wins over texture because a
    /// very dark frame can't be reliably classified for edges/variance.
    static func classify(
        metrics: BackgroundQualityMetrics,
        thresholds: BackgroundQualityThresholds = .default
    ) -> BackgroundQuality {
        if metrics.meanLuminance < thresholds.darkCeiling { return .tooDark }
        if metrics.meanLuminance > thresholds.brightFloor { return .tooBright }
        if metrics.maxStddev > thresholds.stddevCeiling { return .tooTextured }
        if metrics.maxEdgeDensity > thresholds.edgeDensityCeiling { return .tooBusy }
        return .good
    }
}

/// Injection seam so the camera view can be wired without a live
/// capture session (e.g. when previewing SwiftUI views).
protocol BackgroundQualityObserving: AnyObject, Sendable {
    @MainActor var quality: BackgroundQuality { get }
}

/// `AVCaptureVideoDataOutputSampleBufferDelegate` that converts each
/// frame into a `BackgroundQualityMetrics` + `BackgroundQuality`, then
/// publishes to the `@Observable` state on the main actor. Debounced to
/// 4 Hz so the HUD doesn't flicker under noise.
///
/// Sampling strategy: grab the Y plane of the NV12 frame and inspect 4
/// corner patches (128×128 each) — corners approximate "what's behind
/// the clothing" assuming the user frames the item in the center. This
/// is cheap (~0.5 ms on A15+) and avoids hitting the CPU with a full
/// color-space conversion.
@MainActor
@Observable
final class BackgroundQualityMonitor: NSObject, BackgroundQualityObserving {

    private(set) var quality: BackgroundQuality = .unknown

    private var lastUpdate: Date = .distantPast
    private let debounceInterval: TimeInterval = 0.25   // 4 Hz cap

    /// Edge-magnitude threshold on Y values in [0, 255]. 30 picks up
    /// text edges and object silhouettes but ignores sensor noise.
    /// `nonisolated` so the static helpers below can read it from the
    /// capture delegate queue without hopping to the main actor.
    nonisolated private static let edgeMagnitudeThreshold: UInt8 = 30

    /// Side length in pixels of each corner patch. 128 gives us ~16k
    /// samples per corner; enough statistical power without touching
    /// every pixel of a 1080p frame.
    nonisolated private static let patchSide: Int = 128

    override init() { super.init() }

    /// Runs on the capture delegate queue (NOT main). Must be
    /// synchronous with respect to the sample buffer lifetime — once
    /// this returns, AVFoundation may recycle the buffer.
    nonisolated func processSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard let metrics = Self.sampleMetrics(from: sampleBuffer) else { return }
        let newQuality = BackgroundQualityClassifier.classify(metrics: metrics)
        Task { @MainActor [weak self] in
            self?.publish(newQuality)
        }
    }

    /// Runs on the main actor. Debounces so a noisy frame can't flip
    /// the HUD back and forth in the same UI frame.
    private func publish(_ newQuality: BackgroundQuality) {
        let now = Date()
        guard now.timeIntervalSince(lastUpdate) >= debounceInterval else { return }
        lastUpdate = now
        if newQuality != quality { quality = newQuality }
    }

    /// Pull the 4 corner patches out of the Y plane and reduce them to
    /// mean / stddev / edge density. Returns nil for non-biplanar
    /// formats (shouldn't happen given our AVCapture config) or for
    /// frames smaller than `patchSide` (shouldn't happen either, guards
    /// against simulator corner cases).
    nonisolated static func sampleMetrics(from sampleBuffer: CMSampleBuffer) -> BackgroundQualityMetrics? {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }
        guard CVPixelBufferGetPlaneCount(pixelBuffer) >= 1 else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else { return nil }
        guard width >= patchSide, height >= patchSide else { return nil }

        let yBase = base.assumingMemoryBound(to: UInt8.self)

        let topLeft = patchStats(
            yBase: yBase, stride: stride,
            originX: 0, originY: 0,
            width: patchSide, height: patchSide
        )
        let topRight = patchStats(
            yBase: yBase, stride: stride,
            originX: width - patchSide, originY: 0,
            width: patchSide, height: patchSide
        )
        let bottomLeft = patchStats(
            yBase: yBase, stride: stride,
            originX: 0, originY: height - patchSide,
            width: patchSide, height: patchSide
        )
        let bottomRight = patchStats(
            yBase: yBase, stride: stride,
            originX: width - patchSide, originY: height - patchSide,
            width: patchSide, height: patchSide
        )
        let patches = [topLeft, topRight, bottomLeft, bottomRight]

        let meanLuminance = patches.map(\.mean).reduce(0, +) / Double(patches.count) / 255.0
        let maxStddev = (patches.map(\.stddev).max() ?? 0) / 255.0
        let maxEdgeDensity = patches.map(\.edgeDensity).max() ?? 0

        return BackgroundQualityMetrics(
            meanLuminance: meanLuminance,
            maxStddev: maxStddev,
            maxEdgeDensity: maxEdgeDensity
        )
    }

    // MARK: - Patch stats

    private struct PatchStats {
        let mean: Double          // [0, 255]
        let stddev: Double        // [0, 255]
        let edgeDensity: Double   // [0, 1]
    }

    /// Single-pass mean + variance (Welford is overkill for 16k samples)
    /// plus a cheap 4-neighbor gradient density. Reads only the Y plane.
    nonisolated private static func patchStats(
        yBase: UnsafePointer<UInt8>,
        stride: Int,
        originX: Int,
        originY: Int,
        width: Int,
        height: Int
    ) -> PatchStats {
        var sum: Int = 0
        var sumSquares: Int = 0
        var edgeCount: Int = 0
        let pixels = width * height

        // First pass: mean + variance
        for row in 0..<height {
            let rowPtr = yBase.advanced(by: (originY + row) * stride + originX)
            for col in 0..<width {
                let v = Int(rowPtr[col])
                sum += v
                sumSquares += v * v
            }
        }
        let mean = Double(sum) / Double(pixels)
        let variance = max(0, Double(sumSquares) / Double(pixels) - mean * mean)
        let stddev = sqrt(variance)

        // Second pass: 4-neighbor gradient magnitude. Skip 1-pixel border
        // to avoid out-of-patch reads.
        if width > 2 && height > 2 {
            for row in 1..<(height - 1) {
                let prevRow = yBase.advanced(by: (originY + row - 1) * stride + originX)
                let curRow = yBase.advanced(by: (originY + row) * stride + originX)
                let nextRow = yBase.advanced(by: (originY + row + 1) * stride + originX)
                for col in 1..<(width - 1) {
                    let dx = Int(curRow[col + 1]) - Int(curRow[col - 1])
                    let dy = Int(nextRow[col]) - Int(prevRow[col])
                    let magnitude = abs(dx) + abs(dy)
                    if magnitude > Int(edgeMagnitudeThreshold) {
                        edgeCount += 1
                    }
                }
            }
        }
        let interiorPixels = max(1, (width - 2) * (height - 2))
        let edgeDensity = Double(edgeCount) / Double(interiorPixels)

        return PatchStats(mean: mean, stddev: stddev, edgeDensity: edgeDensity)
    }
}

// MARK: - AVCapture bridge

/// Small delegate shim so `BackgroundQualityMonitor` can stay
/// `@MainActor` while AVFoundation's delegate method fires on a
/// non-isolated queue. The shim holds a weak reference to the monitor
/// and forwards each buffer synchronously via the `nonisolated`
/// `processSampleBuffer(_:)` entry point.
final class BackgroundQualityCaptureBridge: NSObject,
    AVCaptureVideoDataOutputSampleBufferDelegate,
    @unchecked Sendable
{
    private weak var monitor: BackgroundQualityMonitor?

    init(monitor: BackgroundQualityMonitor) {
        self.monitor = monitor
        super.init()
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        monitor?.processSampleBuffer(sampleBuffer)
    }
}
