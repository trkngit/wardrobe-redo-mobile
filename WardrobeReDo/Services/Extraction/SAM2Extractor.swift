import CoreImage
import CoreML
import CoreVideo
import Foundation
import UIKit

/// One tap registered by the user (or synthesized by `autoSegment`) on the
/// image plane. Coordinates are in **normalized** [0, 1] × [0, 1] space
/// with the origin at the top-left, so the same point survives
/// aspect-fit / scale transforms in the UI.
struct SAM2TapPoint: Sendable, Equatable {
    /// Normalized coordinate in the image's own coordinate space.
    let normalized: CGPoint
    /// Positive points mark "this IS the clothing"; negative points mark
    /// "this is NOT the clothing" (skin, background) — SAM2 uses both to
    /// constrain the mask.
    let isPositive: Bool

    static func positive(_ point: CGPoint) -> SAM2TapPoint {
        SAM2TapPoint(normalized: point, isPositive: true)
    }

    static func negative(_ point: CGPoint) -> SAM2TapPoint {
        SAM2TapPoint(normalized: point, isPositive: false)
    }
}

/// Result of a SAM2 segmentation pass. Shape mirrors `ForegroundMaskResult`
/// so `ClothingExtractionService` can treat both interchangeably when
/// wrapping them into an `ExtractionResult`.
struct SAM2Result: @unchecked Sendable {
    let maskedImage: UIImage
    let mask: CVPixelBuffer?
    /// Approximate coverage (0…1) of the mask over the frame. Used to
    /// synthesize `ExtractionConfidence` the same way Vision does.
    let coverageRatio: Double
}

/// A SAM2 segmentation session bound to a single source image. Holds the
/// expensive per-image prep (loaded `MLModel`, resized `CVPixelBuffer`)
/// so repeat taps from `TapToSelectView` — or repeat "Save & add another
/// garment" loops in `AddItemViewModel` — only pay model-prediction cost
/// on taps 2..N, not the CGImage → 1024×1024 pixel-buffer resize (~60 ms
/// on A15+).
///
/// Sessions are single-source-image; making a new session for a new
/// photo is cheap, and callers should discard a session when the source
/// image changes.
protocol SAM2Session: Sendable {
    /// One SAM2 inference pass over the cached source image at the given
    /// points. Returns nil when inference fails or the session's model
    /// rejects the point shape.
    func segment(points: [SAM2TapPoint]) async -> SAM2Result?
}

/// Injection seam so `ClothingExtractionService` and the tap-to-select
/// UI can be tested without a real Core ML model. Mocks return a canned
/// `SAM2Result` (or `nil` to simulate missing-model / failure).
protocol SAM2Extracting: Sendable {
    /// Single positive point at the geometric center — the automatic
    /// fallback used when Vision confidence is `.low` / `.failed`.
    func autoSegment(from image: UIImage) async -> SAM2Result?

    /// Tap-to-select path: user provided explicit positive/negative
    /// points via `TapToSelectView`.
    func segment(image: UIImage, points: [SAM2TapPoint]) async -> SAM2Result?

    /// Pre-warm any heavy resources (model load, encoder pass). Called
    /// from `TapToSelectView.onAppear` and `AddItemView.onAppear` so by
    /// the time the user taps, inference is already primed.
    func prewarm() async

    /// Open a reusable session for `image`. Production implementations
    /// cache a resized pixel buffer so subsequent `segment(points:)`
    /// calls don't re-resize the source on every tap. Returns nil when
    /// the model is unavailable (missing LFS bundle, load failure).
    func makeSession(for image: UIImage) async -> SAM2Session?
}

extension SAM2Extracting {
    func prewarm() async { /* default no-op */ }

    /// Default: wrap the existing `segment(image:points:)` so conformers
    /// (e.g. `MockSAM2Extractor` in tests) satisfy the session API
    /// without explicit work. Every call re-enters `segment(image:, points:)`
    /// — there's no caching in this path. Production types (`SAM2Extractor`)
    /// override to return a real caching session.
    func makeSession(for image: UIImage) async -> SAM2Session? {
        LegacySAM2Session(extractor: self, image: image)
    }
}

