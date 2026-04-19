import CoreImage
import CoreML
import CoreVideo
import Foundation
import UIKit
import os.log

// MARK: - Prediction payload

/// Single-garment attribute prediction returned by any
/// `AttributeClassifying` implementation. Confidences are always in
/// `[0, 1]`; `0.0` is the "no prediction" sentinel — either the model
/// hasn't shipped yet or the classifier was invoked with a crop that
/// couldn't be decoded. Enum-valued fields are nil when no class index
/// could be recovered at all, orthogonal to confidence; callers that
/// want to pre-fill a picker should respect
/// `AttributePrefill.shouldPrefill(…)` on the confidence rather than
/// simply branching on the optional.
struct AttributePrediction: Equatable, Sendable {
    var texture: TextureType?
    var textureConfidence: Float
    var fit: FitAttribute?
    var fitConfidence: Float

    /// All-empty prediction. Used by the shipping `MockAttributeClassifier`
    /// and as the fallback every time the real mlpackage hasn't been
    /// bundled yet — downstream `MaskProposal` consumers treat it as
    /// "rules-engine only" and every per-field pre-fill naturally
    /// short-circuits below the 0.80 threshold.
    static let empty = AttributePrediction(
        texture: nil,
        textureConfidence: 0.0,
        fit: nil,
        fitConfidence: 0.0
    )
}

// MARK: - Protocol

/// Injection seam for the per-garment attribute classifier. Production
/// uses `AttributeClassifierService`; tests + previews inject
/// `MockAttributeClassifier` so the higher-level VMs can exercise the
/// pre-fill logic without a live Core ML model. Mirrors the protocol
/// shape established by `MultiGarmentExtracting` (Sendable, async,
/// explicit throws, optional prewarm).
protocol AttributeClassifying: Sendable {
    /// Run the attribute classifier on a single-garment crop and return
    /// the (texture, fit) prediction plus per-head confidences. Callers
    /// typically feed a background-removed cutout (`MaskProposal.maskedImage`)
    /// to avoid distractor pixels; the model is resilient to backgrounds
    /// but masked inputs calibrate better (see Q1 in the auto-attribute
    /// plan's open questions).
    ///
    /// **Throws** `AttributeClassifierError` so callers can distinguish
    /// load-failure (model not bundled, Background Assets problem) from
    /// inference-failure (MLModel threw). A prediction with `nil` fields
    /// is not an error — it just means nothing cleared the internal
    /// argmax confidence floor.
    func predict(crop: UIImage) async throws -> AttributePrediction

    /// Pre-warm heavy resources (model compile + first inference). Safe
    /// to call repeatedly — implementations guard against redundant work.
    /// Intended to be called from `AddItemView.onAppear` alongside the
    /// multi-garment warm-up so the user doesn't pay the cold-start
    /// latency at capture time.
    func prewarm() async
}

extension AttributeClassifying {
    func prewarm() async { /* default no-op */ }
}

// MARK: - Error

/// Rich error type so attribute-classifier failures are self-describing
/// in logs + UI without forcing callers to inspect the underlying error.
/// Shape mirrors `MultiGarmentError` for consistency across the
/// extraction pipeline.
enum AttributeClassifierError: LocalizedError, Equatable {
    /// The Core ML model file couldn't be loaded (missing from bundle,
    /// Background Assets download incomplete, compile failure).
    case modelLoadFailed(reason: String, modelPath: String?)
    /// `MLModel.prediction(from:)` threw. Payload captures the
    /// underlying error's localized description for logs.
    case inferenceFailed(reason: String)
    /// Pre-processing couldn't convert the source crop into a pixel
    /// buffer of the model's expected 224×224 shape.
    case preprocessingFailed(reason: String)

    var errorDescription: String? {
        switch self {
        case .modelLoadFailed(let reason, let path):
            return "Attribute model load failed: \(reason) [\(path ?? "no path")]"
        case .inferenceFailed(let reason):
            return "Attribute inference failed: \(reason)"
        case .preprocessingFailed(let reason):
            return "Attribute preprocessing failed: \(reason)"
        }
    }

    static func == (lhs: AttributeClassifierError, rhs: AttributeClassifierError) -> Bool {
        switch (lhs, rhs) {
        case (.modelLoadFailed(let lr, let lp), .modelLoadFailed(let rr, let rp)):
            return lr == rr && lp == rp
        case (.inferenceFailed(let lr), .inferenceFailed(let rr)):
            return lr == rr
        case (.preprocessingFailed(let lr), .preprocessingFailed(let rr)):
            return lr == rr
        default: return false
        }
    }
}

// MARK: - Production service

