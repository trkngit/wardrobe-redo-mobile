import CoreImage
import CoreML
import CoreVideo
import Foundation
import UIKit
import os.log

/// Injection seam. Production uses `MultiGarmentProposalService`; tests
/// + previews supply `MockMultiGarmentExtractor`. Mirrors the shape of
/// `ClothingExtracting` for consistency.
protocol MultiGarmentExtracting: Sendable {
    /// Run the Core ML model on `image` and return the surviving
    /// per-garment proposals (already NMS'd, thresholded, sorted by
    /// detection score, capped at `MultiGarmentProposalService.maxProposals`).
    ///
    /// **Throws** `MultiGarmentError` so callers can distinguish
    /// load-failure (bundle/Background Assets problem) from
    /// inference-failure from simply-nothing-detected (empty array).
    func detectProposals(in image: UIImage) async throws -> [MaskProposal]

    /// Pre-warm heavy resources (model compile + first inference). Safe
    /// to call repeatedly — the underlying service guards against
    /// redundant work. Invoked from `AddItemView.onAppear` so the user
    /// doesn't pay the cold-start latency at capture time.
    func prewarm() async
}

extension MultiGarmentExtracting {
    func prewarm() async { /* default no-op */ }
}

/// Rich error type so failures are self-describing in logs + UI without
/// forcing callers to inspect the underlying error.
enum MultiGarmentError: LocalizedError, Equatable {
    /// The Core ML model file couldn't be loaded (missing from bundle,
    /// Background Assets download incomplete, compile failure).
    case modelLoadFailed(reason: String, modelPath: String?)
    /// `MLModel.prediction(from:)` threw. Payload captures the
    /// underlying error's localized description for logs.
    case inferenceFailed(reason: String)
    /// Model ran but we couldn't decode any usable outputs — either the
    /// output names don't match what we expect, or every proposal was
    /// filtered out below the confidence threshold.
    case noValidPredictions(rawCount: Int, threshold: Float)
    /// Pre-processing couldn't convert the source image into a pixel
    /// buffer of the model's expected shape.
    case preprocessingFailed(reason: String)

    var errorDescription: String? {
        switch self {
        case .modelLoadFailed(let reason, let path):
            return "Model load failed: \(reason) [\(path ?? "no path")]"
        case .inferenceFailed(let reason):
            return "Inference failed: \(reason)"
        case .noValidPredictions(let raw, let threshold):
            return "No valid predictions (raw=\(raw), threshold=\(threshold))"
        case .preprocessingFailed(let reason):
            return "Preprocessing failed: \(reason)"
        }
    }

    static func == (lhs: MultiGarmentError, rhs: MultiGarmentError) -> Bool {
        switch (lhs, rhs) {
        case (.modelLoadFailed(let lr, let lp), .modelLoadFailed(let rr, let rp)):
            return lr == rr && lp == rp
        case (.inferenceFailed(let lr), .inferenceFailed(let rr)):
            return lr == rr
        case (.noValidPredictions(let lc, let lt), .noValidPredictions(let rc, let rt)):
            return lc == rc && lt == rt
        case (.preprocessingFailed(let lr), .preprocessingFailed(let rr)):
            return lr == rr
        default: return false
        }
    }
}

/// Production `MultiGarmentExtracting` implementation. Loads a Core ML
/// `RFDETRSegFashion.mlmodelc` (Fashionpedia-fine-tuned RF-DETR-Seg-Small)
/// on first use and post-processes its DETR-style outputs into
/// `MaskProposal`s.
///
/// **Graceful missing-model fallback.** Mirrors `SAM2Extractor`: if the
/// model file isn't in the bundle (training not yet shipped, Background
/// Assets still downloading, LFS content missing) every `detectProposals`
/// call throws `.modelLoadFailed`. The caller (`ImageService`) converts
/// that to `proposals: nil` and the rest of the pipeline runs unchanged.
///
/// **Thread safety.** Model load is gated by an `NSLock` + one-shot
/// boolean so concurrent first-touch calls don't double-load. The loaded
/// `MLModel` itself is thread-safe for prediction calls.
final class MultiGarmentProposalService: MultiGarmentExtracting, @unchecked Sendable {

    /// Filename (without extension) of the compiled Core ML model in the
    /// app bundle. Keep in sync with `WardrobeReDo/Models/CoreML/…` or
    /// the Background Assets manifest if delivered out-of-band.
    static let bundledModelName = "RFDETRSegFashion"

    /// Keep only this many proposals in the UI. Above this cap the
    /// lowest-score detections are dropped before the grid renders.
    /// Lowered from 8 → 6 in the multi-pick quality pass: the rug /
    /// non-clothing false-positive risk grows linearly with the cap,
    /// and 6 is enough headroom for any realistic full-body capture
    /// (top + bottom + 1-2 outerwear + 1-2 accessories + 1 shoe pair).
    static let maxProposals = 6

    /// Confidence floor for proposals whose Fashionpedia class doesn't
    /// map to a `ClothingCategory` (i.e., the model is "uncertain" what
    /// kind of item it found). The base `defaultConfidenceThreshold`
    /// of 0.5 admits enough rug/wallpaper/non-clothing patterns that
    /// they leak into the grid; raising the bar to 0.85 for unknown
    /// classes drops most of those without affecting confidently-classed
    /// real garments.
    static let ambiguousClassConfidenceFloor: Float = 0.85

    /// Drop any raw detection below this objectness score before the
    /// per-category argmax. Conservative on purpose — false positives
    /// are worse than false negatives for the multi-pick UX.
    static let defaultConfidenceThreshold: Float = 0.5

    /// IoU threshold for Non-Max Suppression over overlapping proposals
    /// of the same class. DETR architectures don't technically need NMS
    /// (queries are already unique-ish) but we still run one defensive
    /// pass because heavy overlap is worse than a few dropped items.
    static let defaultNMSThreshold: Float = 0.5

    /// Fashionpedia main-class labels in the exact order the training
    /// notebook's `FASHIONPEDIA_CLASSES` list emits them — the trained
    /// model's argmax index maps to this array one-to-one.
    ///
    /// **Single source of truth.** `notebooks/training/2026-04-multi-garment.ipynb`
    /// cell 6 carries the matching Python list. Regenerate both from the
    /// same source when the Fashionpedia schema evolves.
    ///
    /// **Drift guard.** `MultiGarmentProposalServiceFashionpediaLabelsTests`
    /// asserts every label here either maps to a `ClothingCategory` or
    /// is in a known-exclusion set — so adding a label without also
    /// updating `ClothingCategory.fromFashionpediaClass` is a build-time
    /// failure, not a silent "every proposal is uncategorised at runtime."
    ///
    /// **Why 33 entries but `pred_logits` has 91 slots.** rfdetr 1.4
    /// reinitialises the classifier head to the pretrained COCO layout
    /// (91 slots) during `Model.train`, regardless of the `num_classes`
    /// we pass at construction — see `notebooks/training/scripts/export_coreml.py`
    /// (the "rfdetr 1.4 quirk" comment). Our fitted Fashionpedia logits
    /// occupy slots 0–32; slots 33–90 are unfitted COCO weights.
    /// `labelForIndex` returns `"class_N"` for anything >= 33 so those
    /// proposals never silently claim a category.
    static let fashionpediaLabels: [String] = [
        "shirt_blouse", "top_t-shirt_sweatshirt", "sweater", "cardigan",
        "jacket", "vest", "coat", "cape",
        "pants", "shorts", "skirt", "tights_stockings",
        "dress", "jumpsuit",
        "shoe", "boot", "sandal", "sock", "leg_warmer",
        "glasses", "hat", "headband", "scarf", "tie",
        "bag_wallet", "belt",
        "glove", "watch", "ring", "bracelet", "earring", "necklace",
        "umbrella"
    ]

