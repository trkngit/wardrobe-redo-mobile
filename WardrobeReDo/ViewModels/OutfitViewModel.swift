import Foundation
import Observation

/// View-facing model combining an outfit with its resolved items.
struct DailyOutfit: Identifiable, Sendable {
    let outfit: Outfit
    let slots: [OutfitSlot]
    let items: [WardrobeItem]
    var id: UUID { outfit.id }
}

/// Orchestrates daily outfit generation, loading, reactions,
/// and "mark as worn" for the Outfits tab.
@MainActor
@Observable
final class OutfitViewModel {

    // MARK: - Published State

    var dailyOutfits: [DailyOutfit] = []
    var isLoading = false
    var isGenerating = false
    var errorMessage: String?
    var selectedOccasion: Occasion = .casual

    // MARK: - Thumbnail Cache

    /// Maps wardrobe item ID → signed thumbnail URL.
    var thumbnailURLs: [UUID: URL] = [:]

    // MARK: - Dependencies

    private let outfitRepository = OutfitRepository()
    private let wardrobeRepository = WardrobeRepository()
    private let generationService = OutfitGenerationService()
    private let imageService = ImageService()

    // MARK: - Computed

    var isEmpty: Bool { dailyOutfits.isEmpty && !isLoading && !isGenerating }
    var todayDateString: String { OutfitRepository.todayDateString() }

    // MARK: - Load Today's Outfits

    /// Fetch previously generated outfits for today, resolving item references.
    func loadOutfits(userId: UUID) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let dateString = todayDateString
            let outfits = try await outfitRepository.fetchOutfitsByDate(
                userId: userId, date: dateString
            )

            guard !outfits.isEmpty else {
                dailyOutfits = []
                return
            }

            // Batch-fetch all slots
            let slotsByOutfit = try await outfitRepository.fetchSlotsForOutfits(
                outfitIds: outfits.map(\.id)
            )

            // Collect unique item IDs and batch-fetch
            let allItemIds = Array(Set(
                slotsByOutfit.values.flatMap { $0 }.map(\.wardrobeItemId)
            ))
            let items = try await wardrobeRepository.fetchItems(ids: allItemIds)
            let itemsById = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })

            // Assemble DailyOutfit view models
            dailyOutfits = outfits.map { outfit in
                let slots = slotsByOutfit[outfit.id] ?? []
                let outfitItems = slots.compactMap { itemsById[$0.wardrobeItemId] }
                return DailyOutfit(outfit: outfit, slots: slots, items: outfitItems)
            }

            // Pre-load thumbnails
            await loadThumbnails()
        } catch {
            errorMessage = "Couldn't load today's outfits."
        }
    }

    // MARK: - Generate Daily Outfits

    /// Run the generation engine, save results, and reload.
    func generateDailyOutfits(userId: UUID) async {
        isGenerating = true
        errorMessage = nil
        defer { isGenerating = false }

        do {
            // Fetch wardrobe + recent item IDs for versatility scoring
            let wardrobeItems = try await wardrobeRepository.fetchItems(userId: userId)
            let recentIds = try await outfitRepository.fetchRecentItemIds(userId: userId)

            // Generate candidates
            let candidates = await generationService.generateDailyOutfits(
                items: wardrobeItems,
                occasion: selectedOccasion,
                recentItemIds: recentIds
            )

            guard !candidates.isEmpty else {
                errorMessage = "Not enough items to generate outfits. Add more to your wardrobe!"
                return
            }

            // Persist
            _ = try await generationService.saveDailyOutfits(
                candidates: candidates,
                userId: userId
            )

            // Reload from database to get server timestamps
            await loadOutfits(userId: userId)
        } catch {
            errorMessage = "Generation failed. Please try again."
        }
    }

    // MARK: - Reactions

    /// Save user reaction (love / like / skip).
    func react(outfitId: UUID, reaction: String) async {
        do {
            // Toggle: tapping the same reaction clears it
            let currentReaction = dailyOutfits.first(where: { $0.id == outfitId })?.outfit.reaction
            let newReaction = currentReaction == reaction ? nil : reaction

            try await outfitRepository.updateReaction(outfitId: outfitId, reaction: newReaction)

            // Update local state
            if let index = dailyOutfits.firstIndex(where: { $0.id == outfitId }) {
                let old = dailyOutfits[index]
                let updatedOutfit = Outfit(
                    id: old.outfit.id,
                    userId: old.outfit.userId,
                    archetypeId: old.outfit.archetypeId,
                    editorialName: old.outfit.editorialName,
                    editorialDescription: old.outfit.editorialDescription,
                    date: old.outfit.date,
                    score: old.outfit.score,
                    scoreBreakdown: old.outfit.scoreBreakdown,
                    reaction: newReaction,
                    isWorn: old.outfit.isWorn,
                    createdAt: old.outfit.createdAt
                )
                dailyOutfits[index] = DailyOutfit(
                    outfit: updatedOutfit, slots: old.slots, items: old.items
                )
            }
        } catch {
            errorMessage = "Couldn't save reaction."
        }
    }

    // MARK: - Mark as Worn

    func toggleWorn(outfitId: UUID) async {
        do {
            guard let index = dailyOutfits.firstIndex(where: { $0.id == outfitId }) else { return }
            let old = dailyOutfits[index]
            let newWorn = !old.outfit.isWorn

            try await outfitRepository.markAsWorn(outfitId: outfitId, isWorn: newWorn)

            let updatedOutfit = Outfit(
                id: old.outfit.id,
                userId: old.outfit.userId,
                archetypeId: old.outfit.archetypeId,
                editorialName: old.outfit.editorialName,
                editorialDescription: old.outfit.editorialDescription,
                date: old.outfit.date,
                score: old.outfit.score,
                scoreBreakdown: old.outfit.scoreBreakdown,
                reaction: old.outfit.reaction,
                isWorn: newWorn,
                createdAt: old.outfit.createdAt
            )
            dailyOutfits[index] = DailyOutfit(
                outfit: updatedOutfit, slots: old.slots, items: old.items
            )
        } catch {
            errorMessage = "Couldn't update worn status."
        }
    }

    // MARK: - Thumbnails

    /// Pre-load signed thumbnail URLs for all items across all outfits.
    func loadThumbnails() async {
        for outfit in dailyOutfits {
            for item in outfit.items {
                if thumbnailURLs[item.id] == nil {
                    thumbnailURLs[item.id] = try? await imageService.signedURL(
                        for: item.thumbnailPath
                    )
                }
            }
        }
    }

    func thumbnailURL(for item: WardrobeItem) async -> URL? {
        if let cached = thumbnailURLs[item.id] { return cached }
        let url = try? await imageService.signedURL(for: item.thumbnailPath)
        thumbnailURLs[item.id] = url
        return url
    }
}
