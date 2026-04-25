import Foundation
import Observation

/// One "capture" worth of saved garments. Items extracted from the same
/// source photo (same `sourcePhotoId`) collapse into a single session so
/// the wardrobe grid doesn't show 4 visually identical cards when a user
/// multi-picks 4 garments from one mirror selfie. Legacy items where
/// `sourcePhotoId == nil` each become their own 1-item session keyed on
/// `item.id` — never lumped together as a fake "Untitled" group.
struct WardrobeSession: Identifiable, Sendable {
    /// `sourcePhotoId` when present; otherwise the lone item's id. Drives
    /// `Identifiable` for the SwiftUI `ForEach`.
    let id: UUID
    /// The shared `sourcePhotoId` for the group. Nil only when the
    /// underlying items lack one (legacy / single-item captures pre-00008).
    let sourcePhotoId: UUID?
    /// Storage path to the unmasked source photo for the group. Nil for
    /// legacy items pre-00008. UI uses this to render the session header
    /// thumb; nil falls back to a placeholder icon.
    let sourcePhotoPath: String?
    /// Items in the session, sorted oldest-first so the order in the grid
    /// matches the order they were saved during the multi-garment loop.
    let items: [WardrobeItem]
    /// Earliest `createdAt` across the items — used to sort sessions
    /// newest-first at the wardrobe level.
    let createdAt: Date
}

@MainActor
@Observable
final class WardrobeViewModel {
    // MARK: - State

    var items: [WardrobeItem] = []
    var selectedCategory: ClothingCategory?
    var isLoading = false
    var errorMessage: String?
    var showAddItem = false

    // MARK: - Dependencies

    private let wardrobeRepository: any WardrobeRepositoryProtocol
    private let imageService: any ImageServiceProtocol

    init(
        wardrobeRepository: any WardrobeRepositoryProtocol = WardrobeRepository(),
        imageService: any ImageServiceProtocol = ImageService()
    ) {
        self.wardrobeRepository = wardrobeRepository
        self.imageService = imageService
    }

    // MARK: - Computed

    var filteredItems: [WardrobeItem] {
        guard let category = selectedCategory else { return items }
        return items.filter { $0.category == category }
    }

    /// Filtered items grouped by `sourcePhotoId` into capture sessions.
    /// Legacy items with `sourcePhotoId == nil` each become a 1-item
    /// session keyed on the item's own id (so a wardrobe full of legacy
    /// rows doesn't render as one giant fake "session"). Sessions are
    /// sorted newest-first; items inside a session are sorted oldest-first
    /// to preserve the order the user saved them during the multi-garment
    /// loop. A category filter that drops every item in a session also
    /// drops the session itself.
    var sessions: [WardrobeSession] {
        let grouped = Dictionary(grouping: filteredItems) { item in
            item.sourcePhotoId ?? item.id
        }

        return grouped.map { (key, groupItems) in
            let sortedItems = groupItems.sorted { $0.createdAt < $1.createdAt }
            let first = sortedItems.first
            return WardrobeSession(
                id: key,
                sourcePhotoId: first?.sourcePhotoId,
                sourcePhotoPath: first?.sourcePhotoPath,
                items: sortedItems,
                createdAt: sortedItems.first?.createdAt ?? Date()
            )
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    var itemCountText: String {
        let count = filteredItems.count
        if let category = selectedCategory {
            return "\(count) \(category.displayName)"
        }
        return "\(count) item\(count == 1 ? "" : "s")"
    }

    var isEmpty: Bool {
        filteredItems.isEmpty && !isLoading
    }

    // MARK: - Actions

    func loadItems(userId: UUID) async {
        isLoading = true
        errorMessage = nil

        do {
            items = try await wardrobeRepository.fetchItems(userId: userId)
        } catch {
            errorMessage = "Couldn't load your wardrobe. Pull to refresh."
        }

        isLoading = false
    }

    func selectCategory(_ category: ClothingCategory?) {
        selectedCategory = selectedCategory == category ? nil : category
    }

    func archiveItem(_ item: WardrobeItem) async {
        do {
            try await wardrobeRepository.archiveItem(id: item.id)
            items.removeAll { $0.id == item.id }
        } catch {
            errorMessage = "Couldn't archive item."
        }
    }

    func deleteItem(_ item: WardrobeItem, userId: UUID) async {
        do {
            // Delete from DB first — if this fails, no data loss occurs.
            // Images are deleted second; if image cleanup fails, we have a
            // storage leak (orphaned files) but the item is correctly removed.
            try await wardrobeRepository.deleteItem(id: item.id)
            items.removeAll { $0.id == item.id }

            // Best-effort image cleanup — don't fail the delete if this errors.
            // Masked path is nil on legacy (pre-00007) rows; the protocol
            // overload treats nil as "nothing to clean up here."
            do {
                try await imageService.deleteImages(
                    imagePath: item.imagePath,
                    thumbnailPath: item.thumbnailPath,
                    maskedImagePath: item.maskedImagePath
                )
            } catch {
                // Storage leak is acceptable; item is already deleted from DB
                errorMessage = "Item deleted, but image cleanup failed."
            }
        } catch {
            errorMessage = "Couldn't delete item."
        }
    }

    func thumbnailURL(for item: WardrobeItem) async -> URL? {
        // Prefer the cropped cutout (maskedImagePath) so two items extracted
        // from the same source photo render distinctly in the grid. Legacy
        // rows pre-migration 00007 fall back to the framed thumbnail.
        try? await imageService.signedURL(for: ItemCardView.displayPath(for: item))
    }

    func fullImageURL(for item: WardrobeItem) async -> URL? {
        try? await imageService.signedURL(for: item.imagePath)
    }

    /// Sign a session header's source photo path. Sessions share one
    /// `sourcePhotoPath` across N items, so callers cache the resulting
    /// URL by path rather than by item.
    func sourcePhotoURL(for path: String) async -> URL? {
        try? await imageService.signedURL(for: path)
    }
}
