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

    /// Confidence floor for detections whose Fashionpedia class maps to
    /// a real `ClothingCategory` (shirt, pants, jacket, …).
    ///
    /// Build 46 — lowered 0.5 → 0.35. TestFlight users reported
    /// "fails to detect tshirts": a patterned t-shirt / sports jersey
    /// worn in a mirror selfie scored ~0.35-0.45, below the old 0.5
    /// floor, so RF-DETR emitted no proposal. With the TF45 RF-DETR-
    /// first pipeline that miss now falls through to Vision, which
    /// returns the WHOLE PERSON as the cutout — the exact failure the
    /// user saw. The cost asymmetry is stark: a false-negative garment
    /// becomes a person-shaped wardrobe item, while a false-positive
    /// garment is one extra deselectable card in the multi-pick grid
    /// (or a "Refine if needed" tap on the single-item preview). 0.35
    /// rescues under-confident real garments; the ambiguous-class
    /// floor below still rejects non-clothing patterns at 0.85.
    static let defaultConfidenceThreshold: Float = 0.35

    /// Build 47 — recall tiers below the base floor for high-value
    /// classes. TestFlight users still reported missed t-shirts/jerseys
    /// (and a missed held handbag) at the 0.35 base. The cost asymmetry
    /// is steep — a missed garment becomes a whole-person Vision cutout
    /// (TF45 fallthrough), while a false positive is a deselectable grid
    /// card — so the big apparel classes get a lower 0.25 floor. The
    /// ambiguous-class 0.85 floor still guards non-clothing, so noise
    /// risk stays bounded.
    static let highRecallApparelFloor: Float = 0.25
    static let highRecallApparelClasses: Set<String> = [
        "top_t-shirt_sweatshirt", "shirt_blouse", "sweater", "cardigan", "vest",
        "dress", "jumpsuit",
        "jacket", "coat", "cape",
        "pants", "shorts", "skirt", "tights_stockings"
    ]

    /// Held / occluded handbags are a known model-recall weak spot
    /// ("failed to see handbag while someone is holding it"). A modest
    /// 0.30 floor for the bag class gives a partially-detected bag its
    /// best shot without dropping the accessory floor generally — bags
    /// have a distinctive silhouette, so false-positive bags are rarer
    /// than false-positive "tops" on fabric patterns. This is a bounded
    /// recall nudge, NOT a fix; held-bag recall is fundamentally limited
    /// until the detection model is retrained.
    static let bagRecallFloor: Float = 0.30

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
    static let staticLogger = Logger(subsystem: "com.wardroberedo", category: "MultiGarment")

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
            // Build 47 — tiered recall floors:
            //   * core apparel (tops/dresses/outerwear/bottoms): 0.25
            //   * handbag: 0.30
            //   * other mapped classes (shoes, other accessories): 0.35
            //   * ambiguous / non-clothing: 0.85 (noise guard)
            if Self.highRecallApparelClasses.contains(raw.rawClass) {
                return raw.score >= Self.highRecallApparelFloor
            }
            if raw.rawClass == "bag_wallet" {
                return raw.score >= Self.bagRecallFloor
            }
            if ClothingCategory.fromFashionpediaClass(raw.rawClass) == nil {
                return raw.score >= Self.ambiguousClassConfidenceFloor
            }
            return raw.score >= confidenceThreshold
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

}
