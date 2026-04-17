import CoreImage
import CoreVideo
import UIKit

/// Synthetic confidence level for an extraction attempt, stored in the
/// `wardrobe_items.extraction_confidence` column for downstream analytics
/// and UX (e.g. "auto-cropped" badge for `.low` results).
///
/// Vision itself does NOT expose a numeric confidence for its foreground
/// mask — we derive this from instance count + coverage ratio in
/// `ClothingExtractionService.synthesizeConfidence(...)`.
enum ExtractionConfidence: String, Codable, Sendable, Equatable {
    /// One dominant instance, covering > 15% of the frame. Trust fully.
    case high
    /// One instance, 5–15% coverage. Usable but likely a small item.
    case medium
    /// Multiple instances OR < 5% coverage. Mask may be wrong.
    case low
    /// Vision found no foreground. Fell back to the unmasked original.
    case failed
}

/// Which code path produced the final mask.
/// - `.vision`: `VNGenerateForegroundInstanceMaskRequest` succeeded outright.
/// - `.sam2Auto`: Vision was `.low` / `.failed`, so the pipeline auto-ran
///   the SAM2-tiny Core ML model with a single center-of-frame positive
///   point. The UI should surface this as an "auto-cropped" badge so the
///   user knows to double-check.
/// - `.sam2Manual`: User opened `TapToSelectView` and pointed at the item
///   themselves. Treated as the highest-trust path.
/// - `.none`: No mask was produced; the unmasked original is what we saved.
enum ExtractionMethod: String, Codable, Sendable, Equatable {
    case vision
    case sam2Auto
    case sam2Manual
    case none
}

/// Output of the extraction pipeline. Carries the masked image (for
/// color extraction + storage) alongside the raw mask buffer (for the
/// touch-up editor later) and enough provenance to render a confidence
/// badge in the UI.
///
/// `@unchecked Sendable` is required because `CVPixelBuffer` is a CF
/// type that Swift can't prove Sendable on its own. The buffer is
/// created inside Vision's callback, handed to us read-only, and never
/// mutated after construction — safe to cross actor boundaries.
struct ExtractionResult: @unchecked Sendable {
    /// The input image, unchanged (may be rotation-normalized).
    let originalImage: UIImage
    /// Original image with background masked to transparency when
    /// extraction succeeded; equal to `originalImage` when it failed.
    let maskedImage: UIImage
    /// Raw Vision mask buffer. Nil when extraction failed.
    let mask: CVPixelBuffer?
    let confidence: ExtractionConfidence
    let method: ExtractionMethod
}

/// Injection seam so view models and tests can swap in a mock
/// extractor without spinning up the Vision framework.
protocol ClothingExtracting: Sendable {
    func extract(_ image: UIImage) async -> ExtractionResult

    /// Phase 3 manual-override entry point. Called from `TapToSelectView`
    /// when the user taps the clothing directly (and optionally drops
    /// negative points on skin or background). Skips Vision entirely and
    /// returns a SAM2-backed mask.
    func extract(_ image: UIImage, tapPoints: [SAM2TapPoint]) async -> ExtractionResult

    /// Pre-warm heavy resources (e.g. SAM2 model load). Safe to call
    /// repeatedly — the underlying extractor guards against redundant
    /// work. Invoked from `AddItemView.onAppear` / `TapToSelectView.onAppear`
    /// so the user doesn't see a cold-start delay at capture time.
    func prewarm() async
}

extension ClothingExtracting {
    /// Default: manual tap-points not supported (mocks can opt in).
    func extract(_ image: UIImage, tapPoints: [SAM2TapPoint]) async -> ExtractionResult {
        await extract(image)
    }

    func prewarm() async { /* default no-op */ }
}

/// Orchestrates clothing-from-background isolation for every new
/// wardrobe photo. Phase 1 runs Vision's foreground mask request and
/// synthesizes a confidence level from mask coverage. Phase 3 will
/// chain a SAM2 tap-to-select fallback when `.low` / `.failed`.
///
/// Usage: called from `ImageService.processImage(_:)` *after* resize
/// and *before* color extraction. The masked image is what gets fed to
/// k-means so background colors no longer bias the wardrobe palette.
final class ClothingExtractionService: ClothingExtracting, @unchecked Sendable {

    private let visionExtractor: any VisionForegroundExtracting
    private let sam2Extractor: any SAM2Extracting

    init(
        visionExtractor: any VisionForegroundExtracting = VisionForegroundExtractor(),
        sam2Extractor: any SAM2Extracting = SAM2Extractor()
    ) {
        self.visionExtractor = visionExtractor
        self.sam2Extractor = sam2Extractor
    }

