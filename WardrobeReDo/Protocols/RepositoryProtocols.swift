import Foundation
import UIKit
import SwiftUI
import PhotosUI

// MARK: - Repository Protocols for Dependency Injection

/// WardrobeRepository interface for ViewModels.
@MainActor
protocol WardrobeRepositoryProtocol: Sendable {
    func fetchItems(userId: UUID, category: ClothingCategory?) async throws -> [WardrobeItem]
    func fetchItems(ids: [UUID]) async throws -> [WardrobeItem]
    func archiveItem(id: UUID) async throws
    func deleteItem(id: UUID) async throws
    func insertItem(_ item: NewWardrobeItem) async throws -> WardrobeItem
    /// Updates a row with the set of `WardrobeItemUpdate` columns the
    /// caller chose to pass (nils are treated as "don't touch"). Returns
    /// the updated row so VMs can re-drive UI from the server's view
    /// rather than assume local state is authoritative.
    func updateItem(id: UUID, updates: WardrobeItemUpdate) async throws -> WardrobeItem
}

extension WardrobeRepositoryProtocol {
    func fetchItems(userId: UUID) async throws -> [WardrobeItem] {
        try await fetchItems(userId: userId, category: nil)
    }
}

/// OutfitRepository interface for ViewModels.
@MainActor
protocol OutfitRepositoryProtocol: Sendable {
    func fetchOutfitsByDate(userId: UUID, date: String) async throws -> [Outfit]
    func fetchSlotsForOutfits(outfitIds: [UUID]) async throws -> [UUID: [OutfitSlot]]
    func fetchRecentItemIds(userId: UUID, days: Int) async throws -> Set<UUID>
    /// Build 6: returns every unordered item-pair the user has worn
    /// together across their most-recent `limit` outfits. Powers
    /// the VersatilityScorer novelty bonus.
    func fetchRecentItemPairs(userId: UUID, limit: Int) async throws -> Set<UnorderedItemPair>
    func updateReaction(outfitId: UUID, reaction: String?) async throws
    func markAsWorn(outfitId: UUID, isWorn: Bool) async throws
    /// Build 6: bump `wear_count` + `last_worn_at` for the supplied
    /// wardrobe-item IDs. Fired when the user toggles an outfit
    /// from un-worn to worn (NOT the reverse direction — wear is
    /// monotonically increasing).
    func incrementWearCounts(itemIds: [UUID]) async throws
    func hasOutfitsForDate(userId: UUID, date: String) async throws -> Bool
    /// Delete every outfit a user has on a given date (cascade-deletes
    /// `outfit_slots`). Used by the "Generate New Outfits" path so a
    /// re-roll doesn't get blocked by `hasOutfitsForDate` returning the
    /// previous batch.
    func deleteOutfits(userId: UUID, date: String) async throws
}

extension OutfitRepositoryProtocol {
    func fetchRecentItemIds(userId: UUID) async throws -> Set<UUID> {
        try await fetchRecentItemIds(userId: userId, days: 7)
    }

    /// Convenience: 30-outfit history matches the Phase 5.1 plan.
    func fetchRecentItemPairs(userId: UUID) async throws -> Set<UnorderedItemPair> {
        try await fetchRecentItemPairs(userId: userId, limit: 30)
    }
}

/// ImageService interface for ViewModels.
///
/// `upload` returns four storage paths. `maskedImagePath` is nil when
/// background extraction was skipped (simulator / legacy path) — callers
/// must handle that case and pass nil through to `NewWardrobeItem`.
/// `sourcePhotoPath` is populated iff the caller supplied a
/// `sourcePhotoId` (i.e. a multi-garment capture). See migration 00008
/// for the provenance column the path backs.
@MainActor
protocol ImageServiceProtocol: Sendable {
    func signedURL(for path: String, expiresIn: Int) async throws -> URL
    func deleteImages(imagePath: String, thumbnailPath: String, maskedImagePath: String?) async throws
    /// Upload the per-item artifacts (original + thumbnail + optional
    /// masked PNG). When `sourcePhotoId` is non-nil, also uploads the
    /// unmasked original to `{userId}/source/{sourcePhotoId}/original.jpg`
    /// on the *first* call for that capture; subsequent calls pass the
    /// previously-returned path back via `existingSourcePhotoPath` so
    /// storage usage stays proportional to *captures*, not garments.
    func upload(
        processed: ProcessedImage,
        userId: UUID,
        itemId: UUID,
        sourcePhotoId: UUID?,
        existingSourcePhotoPath: String?
    ) async throws -> (imagePath: String, thumbnailPath: String, maskedImagePath: String?, sourcePhotoPath: String?)
    func processImage(_ image: UIImage) async -> ProcessedImage?
    func loadImage(from item: PhotosPickerItem) async -> UIImage?
    /// Apply a user-edited mask on top of an already-processed image and
    /// re-run color extraction. Used by the MaskTouchupView flow to fold
    /// brush strokes into the saved palette without re-running Vision.
    func updateMasked(processed: ProcessedImage, editedMask: UIImage) async -> ProcessedImage?
}

extension ImageServiceProtocol {
    func signedURL(for path: String) async throws -> URL {
        try await signedURL(for: path, expiresIn: 3600)
    }

    /// Convenience shim for call sites that don't have a masked path
    /// (e.g. archiving a legacy item whose row predates migration 00007).
    func deleteImages(imagePath: String, thumbnailPath: String) async throws {
        try await deleteImages(imagePath: imagePath, thumbnailPath: thumbnailPath, maskedImagePath: nil)
    }

    /// Back-compat shim for single-item capture callers. Skips the
    /// source-photo upload entirely and returns the 3-tuple the pre-00008
    /// API used. New code in the multi-garment loop calls the 5-arg
    /// version directly.
    func upload(
        processed: ProcessedImage,
        userId: UUID,
        itemId: UUID
    ) async throws -> (imagePath: String, thumbnailPath: String, maskedImagePath: String?) {
        let paths = try await upload(
            processed: processed,
            userId: userId,
            itemId: itemId,
            sourcePhotoId: nil,
            existingSourcePhotoPath: nil
        )
        return (paths.imagePath, paths.thumbnailPath, paths.maskedImagePath)
    }
}
