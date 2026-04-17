import Foundation
import Observation

/// Manages the "What goes with this?" hero-piece matching flow:
/// item selection → outfit generation → save results.
@MainActor
@Observable
final class MatchingViewModel {

    // MARK: - State

    var wardrobeItems: [WardrobeItem] = []
    var selectedItem: WardrobeItem?
    var matchResults: [OutfitCandidate] = []
    var selectedOccasion: Occasion = .casual
    var selectedCategory: ClothingCategory?
    var isLoading = false
    var isMatching = false
    var errorMessage: String?
    /// Reason the most recent matching attempt failed.
    /// `nil` after a successful run, or before any item is selected.
    var lastFailure: GenerationFailure?

    /// Thumbnail URL cache shared across hero picker and result items.
    var thumbnailURLs: [UUID: URL] = [:]

    /// Tracks which match results have been saved as outfits.
    var savedResultIndices: Set<Int> = []

    // MARK: - Dependencies

    private let wardrobeRepository: any WardrobeRepositoryProtocol
    private let outfitRepository: any OutfitRepositoryProtocol
    private let generationService: OutfitGenerationService
    private let imageService: any ImageServiceProtocol

    init(
        wardrobeRepository: any WardrobeRepositoryProtocol = WardrobeRepository(),
        outfitRepository: any OutfitRepositoryProtocol = OutfitRepository(),
        generationService: OutfitGenerationService = OutfitGenerationService(),
        imageService: any ImageServiceProtocol = ImageService()
    ) {
        self.wardrobeRepository = wardrobeRepository
        self.outfitRepository = outfitRepository
        self.generationService = generationService
        self.imageService = imageService
    }

    // MARK: - Computed

    var filteredItems: [WardrobeItem] {
        guard let category = selectedCategory else { return wardrobeItems }
        return wardrobeItems.filter { $0.category == category }
    }

    var hasResults: Bool { !matchResults.isEmpty }

    // MARK: - Load Wardrobe

    func loadWardrobe(userId: UUID) async {
        isLoading = true
        defer { isLoading = false }

        do {
            wardrobeItems = try await wardrobeRepository.fetchItems(userId: userId)
            await loadThumbnails(for: wardrobeItems)
        } catch {
            errorMessage = "Couldn't load wardrobe."
        }
    }

    // MARK: - Select Hero Item

    /// Select an item as the hero piece and auto-trigger matching.
    func selectItem(_ item: WardrobeItem, userId: UUID) async {
        // Toggle: tapping the same item deselects it
        if selectedItem?.id == item.id {
            selectedItem = nil
            matchResults = []
            savedResultIndices = []
            return
        }

        selectedItem = item
        matchResults = []
        savedResultIndices = []
        await findMatches(userId: userId)
    }

    // MARK: - Find Matches

    func findMatches(userId: UUID) async {
        guard let hero = selectedItem else { return }

        isMatching = true
        errorMessage = nil
        lastFailure = nil
        defer { isMatching = false }

        // Pre-check wardrobe size: matching needs the hero plus at least
        // one supporting piece. Surface a precise error instead of the
        // generic "no matching outfits" message when the wardrobe is bare.
        let supportingCount = wardrobeItems.filter { !$0.isArchived && $0.id != hero.id }.count
        if supportingCount < 1 {
            applyFailure(.wardrobeTooSmall(itemCount: wardrobeItems.count))
            matchResults = []
            return
        }

        do {
            let recentIds = try await outfitRepository.fetchRecentItemIds(userId: userId)

            let results = await generationService.matchOutfits(
                heroItem: hero,
                allItems: wardrobeItems,
                occasion: selectedOccasion,
                recentItemIds: recentIds
            )

            matchResults = results

            // Pre-load thumbnails for result items
            let resultItems = results.flatMap(\.items)
            await loadThumbnails(for: resultItems)

            if results.isEmpty {
                applyFailure(.noCompatibleOutfits)
            }
        } catch {
            applyFailure(.unknown(String(describing: error)))
        }
    }

    /// Surface a failure to both the legacy `errorMessage` and the
    /// richer `lastFailure` state.
    private func applyFailure(_ failure: GenerationFailure) {
        lastFailure = failure
        errorMessage = failure.userMessage
    }

    // MARK: - Save as Outfit

    /// Persist a match result as a saved outfit.
    func saveAsOutfit(at index: Int, userId: UUID) async {
        guard index < matchResults.count else { return }
        let candidate = matchResults[index]

        do {
            _ = try await generationService.saveDailyOutfits(
                candidates: [candidate],
                userId: userId
            )
            savedResultIndices.insert(index)
        } catch {
            errorMessage = "Couldn't save outfit."
        }
    }

    // MARK: - Occasion Change

    func changeOccasion(_ occasion: Occasion, userId: UUID) async {
        selectedOccasion = occasion
        if selectedItem != nil {
            await findMatches(userId: userId)
        }
    }

    // MARK: - Thumbnails

    func loadThumbnails(for items: [WardrobeItem]) async {
        for item in items where thumbnailURLs[item.id] == nil {
            thumbnailURLs[item.id] = try? await imageService.signedURL(
                for: item.thumbnailPath
            )
        }
    }
}