/// Back-compat shim used by the default `makeSession(for:)` impl. Every
/// `segment(points:)` call re-invokes the underlying extractor's
/// `segment(image:points:)` — no caching. This keeps non-session-aware
/// conformers (e.g. test mocks that only implement `segment(image:points:)`)
/// working through the session-only code paths.
private struct LegacySAM2Session: SAM2Session, @unchecked Sendable {
    let extractor: any SAM2Extracting
    let image: UIImage

    func segment(points: [SAM2TapPoint]) async -> SAM2Result? {
        await extractor.segment(image: image, points: points)
    }
}

/// Production `SAM2Extracting` implementation. Loads `SAM2Tiny.mlmodelc`
/// from the app bundle on first use and hands tap points to it.
///
/// **Graceful missing-model fallback.** The compiled `.mlmodelc` ships
/// via Git LFS and may be absent in developer checkouts that haven't
/// pulled LFS content yet, or on CI runners without the binary. When the
/// model can't be loaded we return `nil` from every call — the caller
/// (`ClothingExtractionService`) treats that as "SAM2 unavailable" and
/// keeps the Vision-only result. The app continues to build and ship.
///
/// **Simulator.** Core ML runs on the simulator but loading a missing
/// model file is still the dominant failure mode, so the same fallback
/// applies. No `#if targetEnvironment(simulator)` branch needed.
final class SAM2Extractor: SAM2Extracting, @unchecked Sendable {

    /// Filename (without extension) of the compiled Core ML model in the
    /// app bundle. Keep in sync with `WardrobeReDo/Models/CoreML/…`.
    static let bundledModelName = "SAM2Tiny"

    private let ciContext: CIContext
    private let modelLoader: @Sendable () -> MLModel?

    /// One-shot model load. Wrapped in a lock-free lazy via `NSLock` to
    /// avoid racing the first inference.
    private let modelLock = NSLock()
    private var loadedModel: MLModel?
    private var modelLoadAttempted = false

    /// Token returned by `NotificationCenter.addObserver(forName:…)`
    /// for the memory-warning observer. See
    /// `MultiGarmentProposalService` for the rationale — same eviction
    /// pattern, kept in sync across the three Core ML services.
    private var memoryWarningObserver: NSObjectProtocol?

