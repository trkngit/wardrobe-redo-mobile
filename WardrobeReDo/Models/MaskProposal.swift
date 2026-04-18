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
