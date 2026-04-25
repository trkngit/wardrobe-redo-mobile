import Foundation
import UIKit
import os.log

/// Persists an in-progress multi-pick batch to disk so the user
/// doesn't lose their progress when iOS evicts the app from memory.
///
/// **Why this exists.** The multi-garment capture flow lets the user
/// pick N items from a single photo, then walks them through the per-
/// item details form one proposal at a time. The queue, the source-
/// photo provenance ID, and the per-proposal masked cutouts all live
/// in `AddItemViewModel` properties — purely in-memory. If iOS
/// jetsams the app between items (incoming call, Slack notification,
/// other memory-tight context), the queue dies and the user sees an
/// empty form on next launch with no resume affordance.
///
/// **What we persist.** A single JSON file under
/// `Library/Caches/wardrobe-redo/pending-batch.json`. Caches is the
/// right scope: ephemeral by design (iOS may purge under storage
/// pressure, which is fine — losing the queue 3 days later is the
/// same UX as never having it), and not iCloud-backed (no value to
/// the user across devices).
///
/// **What we DON'T persist.** The `mask: CVPixelBuffer?` slot on
/// each proposal — used only by the mask-touchup re-edit affordance,
/// which the user can't access mid-batch anyway. After save, the
/// user can edit the saved item and re-run touchup on the stored
/// `image_path`. This trims tens of MB from the JSON payload.
///
/// **Expiry.** Anything older than `expiry` is treated as stale and
/// cleared on load. 1 hour is the right default for a multi-pick
/// batch — by then the user has either finished or moved on.
@MainActor
enum BatchPersistenceService {
    /// Stale-batch ceiling. After this duration we discard the
    /// persisted state on next load. 1 hour is comfortable: covers
    /// the typical "got distracted, came back" scenario without
    /// resurrecting a batch the user has clearly abandoned.
    static let expiry: TimeInterval = 60 * 60

    private static let logger = Logger(
        subsystem: "com.wardroberedo",
        category: "BatchPersistence"
    )