    init(
        ciContext: CIContext = CIContext(options: nil),
        modelLoader: (@Sendable () -> MLModel?)? = nil
    ) {
        self.ciContext = ciContext
        self.modelLoader = modelLoader ?? SAM2Extractor.defaultModelLoader

        // Drop the loaded SAM2 model on memory warning so iOS can
        // reclaim ~30 MB. Next call reloads transparently.
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.evictLoadedModel()
        }
    }

    deinit {
        if let observer = memoryWarningObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Drops the loaded `MLModel`. Wired to memory-warning
    /// notifications in `init`; exposed as `internal` so tests can
    /// drive the reload-after-evict path without posting fake
    /// notifications.
    func evictLoadedModel() {
        modelLock.lock()
        defer { modelLock.unlock() }
        loadedModel = nil
        modelLoadAttempted = false
    }

    // MARK: - Public API

    func autoSegment(from image: UIImage) async -> SAM2Result? {
        // Geometric center of the frame is our best prior when we don't
        // know where the user intended to point.
        let center = SAM2TapPoint.positive(CGPoint(x: 0.5, y: 0.5))
        return await segment(image: image, points: [center])
    }

    func segment(image: UIImage, points: [SAM2TapPoint]) async -> SAM2Result? {
        guard !points.isEmpty else { return nil }
        // Route through `makeSession` so the per-image resize / feature
        // provider construction lives in one place. Single-shot callers
        // pay the resize once; tap-to-select callers re-use the session
        // across taps.
        return await makeSession(for: image)?.segment(points: points)
    }

    func prewarm() async {
        _ = loadModelIfAvailable()
    }

    func makeSession(for image: UIImage) async -> SAM2Session? {
        guard let model = loadModelIfAvailable() else { return nil }
        return SAM2SessionImpl(model: model, image: image, ciContext: ciContext)
    }

    // MARK: - Model loading

    private func loadModelIfAvailable() -> MLModel? {
        modelLock.lock()
        defer { modelLock.unlock() }
        if let model = loadedModel { return model }
        if modelLoadAttempted { return nil }
        modelLoadAttempted = true
        loadedModel = modelLoader()
        return loadedModel
    }

    /// Default: look for `SAM2Tiny.mlmodelc` in the main bundle. Returns
    /// nil when the file is missing (common until Git LFS content lands)
    /// or when Core ML can't compile it for some reason.
    private static let defaultModelLoader: @Sendable () -> MLModel? = {
        guard let url = Bundle.main.url(
            forResource: SAM2Extractor.bundledModelName,
            withExtension: "mlmodelc"
        ) else { return nil }

        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        return try? MLModel(contentsOf: url, configuration: configuration)
    }

    // MARK: - Pixel-buffer helpers

    /// Resize `cg` into a `CVPixelBuffer` of the requested size. Used to
    /// prep the model's input tensor from the user's photo.
    static func pixelBuffer(from cg: CGImage, width: Int, height: Int) -> CVPixelBuffer? {
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]

        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32ARGB,
            attrs as CFDictionary,
            &buffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer = buffer else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(pixelBuffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
        ) else { return nil }

        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixelBuffer
    }

    /// Convert a float mask tensor to a single-channel 8-bit `CVPixelBuffer`
    /// so the downstream compositor can blend it against the source image.
    /// Accepts `[H, W]`, `[1, H, W]`, and `[1, 1, H, W]` shapes (the most
    /// common SAM2 mask outputs).
    static func pixelBuffer(fromMultiArray array: MLMultiArray) -> CVPixelBuffer? {
        let shape = array.shape.map(\.intValue)
        let width: Int
        let height: Int
        switch shape.count {
        case 2:
            height = shape[0]
            width = shape[1]
        case 3:
            height = shape[1]
            width = shape[2]
        case 4:
            height = shape[2]
            width = shape[3]
        default:
            return nil
        }
        guard width > 0, height > 0 else { return nil }

        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_OneComponent8,
            nil,
            &buffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer = buffer else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)

        for y in 0..<height {
            let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width {
                let flatIndex: Int
                switch shape.count {
                case 2: flatIndex = y * width + x
                case 3: flatIndex = y * width + x
                case 4: flatIndex = y * width + x
                default: return nil
                }
                let raw = array[flatIndex].floatValue
                // SAM2 emits signed logits in many builds; a tiny sigmoid
                // turns them into [0, 1] without needing Accelerate.
                let sigmoid = 1.0 / (1.0 + expf(-raw))
                let scaled = min(255, max(0, Int(sigmoid * 255)))
                row[x] = UInt8(scaled)
            }
        }
        return pixelBuffer
    }
}

// MARK: - SAM2SessionImpl

/// Production `SAM2Session`. Caches the per-image work (normalized
/// source `UIImage`, loaded `MLModel`, pre-resized `CVPixelBuffer` for
/// each of the model's image-shaped inputs) so `segment(points:)` only
/// pays model-prediction + point-tensor marshaling on taps 2..N.
///
/// Created by `SAM2Extractor.makeSession(for:)`. Held by
/// `AddItemViewModel` and `TapToSelectView` across the lifetime of one
/// captured photo; discarded when the user picks a new photo or
/// dismisses the capture flow.
///
/// Implementation note: the bundled `SAM2Tiny.mlmodelc` is a monolithic
/// graph (image + points → mask in one `prediction(from:)` call), so the
/// savings per tap are limited to skipping the CGImage → 1024×1024 CPU
/// resize (~60 ms on A15+). A future split-model refactor — exposing
/// image-encoder output separately — would let us cache the encoder
/// features too and push per-tap cost down by another ~300 ms. Out of
/// scope for this cycle.
private final class SAM2SessionImpl: SAM2Session, @unchecked Sendable {
    private let model: MLModel
    private let normalizedImage: UIImage
    private let ciContext: CIContext

