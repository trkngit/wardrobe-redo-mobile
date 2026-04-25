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
    /// multi-pick view routes surplus items into a "+N more" sheet.
    static let maxProposals = 8

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

    private let modelLoader: @Sendable () -> MLModel?
    private let confidenceThreshold: Float
    private let nmsThreshold: Float
    private let attributeClassifier: AttributeClassifying?
    private let logger = Logger(subsystem: "com.wardroberedo", category: "MultiGarment")

    /// One-shot model load. `NSLock`-gated lazy just like SAM2Extractor.
    private let modelLock = NSLock()
    private var loadedModel: MLModel?
    private var modelLoadAttempted = false

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

        let normalized = OrientationUtil.normalized(image)

        guard let pixelBuffer = Self.preprocessedPixelBuffer(for: normalized, model: model) else {
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
        let thresholded = rawDetections.filter { $0.score >= confidenceThreshold }

        guard !thresholded.isEmpty else {
            logger.notice("detectProposals.noValidPredictions raw=\(rawDetections.count, privacy: .public) threshold=\(self.confidenceThreshold, privacy: .public)")
            // Empty array — NOT an error, just a photo with no clothing.
            // Callers check `isEmpty` and fall through to the single-item
            // flow automatically.
            await recordSuccess(start: start, proposals: [])
            return []
        }

        let suppressed = Self.applyNMS(thresholded, threshold: nmsThreshold)
        let capped = Array(suppressed
            .sorted { $0.score > $1.score }
            .prefix(Self.maxProposals))

        let baseProposals = capped.compactMap { raw -> MaskProposal? in
            Self.makeProposal(from: raw, sourceImage: normalized)
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
            proposals = baseProposals.map { Self.enrichedWithRulesOnly($0) }
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
        _ = multiArray(for: maskKeys, in: prediction)
        // Masks aren't decoded in v1 post-processing — we fall back to
        // bounding-box crops until the trained model is wired up and we
        // know the exact mask-head tensor shape. Reserved for v1.1.

        // Resolve how many queries the model emitted.
        let queryCount = boxes.shape[safe: 1]?.intValue ?? 0
        guard queryCount > 0 else { return [] }

        var result: [RawDetection] = []
        result.reserveCapacity(queryCount)

        for q in 0 ..< queryCount {
            let bbox = decodeBoundingBox(boxes, queryIndex: q)
            let rawScore = decodeScore(scores: scores, logits: logits, queryIndex: q)
            let rawClass = decodeClassLabel(classes: classes, logits: logits, queryIndex: q)
            result.append(RawDetection(
                boundingBox: bbox,
                score: rawScore,
                rawClass: rawClass,
                mask: nil
            ))
        }
        return result
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

    // MARK: - Proposal construction

    static func makeProposal(
        from raw: RawDetection,
        sourceImage: UIImage
    ) -> MaskProposal? {
        guard let cropped = cropped(sourceImage, to: raw.boundingBox) else { return nil }
        let category = ClothingCategory.fromFashionpediaClass(raw.rawClass)
        let subcategory = ClothingSubcategory.fromFashionpediaClass(raw.rawClass)
        let confidence: ExtractionConfidence = {
            if raw.score >= 0.85 { return .high }
            if raw.score >= 0.6 { return .medium }
            return .low
        }()
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
            return enrichedWithRulesOnly(proposal)
        }
        return applyAttributesAndRules(to: proposal, prediction: prediction)
    }

    /// Fallback enrichment when no classifier is available. Still
    /// populates seasons + occasions from the rules engine using
    /// whatever category + subcategory the detection head produced.
    static func enrichedWithRulesOnly(_ proposal: MaskProposal) -> MaskProposal {
        applyAttributesAndRules(to: proposal, prediction: .empty)
    }

    /// Shared enrichment logic: given a base proposal and an (optional)
    /// attribute prediction, return a proposal with seasons + occasions
    /// filled in from `AttributeRulesEngine`.
    static func applyAttributesAndRules(
        to proposal: MaskProposal,
        prediction: AttributePrediction
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
        // classifier didn't predict (texture head still dormant in v1
        // — Fashionpedia v2 lacks main-fabric-type attributes), fall
        // back to the deterministic subcategory→texture rule (jeans →
        // denim, sweater → knit, …). Rules-derived textures stamp a
        // 0.85 confidence sentinel — just above the 0.80 prefill gate
        // in `AttributePrefill`, so they pass the gate while remaining
        // distinguishable from any future ML score in the
        // `detected_attributes` JSONB telemetry.
        let resolvedTexture: TextureType?
        let resolvedTextureConfidence: Float
        if let mlTexture = prediction.texture {
            resolvedTexture = mlTexture
            resolvedTextureConfidence = prediction.textureConfidence
        } else if let rulesTexture = AttributeRulesEngine.deriveTexture(
            category: category, subcategory: subcategory
        ) {
            resolvedTexture = rulesTexture
            resolvedTextureConfidence = AttributeRulesEngine.rulesTextureConfidence
        } else {
            resolvedTexture = nil
            resolvedTextureConfidence = 0.0
        }

        let rules = AttributeRulesEngine.derive(
            category: category,
            subcategory: subcategory,
            texture: resolvedTexture
        )

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

    private static func cropped(_ image: UIImage, to normalizedBox: CGRect) -> UIImage? {
        guard let cg = image.cgImage else { return image }
        let w = CGFloat(cg.width)
        let h = CGFloat(cg.height)
        let rect = CGRect(
            x: normalizedBox.minX * w,
            y: normalizedBox.minY * h,
            width: normalizedBox.width * w,
            height: normalizedBox.height * h
        ).integral
        guard rect.width > 1, rect.height > 1,
              let cropped = cg.cropping(to: rect) else { return image }
        return UIImage(cgImage: cropped, scale: image.scale, orientation: image.imageOrientation)
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