/// Production `AttributeClassifying` implementation. Loads a Core ML
/// `AttributeClassifier.mlmodelc` (MobileNetV3-Small with two softmax
/// heads trained on Fashionpedia attribute crops) on first use and
/// decodes its output into an `AttributePrediction`.
///
/// **Graceful missing-model fallback.** Mirrors
/// `MultiGarmentProposalService`: if the model file isn't in the bundle
/// (training not yet shipped, Background Assets still downloading, LFS
/// content missing) every `predict` call throws `.modelLoadFailed`.
/// Callers wrap invocation in `try?` to fall through to rules-engine-only
/// pre-fill, keeping the pipeline green while the mlpackage is in-flight.
///
/// **Thread safety.** Model load is gated by an `NSLock` + one-shot
/// boolean so concurrent first-touch calls don't double-load. The loaded
/// `MLModel` itself is thread-safe for prediction calls.
final class AttributeClassifierService: AttributeClassifying, @unchecked Sendable {

    /// Filename (without extension) of the compiled Core ML model in the
    /// app bundle. Keep in sync with
    /// `notebooks/training/scripts/export_attribute_classifier.py`.
    static let bundledModelName = "AttributeClassifier"

    /// Model input is always 224×224. MobileNetV3-Small trained at that
    /// resolution; deviating would require re-training.
    static let inputSize: Int = 224

    /// Minimum softmax confidence required before we return a concrete
    /// enum case. Lower than `AttributePrefill.minConfidence` (0.80) on
    /// purpose — the threshold is calibrated for UI pre-fill; this
    /// threshold just keeps the classifier from emitting obviously-random
    /// guesses, while still letting the VM layer apply the stricter bar.
    static let minEnumConfidence: Float = 0.35

    /// Texture labels in the exact order the training notebook emits
    /// them. Index `i` in the softmax corresponds to `textureLabels[i]`.
    /// Must stay in lock-step with the Python side —
    /// `export_attribute_classifier.py` writes the same array into the
    /// mlpackage metadata so a drift-guard test can diff them at
    /// runtime.
    ///
    /// **Option C dormant.** Per
    /// `docs/plans/2026-04-19-auto-attribute-detection/ATTRIBUTE_TAXONOMY.md`
    /// § Section 0, Fashionpedia v2 carries no main-fabric-type
    /// attributes (cotton/silk/wool/denim/etc. are NOT labeled). The v1
    /// mlpackage ships with a **single fit head only** — no
    /// `texture_probs` output. The decode path below handles the missing
    /// output gracefully (multiArray → nil → argmax → nil → texture
    /// stays nil with 0.0 confidence), so every existing caller
    /// short-circuits correctly under the 0.80 pre-fill threshold.
    ///
    /// This array stays defined so v1.1 can reactivate a multi-head
    /// mlpackage (Option B: DeepFashion-backed texture training) without
    /// re-introducing the label order from scratch. See
    /// `BLOCKERS.md#D-3`.
    static let textureLabels: [TextureType] = [
        .cotton, .silk, .denim, .leather, .suede,
        .wool, .linen, .knit, .synthetic, .velvet,
        .satin, .chiffon, .tweed, .corduroy, .nylon
    ]

    /// Fit labels in the order the training notebook emits them. Mirrors
    /// `fashionpedia_attr_to_ios_enum.TRAINABLE_FIT_LABELS` exactly — same
    /// 5 entries, same order. Index `i` in the `(1, 5)` `fit_probs`
    /// softmax corresponds to `fitLabels[i]`.
    ///
    /// **Option C scope.** `.structured` is intentionally absent: per
    /// `BLOCKERS.md#D-6` the silhouette has no Fashionpedia label that
    /// maps to it cleanly, so the v1 model never emits it. Picker UIs
    /// (`AddItemView`) still iterate `FitAttribute.allCases` so the user
    /// can pick `.structured` manually — only the auto-prediction path
    /// is restricted to the trainable subset. v1.1 reactivates the full
    /// 6-class head once a structured-fit signal is available.
    ///
    /// Drift guards: `fitLabelsLockOptionCTrainableSubset` test pins this
    /// array; the Python side carries an identical list in
    /// `fashionpedia_attr_to_ios_enum.TRAINABLE_FIT_LABELS` and the
    /// exporter writes it into mlpackage metadata for runtime audit.
    static let fitLabels: [FitAttribute] = [
        .oversized, .relaxed, .regular, .slim, .cropped
    ]

    private let modelLoader: @Sendable () -> MLModel?
    private let logger = Logger(subsystem: "com.wardroberedo", category: "AttributeClassifier")

    /// One-shot model load. `NSLock`-gated lazy just like
    /// `MultiGarmentProposalService`.
    private let modelLock = NSLock()
    private var loadedModel: MLModel?
    private var modelLoadAttempted = false

    init(modelLoader: (@Sendable () -> MLModel?)? = nil) {
        self.modelLoader = modelLoader ?? AttributeClassifierService.defaultModelLoader
    }