    /// Pre-resized pixel buffers keyed by the model's image-input name.
    /// Precomputed in `init(...)` so `segment(points:)` never resizes.
    private let cachedInputBuffers: [String: CVPixelBuffer]

    /// Source image pixel dimensions. Used to map the normalized tap
    /// coordinates back into the model's expected point space.
    private let imageWidth: Int
    private let imageHeight: Int

    /// Fails (`init?` → nil) when the source image has no backing
    /// `CGImage`, or when the model declares no usable image input, or
    /// when pixel-buffer creation fails. Callers fall back to "SAM2
    /// unavailable" (same behavior as a missing model).
    init?(model: MLModel, image: UIImage, ciContext: CIContext) {
        guard let cg = image.cgImage else { return nil }

        let inputs = model.modelDescription.inputDescriptionsByName

        // Pick the image input by name (common SAM2 export variants).
        let imageKeys = ["image", "input_image", "image_input", "pixel_values"]
        let imageKey = imageKeys.first(where: { inputs[$0]?.type == .image })
            ?? inputs.first(where: { $0.value.type == .image })?.key
        guard let resolvedKey = imageKey,
              let spec = inputs[resolvedKey],
              spec.type == .image
        else { return nil }

        let width = spec.imageConstraint?.pixelsWide ?? cg.width
        let height = spec.imageConstraint?.pixelsHigh ?? cg.height
        guard let buffer = SAM2Extractor.pixelBuffer(
            from: cg,
            width: width,
            height: height
        ) else { return nil }

        self.model = model
        self.normalizedImage = image
        self.ciContext = ciContext
        self.cachedInputBuffers = [resolvedKey: buffer]
        self.imageWidth = cg.width
        self.imageHeight = cg.height
    }

    func segment(points: [SAM2TapPoint]) async -> SAM2Result? {
        guard !points.isEmpty else { return nil }
        guard let provider = makeFeatureProvider(points: points) else { return nil }

        let prediction: MLFeatureProvider
        do {
            prediction = try await model.prediction(from: provider)
        } catch {
            return nil
        }

        guard let maskBuffer = extractMaskBuffer(from: prediction) else { return nil }
        guard let maskedImage = applyMask(maskBuffer, to: normalizedImage) else {
            return nil
        }

        let coverage = coverageRatio(of: maskBuffer)
        return SAM2Result(
            maskedImage: maskedImage,
            mask: maskBuffer,
            coverageRatio: coverage
        )
    }

    // MARK: - Feature provider