    /// Fashionpedia labels that are deliberately not surfaced in v1's
    /// wardrobe UI (no place to put a sock in a 6-case enum). Drift-guard
    /// tests check this set is consistent with `fromFashionpediaClass`
    /// returning `nil` for these exact labels.
    static let fashionpediaExcludedLabels: Set<String> = [
        "sock", "leg_warmer", "umbrella"
    ]

    /// Working-image cap for proposal cutouts.
    ///
    /// Source photos at iPhone capture resolution (e.g. 4032×3024)
    /// decoded to bitmap consume ~48 MB; a multi-garment capture with 4
    /// detected items therefore holds ~250 MB of UIImage data plus the
    /// model in RAM, which has been observed to trigger watchdog
    /// terminations on devices with 4-6 GB total RAM (e.g. iPhone 15
    /// Plus / iOS 26.4 — see Sentry WARDROBE-REDO-IOS-1).
    ///
    /// Downscaling the source to ≤1280 px on the longest side before
    /// cropping cutouts cuts per-image RAM by ~6× while staying well
    /// above the grid view's display resolution. The model still gets
    /// the same fidelity it always did because its own preprocess step
    /// resizes to 1024×1024 before inference — going through the
    /// downscaled image is a near-no-op there.
    static let workingImageMaxDimension: CGFloat = 1280

    private let modelLoader: @Sendable () -> MLModel?
    private let confidenceThreshold: Float
    private let nmsThreshold: Float
    private let attributeClassifier: AttributeClassifying?
    private let logger = Logger(subsystem: "com.wardroberedo", category: "MultiGarment")

    /// Static logger for capture-pipeline telemetry emitted from the
    /// static helpers (`makeProposal`, NMS, dedup). Same subsystem as the
    /// instance logger so dogfood log captures show the full pipeline
    /// timeline under one filter. See `MultiGarmentSmokeTest` for the
    /// existing precedent of a static logger on a service type.
    fileprivate static let staticLogger = Logger(subsystem: "com.wardroberedo", category: "MultiGarment")

    /// One-shot model load. `NSLock`-gated lazy just like SAM2Extractor.
    private let modelLock = NSLock()
    private var loadedModel: MLModel?
    private var modelLoadAttempted = false

    /// Token returned by `NotificationCenter.addObserver(forName:…)`
    /// for the memory-warning observer. Stored so `deinit` can remove
    /// it deterministically — block-form observers don't accept the
    /// older `removeObserver(self)` pattern.
    private var memoryWarningObserver: NSObjectProtocol?

