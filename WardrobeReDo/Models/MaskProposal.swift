import CoreVideo
import Foundation
import UIKit

/// One garment proposal returned by `MultiGarmentProposalService`. Each
/// proposal represents a single instance-segmented clothing item
/// detected in the source photo, with a labelled category, a composited
/// cutout (background masked to transparency), the raw mask buffer (for
/// the refine-with-brush detour), a confidence band, and the model's
/// raw-class string for telemetry.
///
/// `@unchecked Sendable` because `CVPixelBuffer` is a CF type that Swift
/// can't prove `Sendable` on its own. The buffer is read-only after
/// construction — same invariant as `ExtractionResult`.
struct MaskProposal: Identifiable, Hashable, @unchecked Sendable {
    let id: UUID

    /// Composited cutout (original pixels where mask is on, transparent
    /// elsewhere). Used for the multi-pick overlay thumbnail and as the
    /// final `maskedImage` once the proposal is committed to details.
    let maskedImage: UIImage

    /// Raw mask buffer at source resolution. Preserved so the user can
    /// re-enter the refine-with-brush editor per-proposal without losing
    /// the model's starting point. Nil when mask reconstruction failed
    /// but the bounding box was still usable.
    let mask: CVPixelBuffer?

    /// Synthetic confidence band (re-uses the existing enum so the rest
    /// of the app — "auto-cropped" badge, analytics — doesn't need a
    /// second confidence type).
    let confidence: ExtractionConfidence

    /// Category prediction for this proposal, mapped from the model's
    /// Fashionpedia label via `ClothingCategory.fromFashionpediaClass`.
    /// Nil when the class isn't surfaced in v1 (sock, leg_warmer, …).
    let predictedCategory: ClothingCategory?

    /// Softmaxed confidence of the category prediction in [0, 1]. The
    /// Add Item pre-fill only consumes `predictedCategory` when this
    /// clears `AttributePrefill.minConfidence` — keeps low-confidence
    /// guesses from annoying the user. 0.0 means "no prediction".
    let predictedCategoryConfidence: Float

    /// Subcategory hint derived from the raw Fashionpedia class (e.g.
    /// `"shirt_blouse"` → `.buttonDown`). Nil when the class is too
    /// ambiguous to commit to a subcategory (e.g. generic `"pants"` —
    /// we don't know jeans vs chinos from the name alone). Populated by
    /// `ClothingSubcategory.fromFashionpediaClass`.
    let predictedSubcategory: ClothingSubcategory?

    /// Texture prediction from the attribute classifier. Nil until the
    /// attribute model ships (Phase 3–4 of the auto-attribute-detection
    /// plan) — rely on `predictedTextureConfidence == 0.0` as the
    /// "no prediction yet" sentinel rather than optional-chaining.
    let predictedTexture: TextureType?

    /// Softmaxed confidence of the texture prediction in [0, 1].
    let predictedTextureConfidence: Float

    /// Fit prediction from the attribute classifier. Same lifecycle as
    /// `predictedTexture`.
    let predictedFit: FitAttribute?

    /// Softmaxed confidence of the fit prediction in [0, 1].
    let predictedFitConfidence: Float

    /// Seasons derived by `AttributeRulesEngine` from
    /// (category, subcategory, texture). Empty until the rules engine
    /// ships (Phase 5); the pre-fill layer falls back to all-seasons in
    /// that case. Guaranteed non-empty once the rules engine is wired.
    let predictedSeasons: [Season]

    /// Occasions derived by `AttributeRulesEngine`. Same lifecycle as
    /// `predictedSeasons`; falls back to `[.casual]` when empty.
    let predictedOccasions: [Occasion]

    /// Normalized bounding box in [0, 1] × [0, 1] image coordinates
    /// (origin top-left). Drives the multi-pick overlay layout and
    /// render order (largest-first so accessories aren't buried).
    let boundingBox: CGRect

    /// Raw model objectness score (0…1). Used for display ordering,
    /// proposal cap ("top N"), and the ML Diagnostics debug menu.
    let detectionScore: Float

    /// Original Fashionpedia class (e.g. "shirt_blouse"). Kept alongside
    /// the collapsed `predictedCategory` so we can log prediction drift
    /// in telemetry and expose finer granularity in v1.1 without
    /// retraining the model.
    let modelClassRaw: String

    /// Full memberwise initializer with defaults for every
    /// auto-attribute-detection field. Existing call sites that predate
    /// the attribute classifier continue to compile unchanged — new
    /// fields default to "no prediction" (empty / 0.0 / nil).
    init(
        id: UUID,
        maskedImage: UIImage,
        mask: CVPixelBuffer?,
        confidence: ExtractionConfidence,
        predictedCategory: ClothingCategory?,
        predictedCategoryConfidence: Float = 0.0,
        predictedSubcategory: ClothingSubcategory? = nil,
        predictedTexture: TextureType? = nil,
        predictedTextureConfidence: Float = 0.0,
        predictedFit: FitAttribute? = nil,
        predictedFitConfidence: Float = 0.0,
        predictedSeasons: [Season] = [],
        predictedOccasions: [Occasion] = [],
        boundingBox: CGRect,
        detectionScore: Float,
        modelClassRaw: String
    ) {
        self.id = id
        self.maskedImage = maskedImage
        self.mask = mask
        self.confidence = confidence
        self.predictedCategory = predictedCategory
        self.predictedCategoryConfidence = predictedCategoryConfidence
        self.predictedSubcategory = predictedSubcategory
        self.predictedTexture = predictedTexture
        self.predictedTextureConfidence = predictedTextureConfidence
        self.predictedFit = predictedFit
        self.predictedFitConfidence = predictedFitConfidence
        self.predictedSeasons = predictedSeasons
        self.predictedOccasions = predictedOccasions
        self.boundingBox = boundingBox
        self.detectionScore = detectionScore
        self.modelClassRaw = modelClassRaw
    }

    // MARK: - Hashable / Equatable

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: MaskProposal, rhs: MaskProposal) -> Bool {
        lhs.id == rhs.id
    }
}

extension CGRect {
    /// Convenience used by the multi-pick overlay to render largest
    /// proposals first (back-to-front), so small accessories land on top
    /// of large garments rather than getting buried underneath.
    var area: CGFloat { abs(width * height) }
}