    /// Builds an `MLFeatureProvider` for the cached image + per-tap
    /// points. Image bindings reuse the cached `CVPixelBuffer`; point
    /// bindings are rebuilt each call because the tap set changes
    /// between taps.
    ///
    /// Defensive about input names — the SAM2 conversion pipeline emits
    /// slightly different names across coremltools versions (e.g.
    /// `image` vs `input_image`, `point_coords` vs `points`).
    private func makeFeatureProvider(points: [SAM2TapPoint]) -> MLFeatureProvider? {
        let inputs = model.modelDescription.inputDescriptionsByName
        var bindings: [String: MLFeatureValue] = [:]

        for (key, buffer) in cachedInputBuffers {
            bindings[key] = MLFeatureValue(pixelBuffer: buffer)
        }

        // Point coordinates + labels — packed as 1 × N × 2 and 1 × N tensors.
        if let coordKey = ["point_coords", "coords", "points"].first(where: { inputs[$0] != nil }) {
            let coordShape = [1, NSNumber(value: points.count), 2] as [NSNumber]
            if let array = try? MLMultiArray(shape: coordShape, dataType: .float32) {
                for (idx, pt) in points.enumerated() {
                    let xIndex = [0, NSNumber(value: idx), 0] as [NSNumber]
                    let yIndex = [0, NSNumber(value: idx), 1] as [NSNumber]
                    array[xIndex] = NSNumber(value: Float(pt.normalized.x * CGFloat(imageWidth)))
                    array[yIndex] = NSNumber(value: Float(pt.normalized.y * CGFloat(imageHeight)))
                }
                bindings[coordKey] = MLFeatureValue(multiArray: array)
            }
        }

        if let labelKey = ["point_labels", "labels", "point_types"].first(where: { inputs[$0] != nil }) {
            let labelShape = [1, NSNumber(value: points.count)] as [NSNumber]
            if let array = try? MLMultiArray(shape: labelShape, dataType: .float32) {
                for (idx, pt) in points.enumerated() {
                    let indexPath = [0, NSNumber(value: idx)] as [NSNumber]
                    array[indexPath] = NSNumber(value: pt.isPositive ? 1 : 0)
                }
                bindings[labelKey] = MLFeatureValue(multiArray: array)
            }
        }

        return try? MLDictionaryFeatureProvider(dictionary: bindings)
    }

    // MARK: - Mask post-processing

    /// Best-effort decode of the first mask-shaped output. Accepts both
    /// `CVPixelBuffer` image outputs and `MLMultiArray` tensors.
    private func extractMaskBuffer(from prediction: MLFeatureProvider) -> CVPixelBuffer? {
        let outputNames = model.modelDescription.outputDescriptionsByName.keys
        let preferredOrder = ["masks", "low_res_masks", "mask", "output"]
        let ordered = preferredOrder.filter { outputNames.contains($0) } +
            outputNames.filter { !preferredOrder.contains($0) }

        for name in ordered {
            guard let value = prediction.featureValue(for: name) else { continue }
            if value.type == .image, let buffer = value.imageBufferValue {
                return buffer
            }
            if value.type == .multiArray, let array = value.multiArrayValue,
               let buffer = SAM2Extractor.pixelBuffer(fromMultiArray: array) {
                return buffer
            }
        }
        return nil
    }

    private func applyMask(_ mask: CVPixelBuffer, to image: UIImage) -> UIImage? {
        guard let cg = image.cgImage else { return nil }
        let sourceCI = CIImage(cgImage: cg)
        let maskCI = CIImage(cvPixelBuffer: mask)

        let scaleX = sourceCI.extent.width / maskCI.extent.width
        let scaleY = sourceCI.extent.height / maskCI.extent.height
        let scaledMask = maskCI.transformed(
            by: CGAffineTransform(scaleX: scaleX, y: scaleY)
        )

        let blend = CIFilter(name: "CIBlendWithMask")!
        blend.setValue(sourceCI, forKey: kCIInputImageKey)
        blend.setValue(CIImage.empty(), forKey: kCIInputBackgroundImageKey)
        blend.setValue(scaledMask, forKey: kCIInputMaskImageKey)

        guard let output = blend.outputImage,
              let rendered = ciContext.createCGImage(output, from: sourceCI.extent)
        else { return nil }
        return UIImage(cgImage: rendered)
    }

    private func coverageRatio(of mask: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(mask, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }

        let width = CVPixelBufferGetWidth(mask)
        let height = CVPixelBufferGetHeight(mask)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(mask)
        guard let base = CVPixelBufferGetBaseAddress(mask) else { return 0 }

        var foreground: Int = 0
        let total = width * height
        guard total > 0 else { return 0 }

        for row in 0..<height {
            let rowPtr = base.advanced(by: row * bytesPerRow)
                .assumingMemoryBound(to: UInt8.self)
            for col in 0..<width where rowPtr[col] > 128 {
                foreground += 1
            }
        }
        return Double(foreground) / Double(total)
    }
}