    init(
        modelLoader: (@Sendable () -> MLModel?)? = nil,
        confidenceThreshold: Float = MultiGarmentProposalService.defaultConfidenceThreshold,
        nmsThreshold: Float = MultiGarmentProposalService.defaultNMSThreshold,
        attributeClassifier: AttributeClassifying? = nil
    ) {
        self.modelLoader = modelLoader ?? MultiGarmentProposalService.defaultModelLoader
        self.confidenceThreshold = confidenceThreshold
        self.nmsThreshold = nmsThreshold
        self.attributeClassifier = attributeClassifier

        // Free the loaded model when iOS warns we're tight on RAM. The
        // next inference call reloads it — model load is ~50ms and
        // acceptable as the cost of avoiding a watchdog termination
        // mid-capture.
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

    /// Drops the loaded `MLModel` so the next call has to reload it.
    /// Wired to `UIApplication.didReceiveMemoryWarningNotification`
    /// in `init`, also exposed as `internal` so tests can drive the
    /// reload-after-evict path without posting fake notifications.
    func evictLoadedModel() {
        modelLock.lock()
        defer { modelLock.unlock() }
        loadedModel = nil
        modelLoadAttempted = false
    }

    // MARK: - Public API

    func detectProposals(in image: UIImage) async throws -> [MaskProposal] {
        logger.info("detectProposals.start size=\(image.size.width, privacy: .public)x\(image.size.height, privacy: .public)")
        let start = Date()

        guard let model = loadModelIfAvailable() else {
            let path = Self.defaultModelURL()?.lastPathComponent
            logger.error("detectProposals.modelLoadFailed modelPath=\(path ?? "nil", privacy: .public)")
            await recordFailure(start: start)
            throw MultiGarmentError.modelLoadFailed(
                reason: "Core ML model could not be loaded (missing from bundle or compile failed)",
                modelPath: path
            )
        }

        // Orient + downscale in a single autoreleasepool so the
        // full-resolution `normalized` UIImage is released the moment
        // the smaller `working` copy exists. Without this, ARC could
        // hold both for the lifetime of the function — that's the
        // 50+ MB peak that contributed to watchdog kills on
        // memory-tight devices.
        let working: UIImage = autoreleasepool {
            let normalized = OrientationUtil.normalized(image)
            return Self.downscaledForCutouts(normalized)
        }

        guard let pixelBuffer = Self.preprocessedPixelBuffer(for: working, model: model) else {
            logger.error("detectProposals.preprocessingFailed")
            await recordFailure(start: start)
            throw MultiGarmentError.preprocessingFailed(
                reason: "Could not convert source image to model input buffer"
            )
        }

        let inputName = Self.imageInputName(for: model) ?? "image"
        let provider: MLFeatureProvider
        do {
            provider = try MLDictionaryFeatureProvider(dictionary: [
                inputName: MLFeatureValue(pixelBuffer: pixelBuffer)
            ])
        } catch {
            logger.error("detectProposals.providerFailed \(error.localizedDescription, privacy: .public)")
            await recordFailure(start: start)
            throw MultiGarmentError.preprocessingFailed(reason: error.localizedDescription)
        }

        let prediction: MLFeatureProvider
        do {
            prediction = try await model.prediction(from: provider)
        } catch {
            logger.error("detectProposals.inferenceFailed \(error.localizedDescription, privacy: .public)")
            await recordFailure(start: start)
            throw MultiGarmentError.inferenceFailed(reason: error.localizedDescription)
        }

        let rawDetections = Self.decodeDETROutput(from: prediction)
        // Two-stage threshold: confidently-classed detections clear
        // the lower bar; ambiguous-class detections (classes that don't
        // map to a ClothingCategory — typically the model finding
        // fabric-like patterns in non-clothing) need the higher
        // ambiguous-class floor. This is what drops rugs / wallpaper
        // patterns / phones-in-mirror without touching real garments.
        let thresholded = rawDetections.filter { raw in
            guard raw.score >= confidenceThreshold else { return false }
            if ClothingCategory.fromFashionpediaClass(raw.rawClass) == nil {
                return raw.score >= Self.ambiguousClassConfidenceFloor
            }
            return true
        }

        guard !thresholded.isEmpty else {
            logger.notice("detectProposals.noValidPredictions raw=\(rawDetections.count, privacy: .public) threshold=\(self.confidenceThreshold, privacy: .public)")
            // Empty array — NOT an error, just a photo with no clothing.
            // Callers check `isEmpty` and fall through to the single-item
            // flow automatically.
            await recordSuccess(start: start, proposals: [])
            return []
        }

        // Per-class NMS — the old single-pass NMS was class-agnostic
        // and only suppressed when IoU ≥ threshold globally. Two shoe
        // detections with low IoU (left foot + right foot) survived,
        // so the user saw both shoes of the same pair as separate
        // proposals. Grouping by class first means we can then run a
        // class-specific merge for footwear.
        let byClass = Dictionary(grouping: thresholded, by: \.rawClass)
        var suppressed: [RawDetection] = byClass.values.flatMap { perClass in
            Self.applyNMS(perClass, threshold: nmsThreshold)
        }
        // Smart shoe-pair merge — collapse two `.shoe`-class
        // detections into one when they look like a left/right pair
        // (vertically aligned, similar size, horizontally adjacent).
        // The user explicitly opted into this over a blanket cap so
        // legitimate two-pair photos (rare) keep both. See the
        // `looksLikeShoePair` doc-comment for the exact heuristic.
        suppressed = Self.collapseShoePairs(suppressed)

        let capped = Array(suppressed
            .sorted { $0.score > $1.score }
            .prefix(Self.maxProposals))

        let baseProposals = capped.compactMap { raw -> MaskProposal? in
            Self.makeProposal(from: raw, sourceImage: working)
        }

        // Per-proposal attribute enrichment (Phase 6 of the
        // auto-attribute-detection plan). Runs sequentially so the
        // attribute model doesn't contend with the RF-DETR inference
        // that just finished — both use the Neural Engine. Sequential
        // over ≤8 proposals at ~20ms each stays comfortably inside the
        // capture-to-details transition budget.
        let proposals: [MaskProposal]
        if let classifier = attributeClassifier {
            var enriched: [MaskProposal] = []
            enriched.reserveCapacity(baseProposals.count)
            for proposal in baseProposals {
                let next = await Self.enriched(
                    proposal,
                    with: classifier,
                    logger: logger
                )
                enriched.append(next)
            }
            proposals = enriched
        } else {
            // No classifier injected — apply rules-engine pre-fill
            // using whatever category + subcategory we already have
            // from the detection head. Texture is left nil, which the
            // rules engine tolerates (subcategory-level rules still
            // narrow the season / occasion sets).
            proposals = baseProposals.map { Self.enrichedWithRulesOnly($0, logger: logger) }
        }

        logger.info("detectProposals.success count=\(proposals.count, privacy: .public) topScore=\(proposals.first?.detectionScore ?? 0, privacy: .public)")
        await recordSuccess(start: start, proposals: proposals)
        return proposals
    }

    // MARK: - Diagnostics recording

    private func recordSuccess(start: Date, proposals: [MaskProposal]) async {
        let latencyMs = Date().timeIntervalSince(start) * 1000
        await MLDiagnosticsStore.shared.record(
            latencyMs: latencyMs,
            proposals: proposals,
            modelName: Self.bundledModelName
        )
    }

    private func recordFailure(start: Date) async {
        let latencyMs = Date().timeIntervalSince(start) * 1000
        await MLDiagnosticsStore.shared.recordFailure(
            latencyMs: latencyMs,
            modelName: Self.bundledModelName
        )
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
            forResource: MultiGarmentProposalService.bundledModelName,
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

    /// Convert `image` into the `CVPixelBuffer` shape the model expects.
    /// Falls back to 1024×1024 if the model doesn't declare a fixed
    /// image constraint.
    static func preprocessedPixelBuffer(for image: UIImage, model: MLModel) -> CVPixelBuffer? {
        guard let cg = image.cgImage else { return nil }
        let inputs = model.modelDescription.inputDescriptionsByName
        let key = imageInputName(for: model)
        let constraint = key.flatMap { inputs[$0]?.imageConstraint }
        let width = constraint?.pixelsWide ?? 1024
        let height = constraint?.pixelsHigh ?? 1024
        return SAM2Extractor.pixelBuffer(from: cg, width: width, height: height)
    }

    static func imageInputName(for model: MLModel) -> String? {
        let inputs = model.modelDescription.inputDescriptionsByName
        let preferred = ["image", "input_image", "image_input", "pixel_values", "images"]
        if let hit = preferred.first(where: { inputs[$0]?.type == .image }) {
            return hit
        }
        return inputs.first(where: { $0.value.type == .image })?.key
    }

    // MARK: - DETR output decode

    /// Intermediate representation between the raw tensors and the
    /// user-facing `MaskProposal`. Kept internal so post-processing
    /// helpers (NMS, class map, mask composite) can be pure functions.
    struct RawDetection {
        let boundingBox: CGRect      // normalized [0,1] origin top-left
        let score: Float             // 0…1 objectness
        let rawClass: String         // Fashionpedia label or "unknown"
        let mask: CVPixelBuffer?     // source-res reconstruction (nil when mask head absent)
    }

    /// Best-effort decode of DETR-style outputs. RF-DETR's export names
    /// haven't fully stabilised in coremltools, so we probe a handful of
    /// likely names and decode the first matching set.
    ///
    /// Split out so tests can exercise post-processing by constructing
    /// `RawDetection` arrays directly without needing a live MLModel.
    static func decodeDETROutput(from prediction: MLFeatureProvider) -> [RawDetection] {
        // Preferred output names (RF-DETR 1.4 segmentation export).
        let boxKeys = ["pred_boxes", "boxes", "detection_boxes"]
        let scoreKeys = ["pred_scores", "scores", "detection_scores", "validity"]
        let classKeys = ["pred_classes", "classes", "class_ids", "detection_classes"]
        let logitKeys = ["pred_logits", "class_logits", "logits"]
        let maskKeys = ["pred_masks", "masks", "mask_logits", "segmentation"]

        guard let boxes = multiArray(for: boxKeys, in: prediction) else { return [] }

        let scores = multiArray(for: scoreKeys, in: prediction)
        let logits = multiArray(for: logitKeys, in: prediction)
        let classes = multiArray(for: classKeys, in: prediction)
        let masks = multiArray(for: maskKeys, in: prediction)
        // The segmentation head emits a per-query logits tensor of shape
        // `[1, num_queries, mask_H, mask_W]` (RFDETR-Seg-Small Fashionpedia
        // export verified via `xcrun coremlc metadata`: `pred_masks`
        // Float32 [1, 100, 192, 192]). We decode each query's slice into a
        // CVPixelBuffer at native model resolution and let
        // `compositeMaskedItem` scale it up to source extent.

        // Resolve how many queries the model emitted.
        let queryCount = boxes.shape[safe: 1]?.intValue ?? 0
        guard queryCount > 0 else { return [] }

        // Decode the mask tensor once into a flat buffer so we don't re-read
        // the boxed `MLMultiArray` accessor 36 K times per query. The decoder
        // returns nil on shape mismatch / nil tensor — every per-query
        // `decodeMask` call then falls through to `mask: nil` and the
        // existing rect-crop fallback in `compositeMaskedItem`. No new crash
        // paths introduced.
        let maskContext = masks.flatMap(MaskTensorContext.init(masks:))

        var result: [RawDetection] = []
        result.reserveCapacity(queryCount)

        for q in 0 ..< queryCount {
            let bbox = decodeBoundingBox(boxes, queryIndex: q)
            let rawScore = decodeScore(scores: scores, logits: logits, queryIndex: q)
            let rawClass = decodeClassLabel(classes: classes, logits: logits, queryIndex: q)
            let mask = maskContext.flatMap { ctx in
                decodeMask(from: ctx, queryIndex: q)
            }
            result.append(RawDetection(
                boundingBox: bbox,
                score: rawScore,
                rawClass: rawClass,
                mask: mask
            ))
        }
        return result
    }

    // MARK: - Mask decode

    /// Pre-flattened, sigmoided, thresholded mask tensor — built once per
    /// inference so per-query `decodeMask` calls are an O(H·W) memcpy
    /// rather than re-reading the boxed `MLMultiArray` accessor.
    ///
    /// The flattening + sigmoid + threshold runs once for the whole tensor
    /// (Q × H × W elements) regardless of how many queries we ultimately
    /// keep. This is fine: at the model's native size (100 × 192 × 192 ≈
    /// 3.7 M floats) the work is well below 10 ms on Neural Engine
    /// post-processing budget.
    struct MaskTensorContext {
        let queryCount: Int
        let height: Int
        let width: Int
        /// Binary [0, 1] values, length `queryCount * height * width`,
        /// row-major within each query slice. Stored as `UInt8` so the
        /// downstream `CVPixelBuffer` write is a direct memcpy.
        let binary: [UInt8]

        /// Build a `MaskTensorContext` from the raw `MLMultiArray`.
        /// Returns nil on shape mismatch — caller falls through to the
        /// existing nil-mask path so the rect-crop fallback always runs.
        init?(masks: MLMultiArray) {
            // Expect [1, Q, H, W]. Anything else means the export changed
            // shape and the safe move is to disable mask decode rather
            // than risk index-out-of-bounds.
            let shape = masks.shape.map(\.intValue)
            guard shape.count == 4, shape[0] == 1 else {
                staticLogger.warning(
                    "decodeMask.shapeMismatch shape=\(shape, privacy: .public)"
                )
                return nil
            }
            self.queryCount = shape[1]
            self.height = shape[2]
            self.width = shape[3]
            let total = queryCount * height * width
            guard total > 0 else {
                staticLogger.warning(
                    "decodeMask.emptyTensor shape=\(shape, privacy: .public)"
                )
                return nil
            }

            // Read once into a Float buffer. `MLMultiArray.dataType`
            // determines the underlying layout; the shipped model exports
            // Float32 (verified via `xcrun coremlc metadata`) but we
            // tolerate Float16 too in case a future export step quantises.
            var flat = [UInt8](repeating: 0, count: total)
            switch masks.dataType {
            case .float32:
                masks.withUnsafeBufferPointer(ofType: Float32.self) { buffer in
                    Self.thresholdAndCopy(buffer: buffer, total: total, into: &flat)
                }
            case .float16:
                // Float16 isn't a stand-alone Swift type; coerce via
                // `withUnsafeBytes` and read 2-byte chunks. Use the
                // higher-precision Float promotion path so the sigmoid
                // call site is identical to the Float32 case. Rare in
                // practice but cheap to guard against.
                masks.withUnsafeBytes { rawPtr in
                    guard let base = rawPtr.baseAddress else { return }
                    let elementCount = rawPtr.count / 2
                    let count = min(elementCount, total)
                    for i in 0..<count {
                        let bits = base.load(fromByteOffset: i * 2, as: UInt16.self)
                        let value = Float(Self.float32FromFloat16Bits(bits))
                        let prob = 1.0 / (1.0 + expf(-value))
                        flat[i] = prob > 0.5 ? 255 : 0
                    }
                }
            case .float64:
                masks.withUnsafeBufferPointer(ofType: Double.self) { buffer in
                    let count = min(buffer.count, total)
                    for i in 0..<count {
                        let prob = 1.0 / (1.0 + exp(-buffer[i]))
                        flat[i] = prob > 0.5 ? 255 : 0
                    }
                }
            default:
                staticLogger.warning(
                    "decodeMask.unsupportedDtype dtype=\(String(describing: masks.dataType), privacy: .public)"
                )
                return nil
            }
            self.binary = flat
        }

        private static func thresholdAndCopy(
            buffer: UnsafeBufferPointer<Float32>,
            total: Int,
            into flat: inout [UInt8]
        ) {
            let count = min(buffer.count, total)
            for i in 0..<count {
                let prob = 1.0 / (1.0 + expf(-buffer[i]))
                flat[i] = prob > 0.5 ? 255 : 0
            }
        }

        /// Bit-pattern conversion for Float16 → Float32 without bringing
        /// in a SIMD dependency. Following IEEE 754 binary16: 1 sign
        /// bit, 5 exponent bits, 10 fraction bits.
        fileprivate static func float32FromFloat16Bits(_ bits: UInt16) -> Float {
            let sign = UInt32(bits & 0x8000) << 16
            let exp = UInt32((bits >> 10) & 0x1F)
            let frac = UInt32(bits & 0x03FF)
            let f32Bits: UInt32
            if exp == 0 {
                if frac == 0 {
                    f32Bits = sign
                } else {
                    // Subnormal — normalise.
                    var e: Int32 = -1
                    var m: UInt32 = frac
                    repeat {
                        e += 1
                        m <<= 1
                    } while (m & 0x0400) == 0
                    let normExp = UInt32(127 - 15 - e)
                    let normFrac = (m & 0x03FF) << 13
                    f32Bits = sign | (normExp << 23) | normFrac
                }
            } else if exp == 0x1F {
                // Inf / NaN.
                f32Bits = sign | 0x7F800000 | (frac << 13)
            } else {
                let f32Exp = (exp + (127 - 15)) << 23
                f32Bits = sign | f32Exp | (frac << 13)
            }
            return Float(bitPattern: f32Bits)
        }
    }

    /// Extract a single per-instance mask from a pre-decoded
    /// `MaskTensorContext` and return it as a binary `CVPixelBuffer` at
    /// the model's native mask resolution. `compositeMaskedItem`
    /// upscales it to source extent via `CGAffineTransform` (existing
    /// path — no new dependency).
    ///
    /// Returns nil on out-of-range query index or pixel-buffer creation
    /// failure. Caller's `RawDetection.mask` becomes nil on failure and
    /// `compositeMaskedItem`'s rect-crop fallback runs unchanged. This
    /// is the safety net the planning brief asks for: no new crash paths.
    static func decodeMask(
        from ctx: MaskTensorContext,
        queryIndex q: Int
    ) -> CVPixelBuffer? {
        guard q >= 0, q < ctx.queryCount else {
            staticLogger.warning(
                "decodeMask.queryOutOfRange index=\(q, privacy: .public) total=\(ctx.queryCount, privacy: .public)"
            )
            return nil
        }
        let stride = ctx.height * ctx.width
        let base = q * stride
        let slice = ctx.binary[base..<(base + stride)]

        guard let buffer = makeBinaryMaskBuffer(
            from: Array(slice),
            width: ctx.width,
            height: ctx.height
        ) else {
            staticLogger.warning(
                "decodeMask.bufferCreateFailed queryIndex=\(q, privacy: .public)"
            )
            return nil
        }
        staticLogger.info(
            "decodeMask.success queryIndex=\(q, privacy: .public) shape=\(ctx.height, privacy: .public)x\(ctx.width, privacy: .public)"
        )
        return buffer
    }

    /// Wrap a row-major `UInt8` slice (0 or 255) into a
    /// `kCVPixelFormatType_OneComponent8` `CVPixelBuffer`. This is the
    /// format `CIImage(cvPixelBuffer:)` reads as a single-channel mask
    /// for use with `CIBlendWithMask`, matching the existing
    /// `compositeMaskedItem` consumer.
    fileprivate static func makeBinaryMaskBuffer(
        from values: [UInt8],
        width: Int,
        height: Int
    ) -> CVPixelBuffer? {
        guard width > 0, height > 0, values.count == width * height else {
            staticLogger.warning(
                "makeBinaryMaskBuffer.invalidShape width=\(width, privacy: .public) height=\(height, privacy: .public) valuesCount=\(values.count, privacy: .public)"
            )
            return nil
        }
        var output: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_OneComponent8,
            nil,
            &output
        )
        guard status == kCVReturnSuccess, let pb = output else {
            // Build-7 hardening: surface allocation failures from the
            // field. `CVPixelBufferCreate` can return
            // `kCVReturnAllocationFailed` (-6660) on memory-constrained
            // devices; without this log the silent-nil return looks
            // identical to a malformed-input rejection upstream, masking
            // a real OOM signal.
            staticLogger.warning(
                "makeBinaryMaskBuffer.cvCreateFailed status=\(status, privacy: .public) width=\(width, privacy: .public) height=\(height, privacy: .public)"
            )
            return nil
        }

        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pb)
        guard let baseAddr = CVPixelBufferGetBaseAddress(pb) else {
            staticLogger.warning(
                "makeBinaryMaskBuffer.lockFailed width=\(width, privacy: .public) height=\(height, privacy: .public)"
            )
            return nil
        }
        let dst = baseAddr.assumingMemoryBound(to: UInt8.self)
        // Honour bytesPerRow — it may include row padding so a flat
        // memcpy of `width * height` bytes would scribble over padding
        // and leave subsequent rows offset.
        for y in 0..<height {
            let srcOffset = y * width
            let dstRow = dst.advanced(by: y * bytesPerRow)
            values.withUnsafeBufferPointer { srcBuf in
                guard let srcBase = srcBuf.baseAddress else { return }
                dstRow.update(from: srcBase.advanced(by: srcOffset), count: width)
            }
        }
        return pb
    }

