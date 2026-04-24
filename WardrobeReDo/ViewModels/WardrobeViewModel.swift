import Foundation
import Observation

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
        try? await imageService.signedURL(for: item.thumbnailPath)
    }

    func fullImageURL(for item: WardrobeItem) async -> URL? {
        try? await imageService.signedURL(for: item.imagePath)
    }
}
