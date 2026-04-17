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
}

extension SAM2Extracting {
    func prewarm() async { /* default no-op */ }
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

    init(
        ciContext: CIContext = CIContext(options: nil),
        modelLoader: (@Sendable () -> MLModel?)? = nil
    ) {
        self.ciContext = ciContext
        self.modelLoader = modelLoader ?? SAM2Extractor.defaultModelLoader
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
        guard let model = loadModelIfAvailable() else { return nil }
        return await runInference(model: model, image: image, points: points)
    }

    func prewarm() async {
        _ = loadModelIfAvailable()
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

    // MARK: - Inference

    /// Runs a SAM2 inference pass. The exact tensor shapes are declared by
    /// the compiled `.mlmodelc` file; we adapt at runtime so we don't have
    /// to hand-regenerate model classes every time the source model gets
    /// re-quantized.
    ///
    /// Implementation note: this routine is intentionally defensive — the
    /// SAM2 conversion pipeline produces slightly different input/output
    /// names depending on coremltools version (e.g. `image` vs `input_image`,
    /// `low_res_masks` vs `masks`). We inspect the `modelDescription` and
    /// pick the first compatible binding rather than hard-coding names.
    private func runInference(
        model: MLModel,
        image: UIImage,
        points: [SAM2TapPoint]
    ) async -> SAM2Result? {
        guard let provider = makeFeatureProvider(model: model, image: image, points: points) else {
            return nil
        }

        let prediction: MLFeatureProvider
        do {
            prediction = try await model.prediction(from: provider)
        } catch {
            return nil
        }

        guard let maskBuffer = extractMaskBuffer(from: prediction, model: model) else {
            return nil
        }

        guard let maskedImage = applyMask(maskBuffer, to: image) else {
            return nil
        }

        let coverage = coverageRatio(of: maskBuffer)
        return SAM2Result(
            maskedImage: maskedImage,
            mask: maskBuffer,
            coverageRatio: coverage
        )
    }

    /// Build an `MLFeatureProvider` whose keys match the loaded model's
    /// input description. Missing inputs (e.g. the model expects a
    /// resized image but we only have the full frame) trigger a nil
    /// return, which falls through to the Vision-only path.
    private func makeFeatureProvider(
        model: MLModel,
        image: UIImage,
        points: [SAM2TapPoint]
    ) -> MLFeatureProvider? {
        guard let cg = image.cgImage else { return nil }

        let inputs = model.modelDescription.inputDescriptionsByName
        var bindings: [String: MLFeatureValue] = [:]

        // Image input — try common names in priority order.
        let imageKeys = ["image", "input_image", "image_input", "pixel_values"]
        let imageKey = imageKeys.first(where: { inputs[$0] != nil }) ?? inputs.keys.first
        if let imageKey, let spec = inputs[imageKey], spec.type == .image {
            let size = spec.imageConstraint?.pixelsWide ?? cg.width
            let height = spec.imageConstraint?.pixelsHigh ?? cg.height
            guard let pixelBuffer = SAM2Extractor.pixelBuffer(
                from: cg,
                width: size,
                height: height
            ) else { return nil }
            bindings[imageKey] = MLFeatureValue(pixelBuffer: pixelBuffer)
        }

        // Point coordinates + labels — packed as 1 × N × 2 and 1 × N tensors.
        if let coordKey = ["point_coords", "coords", "points"].first(where: { inputs[$0] != nil }) {
            let coordShape = [1, NSNumber(value: points.count), 2] as [NSNumber]
            if let array = try? MLMultiArray(shape: coordShape, dataType: .float32) {
                let imageWidth = cg.width
                let imageHeight = cg.height
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

    /// Best-effort decode of the first mask-shaped output. Accepts both
    /// `CVPixelBuffer` image outputs and `MLMultiArray` tensors.
    private func extractMaskBuffer(
        from prediction: MLFeatureProvider,
        model: MLModel
    ) -> CVPixelBuffer? {
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

    // MARK: - Mask compositing

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