    /// Decode one row of a `[1, Q, 4]` cxcywh tensor. DETR conventionally
    /// emits normalized cxcywh; we convert to origin-top-left `CGRect`.
    static func decodeBoundingBox(_ array: MLMultiArray, queryIndex q: Int) -> CGRect {
        let cx = array[safe: [0, q, 0]] ?? 0
        let cy = array[safe: [0, q, 1]] ?? 0
        let w = array[safe: [0, q, 2]] ?? 0
        let h = array[safe: [0, q, 3]] ?? 0

        let x = max(0, cx - w / 2)
        let y = max(0, cy - h / 2)
        return CGRect(
            x: CGFloat(x),
            y: CGFloat(y),
            width: CGFloat(min(1, w)),
            height: CGFloat(min(1, h))
        )
    }

    /// Prefer an explicit per-query score tensor; fall back to max-softmax
    /// over class logits.
    static func decodeScore(
        scores: MLMultiArray?,
        logits: MLMultiArray?,
        queryIndex q: Int
    ) -> Float {
        if let scores, let score = scores[safe: [0, q]] {
            // Raw scores may already be sigmoided or not. If > 1 we pass
            // through a sigmoid; otherwise accept as-is.
            return score > 1 ? 1 / (1 + expf(-score)) : score
        }
        if let logits {
            let classCount = logits.shape[safe: 2]?.intValue ?? 0
            guard classCount > 0 else { return 0 }
            var maxVal = -Float.greatestFiniteMagnitude
            for c in 0 ..< classCount {
                let v = logits[safe: [0, q, c]] ?? 0
                if v > maxVal { maxVal = v }
            }
            return 1 / (1 + expf(-maxVal))
        }
        return 0
    }

