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

    /// Texture for the proposal. Populated by
    /// `AttributeRulesEngine.deriveTexture` (deterministic
    /// subcategory→texture lookup, e.g. jeans → denim, sweater →
    /// knit). **Build 6** retired the parallel ML inference path —
    /// Fashionpedia v2 carried no main-fabric-type attributes so the
    /// head emitted nil in production. Nil here means neither the
    /// rules table nor a category-default lookup committed to a
    /// texture; the user picks from `ItemFormView`.
    let predictedTexture: TextureType?

    /// Confidence in [0, 1]. Rules-derived textures stamp a 0.85
    /// sentinel (see `AttributeRulesEngine.rulesTextureConfidence`)
    /// so they pass the 0.80 prefill gate while staying tagged in
    /// telemetry; `0.0` means no rules-table match.
    let predictedTextureConfidence: Float

    /// Fit prediction from the attribute classifier.
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

    // MARK: - Confidence-gated category (Build 47)

    /// Category to surface ONLY when the classifier clears the prefill
    /// confidence bar (`AttributePrefill.shouldPrefill`); `nil` otherwise.
    ///
    /// Build 47 — single source of truth shared by BOTH the multi-pick
    /// grid label (`MultiGarmentGridView`) and the details prefill
    /// (`AddItemViewModel.applyPrefill`). Before this, the grid showed
    /// the raw `predictedCategory` while details silently fell back to
    /// `.top` when confidence was below the bar — so an item shown as a
    /// shoe in the grid "transformed" into a top on the details screen
    /// (the TestFlight report). Routing both reads through this property
    /// guarantees the two screens can never disagree, and that nothing
    /// is auto-assigned unless the model is genuinely confident.
    var confidentCategory: ClothingCategory? {
        guard let predictedCategory,
              AttributePrefill.shouldPrefill(predictedCategoryConfidence)
        else { return nil }
        return predictedCategory
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