    /// Wipe any persisted batch state. Called on confirmed batch end
    /// (all-saved, all-skipped, cancelled) and on stale loads.
    static func clear() {
        do {
            let url = try fileURL()
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
                logger.info("batch.clear: removed persisted batch")
            }
        } catch {
            logger.warning("batch.clear.failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Persist a snapshot of the current batch. Called after every
    /// queue mutation (`startNextProposal`, `save`, `onSkipCurrent`)
    /// so a force-quit between items keeps at most one item of work
    /// at risk. Errors are swallowed and logged — persistence
    /// failures shouldn't surface in the UI; the worst case is the
    /// user loses their batch on next launch, which is the same as
    /// the pre-PR behaviour.
    static func save(_ snapshot: BatchSnapshot) {
        do {
            let data = try JSONEncoder().encode(snapshot)
            let url = try fileURL()
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: [.atomic])
            logger.info("batch.save: \(snapshot.queue.count, privacy: .public) pending, \(snapshot.savedCount, privacy: .public) saved, \(snapshot.skippedCount, privacy: .public) skipped")
        } catch {
            logger.warning("batch.save.failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Load any persisted batch. Returns `nil` when no batch exists
    /// or when the persisted batch is older than `expiry`. Stale
    /// batches are cleared from disk in the same call so the next
    /// load sees a clean state.
    static func load() -> BatchSnapshot? {
        let url: URL
        do {
            url = try fileURL()
        } catch {
            return nil
        }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            let snapshot = try JSONDecoder().decode(BatchSnapshot.self, from: data)
            let age = Date().timeIntervalSince(snapshot.createdAt)
            if age > expiry {
                logger.info("batch.load: stale (\(age, privacy: .public)s old), discarding")
                clear()
                return nil
            }
            logger.info("batch.load: restored \(snapshot.queue.count, privacy: .public) pending items")
            return snapshot
        } catch {
            logger.warning("batch.load.failed: \(error.localizedDescription, privacy: .public)")
            // Schema-mismatch (we changed BatchSnapshot fields) or
            // file corruption — clear so next launch is clean.
            clear()
            return nil
        }
    }

    /// Filename = single per-user file under Caches. We don't
    /// support multi-user-on-one-device (each user signs in fresh),
    /// so user-namespacing isn't needed yet.
    private static func fileURL() throws -> URL {
        let caches = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return caches
            .appendingPathComponent("wardrobe-redo", isDirectory: true)
            .appendingPathComponent("pending-batch.json", isDirectory: false)
    }
}

// MARK: - Snapshot types

/// Codable mirror of `MaskProposal` minus the CVPixelBuffer mask
/// slot. The masked cutout (PNG) IS persisted because the multi-pick
/// details flow needs it to render the per-item preview.
struct PersistedProposal: Codable, Sendable {
    let id: UUID
    /// PNG bytes of `MaskProposal.maskedImage`. Encoded via
    /// `proposal.maskedImage.pngData()` at persist time, restored via
    /// `UIImage(data:)` at load time.
    let maskedImagePNG: Data
    let confidence: ExtractionConfidence
    let predictedCategory: ClothingCategory?
    let predictedCategoryConfidence: Float
    let predictedSubcategory: ClothingSubcategory?
    let predictedTexture: TextureType?
    let predictedTextureConfidence: Float
    let predictedFit: FitAttribute?
    let predictedFitConfidence: Float
    let predictedSeasons: [Season]
    let predictedOccasions: [Occasion]
    let boundingBox: CGRect
    let detectionScore: Float
    let modelClassRaw: String

    /// Pack a live `MaskProposal` into its persistent form. Returns
    /// nil if PNG encoding fails (degenerate UIImages).
    init?(from proposal: MaskProposal) {
        guard let png = proposal.maskedImage.pngData() else { return nil }
        self.id = proposal.id
        self.maskedImagePNG = png
        self.confidence = proposal.confidence
        self.predictedCategory = proposal.predictedCategory
        self.predictedCategoryConfidence = proposal.predictedCategoryConfidence
        self.predictedSubcategory = proposal.predictedSubcategory
        self.predictedTexture = proposal.predictedTexture
        self.predictedTextureConfidence = proposal.predictedTextureConfidence
        self.predictedFit = proposal.predictedFit
        self.predictedFitConfidence = proposal.predictedFitConfidence
        self.predictedSeasons = proposal.predictedSeasons
        self.predictedOccasions = proposal.predictedOccasions
        self.boundingBox = proposal.boundingBox
        self.detectionScore = proposal.detectionScore
        self.modelClassRaw = proposal.modelClassRaw
    }

    /// Hydrate back into a live `MaskProposal`. Returns nil if the
    /// PNG bytes can't be decoded into a UIImage (corrupted file).
    func toProposal() -> MaskProposal? {
        guard let image = UIImage(data: maskedImagePNG) else { return nil }
        return MaskProposal(
            id: id,
            maskedImage: image,
            mask: nil, // not persisted; touchup re-edit is post-save
            confidence: confidence,
            predictedCategory: predictedCategory,
            predictedCategoryConfidence: predictedCategoryConfidence,
            predictedSubcategory: predictedSubcategory,
            predictedTexture: predictedTexture,
            predictedTextureConfidence: predictedTextureConfidence,
            predictedFit: predictedFit,
            predictedFitConfidence: predictedFitConfidence,
            predictedSeasons: predictedSeasons,
            predictedOccasions: predictedOccasions,
            boundingBox: boundingBox,
            detectionScore: detectionScore,
            modelClassRaw: modelClassRaw
        )
    }
}

/// Snapshot of an in-progress multi-pick batch. Includes everything
/// `AddItemViewModel.startNextProposal()` needs to resume the queue
/// at the same item the user was on when the app died.
struct BatchSnapshot: Codable, Sendable {
    /// Owner of the batch — pinned so a sign-out / sign-in-as-other
    /// flow can detect the mismatch and discard.
    let userId: UUID
    /// Provenance ID of the source capture. Re-used so the resumed
    /// batch's saved items share `source_photo_id` with the items
    /// already saved before the crash.
    let sourcePhotoId: UUID
    /// Storage path of the source photo if it was uploaded already
    /// (subsequent saves echo this back to ImageService.upload). Nil
    /// before the first save in the batch.
    let sourcePhotoPath: String?
    /// PNG bytes of the source photo for the details-step image
    /// preview when the user resumes — without this the form would
    /// have no fallback image while `currentProposal.maskedImage`
    /// loads. Encoded as PNG to preserve fidelity.
    let sourcePhotoPNG: Data?
    /// When the snapshot was last persisted. Used to expire stale
    /// batches.
    let createdAt: Date
    /// Original total at batch start — pinned so `Item N of T`
    /// progress matches what the user originally committed to.
    let total: Int
    /// Items already persisted to Supabase before the crash.
    let savedCount: Int
    /// Items the user explicitly skipped before the crash.
    let skippedCount: Int
    /// Remaining items in queue order (NOT including the
    /// current proposal — that's `currentProposal` below).
    let queue: [PersistedProposal]
    /// The proposal the user was actively detailing at persist time.
    /// Nil between batches; non-nil when a batch is in flight.
    let currentProposal: PersistedProposal?
}