    /// Pull the argmax class name, mapping the model's integer class index
    /// to the Fashionpedia label string via `fashionpediaLabels`. When the
    /// index falls outside the known label set (future schema extension
    /// or a buggy export) we fall back to `"class_N"` so the raw number
    /// still shows up in `MaskProposal.modelClassRaw` for debugging —
    /// but `ClothingCategory.fromFashionpediaClass` will return `nil`
    /// for those so they never silently claim a category they aren't.
    static func decodeClassLabel(
        classes: MLMultiArray?,
        logits: MLMultiArray?,
        queryIndex q: Int
    ) -> String {
        if let classes, let idx = classes[safe: [0, q]] {
            return labelForIndex(Int(idx))
        }
        if let logits {
            let classCount = logits.shape[safe: 2]?.intValue ?? 0
            var bestIdx = 0
            var bestVal = -Float.greatestFiniteMagnitude
            for c in 0 ..< classCount {
                let v = logits[safe: [0, q, c]] ?? 0
                if v > bestVal {
                    bestVal = v
                    bestIdx = c
                }
            }
            return labelForIndex(bestIdx)
        }
        return "unknown"
    }

    /// Look up a Fashionpedia label by model class index. Exposed as
    /// `internal` so tests can assert index ↔ label round-trips without
    /// going through a full MLMultiArray synthesis.
    static func labelForIndex(_ index: Int) -> String {
        guard index >= 0, index < fashionpediaLabels.count else {
            classIndexLogger.debug(
                "pred_logits argmax=\(index, privacy: .public) outside fitted range [0,\(fashionpediaLabels.count - 1, privacy: .public)] — unfitted COCO slot"
            )
            return "class_\(index)"
        }
        return fashionpediaLabels[index]
    }

    private static let classIndexLogger = Logger(
        subsystem: "com.wardroberedo",
        category: "MultiGarmentClassIndex"
    )

    private static func multiArray(
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

    // MARK: - NMS

    /// Axis-aligned Non-Max Suppression over raw detections. Keeps the
    /// highest-scoring proposal per overlapping cluster.
    static func applyNMS(_ detections: [RawDetection], threshold: Float) -> [RawDetection] {
        let sorted = detections.sorted { $0.score > $1.score }
        var keep: [RawDetection] = []
        keep.reserveCapacity(sorted.count)

        for candidate in sorted {
            let overlap = keep.contains { existing in
                iou(candidate.boundingBox, existing.boundingBox) >= CGFloat(threshold)
            }
            if !overlap {
                keep.append(candidate)
            }
        }
        return keep
    }

    static func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let intersection = a.intersection(b)
        guard !intersection.isNull, intersection.area > 0 else { return 0 }
        let union = a.area + b.area - intersection.area
        return intersection.area / union
    }

    // MARK: - Smart shoe-pair merge

    /// Heuristic for "these two shoe boxes look like the left and right
    /// shoe of the same pair." Tuned for selfie / full-body captures
    /// where both feet are visible side-by-side. Returns false when the
    /// two boxes are stacked vertically, are very different sizes, or
    /// are too far apart horizontally — those configurations are more
    /// likely to be two distinct pairs of shoes laid out in a flat-lay.
    ///
    /// Rules (all must hold):
    ///   * Vertical mid-points within 10% of each other (same band)
    ///   * Width and height ratios both < 1.5× (similar size)
    ///   * Horizontal gap between the inner edges < average shoe width
    ///     (they're touching or close to touching, not "across the room")
    ///
    /// Both bounding boxes are expected in normalized [0,1] image
    /// coordinates — same convention the rest of post-processing uses.
    /// `static` so unit tests can verify against synthetic CGRects.
    static func looksLikeShoePair(_ a: CGRect, _ b: CGRect) -> Bool {
        let yDelta = abs(a.midY - b.midY)
        guard yDelta < 0.10 else { return false }

        let widthRatio = max(a.width, b.width) / max(min(a.width, b.width), 0.0001)
        guard widthRatio < 1.5 else { return false }
        let heightRatio = max(a.height, b.height) / max(min(a.height, b.height), 0.0001)
        guard heightRatio < 1.5 else { return false }

        let (left, right) = a.minX < b.minX ? (a, b) : (b, a)
        let gap = right.minX - left.maxX
        let avgWidth = (left.width + right.width) / 2
        return gap < avgWidth
    }