    // MARK: - Public API

    func predict(crop: UIImage) async throws -> AttributePrediction {
        guard let model = loadModelIfAvailable() else {
            let path = Self.defaultModelURL()?.lastPathComponent
            logger.error("predict.modelLoadFailed modelPath=\(path ?? "nil", privacy: .public)")
            throw AttributeClassifierError.modelLoadFailed(
                reason: "Core ML attribute model could not be loaded (missing from bundle or compile failed)",
                modelPath: path
            )
        }

        let normalized = OrientationUtil.normalized(crop)

        guard let pixelBuffer = Self.preprocessedPixelBuffer(for: normalized) else {
            logger.error("predict.preprocessingFailed")
            throw AttributeClassifierError.preprocessingFailed(
                reason: "Could not convert crop to 224×224 pixel buffer"
            )
        }

        let inputName = Self.imageInputName(for: model) ?? "image"
        let provider: MLFeatureProvider
        do {
            provider = try MLDictionaryFeatureProvider(dictionary: [
                inputName: MLFeatureValue(pixelBuffer: pixelBuffer)
            ])
        } catch {
            logger.error("predict.providerFailed \(error.localizedDescription, privacy: .public)")
            throw AttributeClassifierError.preprocessingFailed(reason: error.localizedDescription)
        }

        let prediction: MLFeatureProvider
        do {
            prediction = try await model.prediction(from: provider)
        } catch {
            logger.error("predict.inferenceFailed \(error.localizedDescription, privacy: .public)")
            throw AttributeClassifierError.inferenceFailed(reason: error.localizedDescription)
        }

        return Self.decode(prediction: prediction)
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

    fileprivate static func defaultModelURL() -> URL? {
        Bundle.main.url(
            forResource: AttributeClassifierService.bundledModelName,
            withExtension: "mlmodelc"
        )
    }

    private static let defaultModelLoader: @Sendable () -> MLModel? = {
        guard let url = defaultModelURL() else { return nil }
        let config = MLModelConfiguration()
        config.computeUnits = .all
        return try? MLModel(contentsOf: url, configuration: config)
    }

    // MARK: - Preprocessing

    /// Convert `image` into the 224×224 `CVPixelBuffer` the classifier
    /// expects. Normalization (ImageNet mean/std) is baked into the
    /// Core ML model as preprocessing layers by the export script, so
    /// we only need to deliver correct pixel dimensions here.
    static func preprocessedPixelBuffer(for image: UIImage) -> CVPixelBuffer? {
        guard let cg = image.cgImage else { return nil }
        return SAM2Extractor.pixelBuffer(from: cg, width: inputSize, height: inputSize)
    }

    static func imageInputName(for model: MLModel) -> String? {
        let inputs = model.modelDescription.inputDescriptionsByName
        let preferred = ["image", "input_image", "image_input", "pixel_values", "images"]
        if let hit = preferred.first(where: { inputs[$0]?.type == .image }) {
            return hit
        }
        return inputs.first(where: { $0.value.type == .image })?.key
    }

    // MARK: - Output decode

    /// Preferred output names (training notebook writes these; we also
    /// accept a couple of coremltools-defaulted alternates).
    static let textureOutputKeys = ["texture_probs", "texture_logits", "texture"]
    static let fitOutputKeys = ["fit_probs", "fit_logits", "fit"]

    /// Decode the classifier outputs into an `AttributePrediction`.
    /// Split out as a pure function so tests can construct
    /// `MLFeatureProvider`s directly (via `MLDictionaryFeatureProvider`)
    /// and exercise the full decode path without a live model.
    static func decode(prediction: MLFeatureProvider) -> AttributePrediction {
        let textureArray = multiArray(for: textureOutputKeys, in: prediction)
        let fitArray = multiArray(for: fitOutputKeys, in: prediction)

        let (textureIdx, textureConf) = argmaxSoftmax(textureArray, labelCount: textureLabels.count)
        let (fitIdx, fitConf) = argmaxSoftmax(fitArray, labelCount: fitLabels.count)

        let texture: TextureType? = {
            guard let idx = textureIdx, textureConf >= minEnumConfidence,
                  idx < textureLabels.count else { return nil }
            return textureLabels[idx]
        }()

        let fit: FitAttribute? = {
            guard let idx = fitIdx, fitConf >= minEnumConfidence,
                  idx < fitLabels.count else { return nil }
            return fitLabels[idx]
        }()

        return AttributePrediction(
            texture: texture,
            textureConfidence: textureConf,
            fit: fit,
            fitConfidence: fitConf
        )
    }

    /// Resolve the first matching output key to an `MLMultiArray`.
    /// Accepts logits or pre-softmaxed probabilities — `argmaxSoftmax`
    /// passes raw logits through a softmax and leaves in-range
    /// probabilities alone, so the caller doesn't need to know which
    /// the export produced.
    static func multiArray(
        for keys: [String],
        in prediction: MLFeatureProvider
    ) -> MLMultiArray? {
        for key in keys {
            if let value = prediction.featureValue(for: key),
               value.type == .multiArray,
               let array = value.multiArrayValue {
                return array
            }
        }
        return nil
    }

    /// Argmax + softmax over a `[1, N]` or `[N]` tensor. Returns
    /// `(nil, 0.0)` when the array is absent or empty. When the max
    /// value is already in `[0, 1]` and the vector sums to roughly 1
    /// we treat it as pre-softmaxed probabilities and return the value
    /// as-is; otherwise we compute a stable softmax.
    static func argmaxSoftmax(
        _ array: MLMultiArray?,
        labelCount: Int
    ) -> (index: Int?, confidence: Float) {
        guard let array, labelCount > 0 else { return (nil, 0.0) }

        // Infer the axis that holds the labels. The export pipeline
        // writes `[1, N]` by default, but we also accept a bare `[N]`.
        let shape = array.shape.map { $0.intValue }
        guard let n = shape.last, n == labelCount else {
            return (nil, 0.0)
        }
        let batchStride = shape.count >= 2 ? shape[shape.count - 2] : 1
        _ = batchStride // placeholder; we only read the first row

        // Collect the N values.
        var values = [Float](repeating: 0, count: labelCount)
        for i in 0 ..< labelCount {
            // For `[1, N]` we want `[0, i]`; for `[N]` just `[i]`.
            let indices: [NSNumber]
            if shape.count >= 2 {
                indices = [0, NSNumber(value: i)]
            } else {
                indices = [NSNumber(value: i)]
            }
            values[i] = array[indices].floatValue
        }

        // Find argmax + max raw value.
        var bestIdx = 0
        var bestRaw = -Float.greatestFiniteMagnitude
        for (i, v) in values.enumerated() where v > bestRaw {
            bestRaw = v
            bestIdx = i
        }

        // Heuristic: if every entry is already in [0, 1] and they sum
        // to ~1, treat as probabilities; otherwise softmax.
        let sum = values.reduce(0, +)
        let looksLikeProbs = values.allSatisfy { $0 >= 0 && $0 <= 1 } && abs(sum - 1.0) < 0.05
        let confidence: Float
        if looksLikeProbs {
            confidence = values[bestIdx]
        } else {
            // Numerically stable softmax.
            let maxV = bestRaw
            var expSum: Float = 0
            var expBest: Float = 0
            for (i, v) in values.enumerated() {
                let e = expf(v - maxV)
                expSum += e
                if i == bestIdx { expBest = e }
            }
            confidence = expSum > 0 ? expBest / expSum : 0
        }

        return (bestIdx, confidence)
    }
}

// MARK: - Mock for tests + previews

/// Deterministic mock that short-circuits the Core ML dependency. Tests
/// and SwiftUI previews inject this when they need an `AttributeClassifying`
/// but don't want to load a live mlpackage. Default behaviour is "no
/// prediction" — every field nil / 0.0 — which mirrors the production
/// fallback when the bundled model is missing, so VMs that depend on
/// the service work correctly even when no test has pre-configured it.
///
/// Thread-safety uses a serial `DispatchQueue`: `NSLock` is off-limits
/// from async functions under Swift 6 strict concurrency, and
/// `DispatchQueue.sync` is the blessed async-safe escape hatch — see
/// `MultiGarmentProposalService` which uses `NSLock` only in its
/// synchronous load path for the same reason.
final class MockAttributeClassifier: AttributeClassifying, @unchecked Sendable {
    enum Behavior: Sendable {
        case returnPrediction(AttributePrediction)
        case throwError(AttributeClassifierError)
    }

    private let queue = DispatchQueue(label: "com.wardroberedo.MockAttributeClassifier")
    private var _behavior: Behavior
    private var _callCount: Int = 0

    var callCount: Int {
        queue.sync { _callCount }
    }

    init(behavior: Behavior = .returnPrediction(.empty)) {
        self._behavior = behavior
    }

    convenience init(prediction: AttributePrediction) {
        self.init(behavior: .returnPrediction(prediction))
    }

    /// Swap the behaviour mid-test (e.g. first call succeeds, second
    /// throws). Thread-safe because the service itself can be hit
    /// concurrently by the proposal pipeline.
    func setBehavior(_ new: Behavior) {
        queue.sync { _behavior = new }
    }

    func predict(crop: UIImage) async throws -> AttributePrediction {
        let snapshot: Behavior = queue.sync {
            _callCount += 1
            return _behavior
        }

        switch snapshot {
        case .returnPrediction(let prediction):
            return prediction
        case .throwError(let error):
            throw error
        }
    }
}