    func extract(_ image: UIImage) async -> ExtractionResult {
        // Work with a rotation-normalized copy so the downstream JPEG
        // and mask share the same pixel orientation.
        let normalized = OrientationUtil.normalized(image)

        let visionResult = await visionExtractor.extractForeground(from: normalized)

        if let vision = visionResult {
            let confidence = Self.synthesizeConfidence(
                instanceCount: vision.instanceCount,
                coverageRatio: vision.coverageRatio
            )

            // Trust Vision's mask when confidence is high enough —
            // short-circuiting SAM2 is the fast common path (~80% of
            // uploads per the benchmark set).
            if Self.isHighTrust(confidence) {
                return ExtractionResult(
                    originalImage: normalized,
                    maskedImage: vision.maskedImage,
                    mask: vision.mask,
                    confidence: confidence,
                    method: .vision
                )
            }

            // Low-confidence Vision: try SAM2 auto. If SAM2 produces a
            // better mask, swap it in; otherwise stick with Vision.
            if let sam2 = await sam2Extractor.autoSegment(from: normalized) {
                let sam2Confidence = Self.synthesizeConfidence(
                    instanceCount: 1,
                    coverageRatio: sam2.coverageRatio
                )
                return ExtractionResult(
                    originalImage: normalized,
                    maskedImage: sam2.maskedImage,
                    mask: sam2.mask,
                    confidence: sam2Confidence,
                    method: .sam2Auto
                )
            }

            // Vision returned something usable-ish; keep it as the
            // best available result rather than falling off the cliff
            // to the unmasked original.
            return ExtractionResult(
                originalImage: normalized,
                maskedImage: vision.maskedImage,
                mask: vision.mask,
                confidence: confidence,
                method: .vision
            )
        }

        // Vision failed outright (nothing detected, simulator, etc.).
        // Try SAM2 auto as a second-chance rescue.
        if let sam2 = await sam2Extractor.autoSegment(from: normalized) {
            let sam2Confidence = Self.synthesizeConfidence(
                instanceCount: 1,
                coverageRatio: sam2.coverageRatio
            )
            return ExtractionResult(
                originalImage: normalized,
                maskedImage: sam2.maskedImage,
                mask: sam2.mask,
                confidence: sam2Confidence,
                method: .sam2Auto
            )
        }

        // Nothing worked. Fall through to the unmasked original.
        return ExtractionResult(
            originalImage: normalized,
            maskedImage: normalized,
            mask: nil,
            confidence: .failed,
            method: .none
        )
    }

    func extract(_ image: UIImage, tapPoints: [SAM2TapPoint]) async -> ExtractionResult {
        let normalized = OrientationUtil.normalized(image)
        guard !tapPoints.isEmpty,
              let sam2 = await sam2Extractor.segment(image: normalized, points: tapPoints)
        else {
            // User opened TapToSelectView but SAM2 was unavailable (model
            // missing / prediction error). Fall back to whatever the
            // automatic pipeline can produce, rather than leaving them
            // stuck on a broken screen.
            return await extract(normalized)
        }
        let confidence = Self.synthesizeConfidence(
            instanceCount: 1,
            coverageRatio: sam2.coverageRatio
        )
        return ExtractionResult(
            originalImage: normalized,
            maskedImage: sam2.maskedImage,
            mask: sam2.mask,
            confidence: confidence,
            method: .sam2Manual
        )
    }

    func prewarm() async {
        await sam2Extractor.prewarm()
    }

    // MARK: - Confidence heuristic

    /// Vision doesn't expose a score, so we approximate one from the
    /// two signals it does give us: how many foreground instances it
    /// found, and what fraction of the frame those instances cover.
    ///
    /// The thresholds here were picked from the 30-photo fixture set
    /// and are tuned to match human judgment of "the mask is right."
    /// Adjust by running `SegmentationIoUTests` and checking which
    /// fixtures shift confidence buckets.
    static func synthesizeConfidence(
        instanceCount: Int,
        coverageRatio: Double
    ) -> ExtractionConfidence {
        guard instanceCount > 0 else { return .failed }

        if instanceCount == 1 {
            if coverageRatio > 0.15 { return .high }
            if coverageRatio > 0.05 { return .medium }
            return .low
        }

        // Multiple instances: the mask probably captured clothing + person
        // or clothing + accessory. Phase 3 offers tap-to-select to fix.
        return .low
    }

    /// `true` when Vision's mask is trustworthy enough to skip SAM2 auto.
    /// `.high` / `.medium` are kept; `.low` / `.failed` trigger fallback.
    static func isHighTrust(_ confidence: ExtractionConfidence) -> Bool {
        switch confidence {
        case .high, .medium: return true
        case .low, .failed:  return false
        }
    }
}