    /// True when two shoe-class detections look like the same physical
    /// foot photographed from slightly different angles or zooms — i.e.
    /// proposal-level redundancy from the model emitting near-duplicate
    /// queries.
    ///
    /// **Why proximity, not IoU containment.** The previous 70%-IoU
    /// containment heuristic missed real-world cases. Supabase production
    /// data (build-4 batch) confirmed two shoe detections of the same
    /// foot at slightly different zooms produced bounding boxes that
    /// don't actually overlap enough to trip a containment check, but
    /// whose centroids land within a hand-width of each other. The
    /// proximity check catches those reliably.
    ///
    /// **Tuning.**
    ///   * dx < 0.18 — same physical foot photographed across the
    ///     image plane lands within 18% horizontal-image-width tolerance.
    ///     Two genuinely different feet (left + right) of a wearer
    ///     typically land 5-15% apart in horizontal centroid.
    ///   * dy < 0.10 — same foot stays inside a 10%-image-height band.
    ///     Front-foot vs back-foot in a walking pose can spread further
    ///     vertically; left + right of a standing pose stay tight.
    ///
    /// Returns false for the "left foot vs right foot of the same pair"
    /// case (often dx ≈ 0.10-0.15 — borderline). That's intentional:
    /// `collapseShoePairs` runs `looksLikeShoePair` afterward to catch
    /// the legitimate left+right collapse. The proximity check is
    /// strictly tighter — only catches near-duplicates.
    ///
    /// Both bounding boxes in normalized [0,1] image coordinates.
    static func looksLikeSameShoeDetection(_ a: CGRect, _ b: CGRect) -> Bool {
        let centroidA = CGPoint(x: a.midX, y: a.midY)
        let centroidB = CGPoint(x: b.midX, y: b.midY)
        let dx = abs(centroidA.x - centroidB.x)
        let dy = abs(centroidA.y - centroidB.y)
        // Real-world shoe pair detections: same physical foot photographed
        // at different angles/zooms produces detections with centroids
        // close horizontally and vertically (in normalized image coords).
        return dx < 0.18 && dy < 0.10
    }

    /// Reduces same-class shoe detections that look like a pair down
    /// to one box, keeping the higher-scored side. For 3+ shoe boxes,
    /// iteratively prunes near-duplicate redundancies (same physical
    /// foot at different angles/zooms) before the pair check, then caps
    /// the remaining shoes at 2 per photo (left + right of one pair —
    /// rest are model noise, not legitimate distinct items).
    ///
    /// Treats every shoe-family Fashionpedia label (`shoe`, `boot`,
    /// `sandal`) as the same class for pair purposes — left and right
    /// are mirror images regardless of subtype.
    static func collapseShoePairs(_ detections: [RawDetection]) -> [RawDetection] {
        let shoeLabels: Set<String> = ["shoe", "boot", "sandal"]
        var nonShoes: [RawDetection] = []
        var shoes: [RawDetection] = []
        for d in detections {
            if shoeLabels.contains(d.rawClass) {
                shoes.append(d)
            } else {
                nonShoes.append(d)
            }
        }

        // Iteratively drop redundant shoe boxes (proximity-based — same
        // physical foot at different angles). Runs before the pair check
        // so a near-duplicate pair doesn't slip past as a "pair."
        shoes = pruneShoeRedundancies(shoes)

        // Build 44 — pair detection BEFORE the hard cap. The earlier
        // algorithm capped at 2 highest-confidence first, which broke
        // a legitimate same-class pair (e.g. left+right boot) when a
        // third shoe-family detection happened to score higher than
        // one half of the pair. Concretely: 2 boots (scores 0.82 + 0.75)
        // plus 1 sneaker (score 0.78) used to collapse to "boot 0.82 +
        // sneaker 0.78" and the boot pair was destroyed.
        //
        // New algorithm — greedy per-class pair walk:
        //   1. Sort all shoes descending by score.
        //   2. For each unpaired shoe, look for the highest-scoring
        //      unpaired same-rawClass partner that geometrically
        //      satisfies `looksLikeShoePair`. If found, collapse
        //      both into the higher-scored one.
        //   3. After the walk, apply the hard cap.
        //
        // Same-rawClass requirement prevents a boot+sneaker false-pair
        // collapse: the legitimate pair semantics only hold within a
        // single Fashionpedia label.
        shoes = collapseSameClassPairs(shoes)

        // Hard cap at 2 shoe items per source photo (left + right foot,
        // OR two distinct shoes from two different physical pairs after
        // same-class pair-collapse). Real-world wardrobe captures don't
        // legitimately contain 3+ distinct shoes — anything over 2
        // after pair collapse is model noise. Keep the 2 highest-
        // confidence survivors.
        if shoes.count > 2 {
            shoes = Array(shoes.sorted { $0.score > $1.score }.prefix(2))
        }

        return nonShoes + shoes
    }

    /// Greedy walk over `shoes` looking for same-`rawClass` pairs that
    /// satisfy `looksLikeShoePair`. The higher-scored member of each
    /// confirmed pair wins; the partner is dropped. Used by
    /// `collapseShoePairs` so the post-walk hard cap operates on a
    /// list where each remaining detection is either a confirmed
    /// single shoe or the representative of a confirmed pair.
    private static func collapseSameClassPairs(_ shoes: [RawDetection]) -> [RawDetection] {
        guard shoes.count >= 2 else { return shoes }
        let sorted = shoes.sorted { $0.score > $1.score }
        var consumed = Set<Int>()
        var result: [RawDetection] = []
        for i in sorted.indices {
            if consumed.contains(i) { continue }
            let anchor = sorted[i]
            var partnerIndex: Int?
            for j in (i + 1)..<sorted.count {
                if consumed.contains(j) { continue }
                let candidate = sorted[j]
                guard candidate.rawClass == anchor.rawClass else { continue }
                if looksLikeShoePair(anchor.boundingBox, candidate.boundingBox) {
                    partnerIndex = j
                    break
                }
            }
            if let j = partnerIndex {
                // Pair confirmed — anchor wins (higher score per the
                // pre-sort), partner is consumed.
                consumed.insert(j)
            }
            consumed.insert(i)
            result.append(anchor)
        }
        return result
    }

    /// Iteratively drops the lower-scored member of any shoe-class
    /// detection pair where the two boxes' centroids are close enough
    /// to be the same physical foot (see `looksLikeSameShoeDetection`).
    /// Stops when no near-duplicate pair remains. Ordering by score
    /// descending makes the survivor deterministic.
    private static func pruneShoeRedundancies(_ shoes: [RawDetection]) -> [RawDetection] {
        guard shoes.count > 1 else { return shoes }

        var remaining = shoes.sorted { $0.score > $1.score }
        var changed = true
        while changed {
            changed = false
            for i in 0..<remaining.count {
                var didCollapse = false
                for j in (i + 1)..<remaining.count {
                    if looksLikeSameShoeDetection(
                        remaining[i].boundingBox,
                        remaining[j].boundingBox
                    ) {
                        // `remaining[i]` has the higher score (sorted
                        // descending) — drop the lower-scored copy.
                        // The `while changed` re-entry restarts iteration
                        // from the top with the shrunken array, so we
                        // only need to break the inner loop here.
                        remaining.remove(at: j)
                        changed = true
                        didCollapse = true
                        break
                    }
                }
                if didCollapse { break }
            }
        }
        return remaining
    }

