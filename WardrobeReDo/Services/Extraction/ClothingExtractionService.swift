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

/// Which code path produced the final mask. Phase 1 only has `.vision`
/// and `.none`. Phase 3 will add `.sam2Auto` and `.sam2Manual`.
enum ExtractionMethod: String, Codable, Sendable, Equatable {
    case vision
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

    init(visionExtractor: any VisionForegroundExtracting = VisionForegroundExtractor()) {
        self.visionExtractor = visionExtractor
    }

    func extract(_ image: UIImage) async -> ExtractionResult {
        // Work with a rotation-normalized copy so the downstream JPEG
        // and mask share the same pixel orientation.
        let normalized = OrientationUtil.normalized(image)

        guard let result = await visionExtractor.extractForeground(from: normalized) else {
            return ExtractionResult(
                originalImage: normalized,
                maskedImage: normalized,
                mask: nil,
                confidence: .failed,
                method: .none
            )
        }

        let confidence = Self.synthesizeConfidence(
            instanceCount: result.instanceCount,
            coverageRatio: result.coverageRatio
        )

        return ExtractionResult(
            originalImage: normalized,
            maskedImage: result.maskedImage,
            mask: result.mask,
            confidence: confidence,
            method: .vision
        )
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
        // or clothing + accessory. Phase 3 will offer tap-to-select to fix.
        return .low
    }
}