    // MARK: - Proposal construction

    static func makeProposal(
        from raw: RawDetection,
        sourceImage: UIImage
    ) -> MaskProposal? {
        // Composite the per-instance segmentation mask onto the source
        // image and crop to the bbox. When the mask isn't available
        // (model failure / segmentation head not decoded), this falls
        // back to a plain rect crop — still a usable image, just lacks
        // the transparent background.
        guard let cropped = compositeMaskedItem(
            sourceImage: sourceImage,
            mask: raw.mask,
            bbox: raw.boundingBox
        ) else {
            staticLogger.notice("makeProposal.dropped reason=cropFailed rawClass=\(raw.rawClass, privacy: .public)")
            return nil
        }
        let category = ClothingCategory.fromFashionpediaClass(raw.rawClass)
        let subcategory = ClothingSubcategory.fromFashionpediaClass(raw.rawClass)
        let confidence: ExtractionConfidence = {
            if raw.score >= 0.85 { return .high }
            if raw.score >= 0.6 { return .medium }
            return .low
        }()
        // Per-proposal telemetry — dogfood failures (sneakers→Boots,
        // sunglasses→Hat, etc.) need the raw model class string + the
        // resolved category/subcategory side-by-side to triage. PII-
        // safe: bbox geometry only, no image bytes or user identifiers.
        staticLogger.info(
            """
            makeProposal: \
            rawClass=\(raw.rawClass, privacy: .public) \
            score=\(raw.score, privacy: .public) \
            bbox=(\(raw.boundingBox.minX, privacy: .public),\(raw.boundingBox.minY, privacy: .public),\(raw.boundingBox.width, privacy: .public),\(raw.boundingBox.height, privacy: .public)) \
            category=\(category?.rawValue ?? "nil", privacy: .public) \
            subcategory=\(subcategory?.rawValue ?? "nil", privacy: .public) \
            hasMask=\(raw.mask != nil, privacy: .public)
            """
        )
        return MaskProposal(
            id: UUID(),
            maskedImage: cropped,
            mask: raw.mask,
            confidence: confidence,
            predictedCategory: category,
            // raw.score is already a post-sigmoid objectness in [0,1];
            // DETR's formulation makes "is this a valid detection of
            // class C" inseparable from "what's the class C", so the
            // detection score IS the category confidence.
            predictedCategoryConfidence: raw.score,
            predictedSubcategory: subcategory,
            boundingBox: raw.boundingBox,
            detectionScore: raw.score,
            modelClassRaw: raw.rawClass
        )
    }

    /// Run the attribute classifier on a proposal's cropped image and
    /// feed the result through the rules engine to populate seasons +
    /// occasions. Classifier errors (model missing, inference threw)
    /// are swallowed — the proposal is returned with rules-engine-only
    /// fallback so the caller's UX is identical to the "no classifier
    /// injected" path.
    static func enriched(
        _ proposal: MaskProposal,
        with classifier: AttributeClassifying,
        logger: Logger
    ) async -> MaskProposal {
        let prediction: AttributePrediction
        do {
            prediction = try await classifier.predict(crop: proposal.maskedImage)
        } catch {
            logger.notice("attribute.predict.failed \(error.localizedDescription, privacy: .public)")
            return enrichedWithRulesOnly(proposal, logger: logger)
        }
        return applyAttributesAndRules(
            to: proposal,
            prediction: prediction,
            pathTaken: "ml-classifier",
            logger: logger
        )
    }

    /// Fallback enrichment when no classifier is available. Still
    /// populates seasons + occasions from the rules engine using
    /// whatever category + subcategory the detection head produced.
    static func enrichedWithRulesOnly(
        _ proposal: MaskProposal,
        logger: Logger? = nil
    ) -> MaskProposal {
        applyAttributesAndRules(
            to: proposal,
            prediction: .empty,
            pathTaken: "rules-only",
            logger: logger
        )
    }

    /// Shared enrichment logic: given a base proposal and an (optional)
    /// attribute prediction, return a proposal with seasons + occasions
    /// filled in from `AttributeRulesEngine`.
    ///
    /// The `pathTaken` parameter exists purely for diagnostics — it
    /// distinguishes the `ml-classifier` (attribute model returned a
    /// prediction), `rules-only` (no classifier or classifier errored),
    /// and `direct` (callers like tests bypass the higher-level
    /// orchestration) paths in the structured log line emitted at the
    /// end of this method. Build-5 dogfood (PR #25) added the log so
    /// future "texture not pre-filled" failures can be diagnosed by
    /// grep'ing the device log for `multiGarment.enrichment` rather
    /// than re-instrumenting the codebase.
    static func applyAttributesAndRules(
        to proposal: MaskProposal,
        prediction: AttributePrediction,
        pathTaken: String = "direct",
        logger: Logger? = nil
    ) -> MaskProposal {
        // Rules engine needs a concrete ClothingCategory +
        // ClothingSubcategory. Fall back to sensible defaults when the
        // detection head didn't surface one — the enum's `.category`
        // chain keeps the types consistent, and every subcategory has
        // a category by construction.
        let category = proposal.predictedCategory
            ?? proposal.predictedSubcategory?.category
            ?? .top
        let subcategory = proposal.predictedSubcategory
            ?? ClothingSubcategory.subcategories(for: category).first
            ?? .tshirt

        // Texture: prefer the ML prediction when present. When the
        // Build 6: texture is exclusively rules-derived. The
        // deterministic subcategory→texture lookup (jeans → denim,
        // sweater → knit, …) is the only auto-population path; ML
        // inference for texture was retired (`AttributePrediction`
        // no longer carries a texture field). Rules-derived textures
        // stamp a 0.85 confidence sentinel — just above the 0.80
        // prefill gate in `AttributePrefill` — so they pass the gate
        // while staying distinguishable from user-confirmed values in
        // the `detected_attributes` JSONB telemetry.
        let resolvedTexture: TextureType?
        let resolvedTextureConfidence: Float
        let textureSource: String
        if let rulesTexture = AttributeRulesEngine.deriveTexture(
            category: category, subcategory: subcategory
        ) {
            resolvedTexture = rulesTexture
            resolvedTextureConfidence = AttributeRulesEngine.rulesTextureConfidence
            textureSource = "rules-table"
        } else {
            resolvedTexture = nil
            resolvedTextureConfidence = 0.0
            textureSource = "none"
        }

        let rules = AttributeRulesEngine.derive(
            category: category,
            subcategory: subcategory,
            texture: resolvedTexture
        )

        // Build-5 dogfood (PR #25): structured log so future "texture
        // not pre-filled" failures can be diagnosed by tailing the
        // device log for `multiGarment.enrichment`. Captures the path
        // taken (ml-classifier / rules-only / direct), the resolved
        // category + subcategory the rules engine used, the resolved
        // texture, and which lookup tier produced it (prediction /
        // rules-table / none). The log is gated on a Logger being
        // injected so tests calling this static directly don't spam.
        if let logger {
            let categoryRaw = category.rawValue
            let subcategoryRaw = subcategory.rawValue
            let textureRaw = resolvedTexture?.rawValue ?? "nil"
            logger.info("multiGarment.enrichment: path=\(pathTaken, privacy: .public) category=\(categoryRaw, privacy: .public) subcategory=\(subcategoryRaw, privacy: .public) texture=\(textureRaw, privacy: .public) source=\(textureSource, privacy: .public)")
        }

        return MaskProposal(
            id: proposal.id,
            maskedImage: proposal.maskedImage,
            mask: proposal.mask,
            confidence: proposal.confidence,
            predictedCategory: proposal.predictedCategory,
            predictedCategoryConfidence: proposal.predictedCategoryConfidence,
            predictedSubcategory: proposal.predictedSubcategory,
            predictedTexture: resolvedTexture,
            predictedTextureConfidence: resolvedTextureConfidence,
            predictedFit: prediction.fit,
            predictedFitConfidence: prediction.fitConfidence,
            predictedSeasons: Array(rules.seasons).sorted { $0.rawValue < $1.rawValue },
            predictedOccasions: Array(rules.occasions).sorted { $0.rawValue < $1.rawValue },
            boundingBox: proposal.boundingBox,
            detectionScore: proposal.detectionScore,
            modelClassRaw: proposal.modelClassRaw
        )
    }

    // MARK: - Working-image downscale

    /// Returns a downscaled copy of `image` whose longest side is at
    /// most `workingImageMaxDimension` px. Returns the input unchanged
    /// when it's already small enough — no allocation, no work.
    ///
    /// Render scale is forced to 1 so the resulting bitmap memory is
    /// exactly `width × height × 4` bytes; a `UIImage` constructed at
    /// the device's native scale would silently use 4-9× more RAM
    /// because the renderer would multiply the pixel count by
    /// `UIScreen.main.scale²`.
    ///
    /// `static` so unit tests can verify the resize behaviour without
    /// instantiating the service or hitting the model bundle.
    static func downscaledForCutouts(_ image: UIImage) -> UIImage {
        let maxDim = max(image.size.width, image.size.height)
        guard maxDim > workingImageMaxDimension else { return image }

        let scale = workingImageMaxDimension / maxDim
        let target = CGSize(
            width: floor(image.size.width * scale),
            height: floor(image.size.height * scale)
        )
        guard target.width > 0, target.height > 0 else { return image }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }

    /// Composite the per-instance segmentation mask onto the source image
    /// then crop to the proposal's bounding box, producing a transparent-
    /// background `UIImage`.
    ///
    /// **Why this exists.** The previous `cropped()` took a rectangular
    /// slice of the source photo. Wardrobe cards rendered those slices
    /// with the source-photo backdrop visible (the "mirror selfie behind
    /// the shirt" bug). RFDETR-Seg already produces a per-instance
    /// segmentation mask — this function uses it to mask out everything
    /// outside the garment, leaving alpha=0 outside and ~alpha=255 inside.
    ///
    /// **Mask handling.**
    ///   * `mask == nil` → fall back to a plain rectangular bbox crop
    ///     (back-compat with the legacy `cropped()` behavior). The model
    ///     can fail to surface a mask (e.g. when the segmentation head
    ///     isn't decoded yet) and we'd rather show a rect crop than
    ///     drop the proposal entirely.
    ///   * `mask != nil` → run `MaskCleaner.clean` to drop the soft
    ///     fringe, scale to source extent, composite via `CIBlendWithMask`
    ///     against transparency, then crop to the bbox region.
    ///
    /// The masking approach uses `CIBlendWithMask` — same pattern as
    /// `VisionForegroundExtractor.applyMask` (the single-item flow). See
    /// `web-research/G-ios-isolation-best-practices.md` § 2.1 for rationale.
    static func compositeMaskedItem(
        sourceImage: UIImage,
        mask: CVPixelBuffer?,
        bbox normalizedBox: CGRect
    ) -> UIImage? {
        guard let cg = sourceImage.cgImage else { return sourceImage }

        let w = CGFloat(cg.width)
        let h = CGFloat(cg.height)
        let rect = CGRect(
            x: normalizedBox.minX * w,
            y: normalizedBox.minY * h,
            width: normalizedBox.width * w,
            height: normalizedBox.height * h
        ).integral

        // No usable mask — preserve the legacy rect-crop behavior so the
        // proposal still surfaces (better than dropping it entirely).
        guard let mask else {
            return rectCropFallback(cg, rect: rect, base: sourceImage)
        }

        // Composite source over transparent background using the cleaned
        // mask. CIImage extents put origin at bottom-left while CGImage
        // pixels are top-left — both extents are full-image so the
        // bbox-pixel rect we computed above is in the right space for
        // the final cgImage crop.
        let sourceCI = CIImage(cgImage: cg)
        let maskCI = CIImage(cvPixelBuffer: mask)

        // Scale mask to match source extent (RFDETR's mask is at model
        // resolution, e.g. 320×320; source can be 1280×… after the
        // working-image downscale).
        let sx = sourceCI.extent.width / max(maskCI.extent.width, 1)
        let sy = sourceCI.extent.height / max(maskCI.extent.height, 1)
        let scaledMask = maskCI.transformed(by: CGAffineTransform(scaleX: sx, y: sy))

        // Drop the soft fringe. If cleaning fails for any reason, fall
        // back to the un-cleaned scaled mask rather than the rect crop —
        // a slightly fringy cutout still beats a rect crop visually.
        let finalMask = MaskCleaner.clean(scaledMask) ?? scaledMask

        guard let blend = CIFilter(name: "CIBlendWithMask") else {
            return rectCropFallback(cg, rect: rect, base: sourceImage)
        }
        blend.setValue(sourceCI, forKey: kCIInputImageKey)
        blend.setValue(CIImage.empty(), forKey: kCIInputBackgroundImageKey)
        blend.setValue(finalMask, forKey: kCIInputMaskImageKey)

        guard let composited = blend.outputImage else {
            return rectCropFallback(cg, rect: rect, base: sourceImage)
        }

        let context = CIContext(options: nil)
        guard let fullCG = context.createCGImage(composited, from: sourceCI.extent) else {
            return rectCropFallback(cg, rect: rect, base: sourceImage)
        }

        // Crop the composited image to the bbox region. fullCG carries
        // alpha now, so the crop preserves transparency outside the
        // garment silhouette.
        guard rect.width > 1, rect.height > 1,
              let cropped = fullCG.cropping(to: rect) else {
            return UIImage(cgImage: fullCG, scale: sourceImage.scale, orientation: sourceImage.imageOrientation)
        }
        return UIImage(cgImage: cropped, scale: sourceImage.scale, orientation: sourceImage.imageOrientation)
    }

    /// Rectangular bbox crop — the legacy behavior preserved as the
    /// nil-mask fallback so any caller that hits the no-mask path still
    /// gets a usable image. Kept private since callers should always go
    /// through `compositeMaskedItem`.
    private static func rectCropFallback(_ cg: CGImage, rect: CGRect, base: UIImage) -> UIImage? {
        guard rect.width > 1, rect.height > 1,
              let cropped = cg.cropping(to: rect) else { return base }
        return UIImage(cgImage: cropped, scale: base.scale, orientation: base.imageOrientation)
    }
}

// MARK: - MLMultiArray convenience

private extension MLMultiArray {
    /// Safe indexed read that returns `nil` when the shape doesn't match
    /// the index, so post-processing helpers can defensively handle the
    /// variety of DETR export shapes coremltools emits.
    subscript(safe indices: [Int]) -> Float? {
        guard indices.count == shape.count else { return nil }
        for (i, dim) in indices.enumerated() {
            guard dim >= 0, dim < shape[i].intValue else { return nil }
        }
        let nsIndices = indices.map { NSNumber(value: $0) }
        return self[nsIndices].floatValue
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
