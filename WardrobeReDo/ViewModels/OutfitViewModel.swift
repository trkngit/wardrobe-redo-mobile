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
    /// True while the "Generate New Outfits" button is mid-flight: the
    /// VM is deleting today's cached batch and regenerating against a
    /// fresh seed. Distinct from `isGenerating` so views can show a
    /// button-local spinner without flipping the whole-screen
    /// "Curating your outfits…" state.
    var isRegenerating = false
    var errorMessage: String?
    /// Reason the most recent generation attempt failed.
    /// `nil` after a successful run, or before the first attempt.
    /// Views should prefer this over `errorMessage` for empty-state copy
    /// — it carries enough information to show a Try-Again button and
    /// the right wording for "wardrobe too small" vs "no compatible
    /// outfits" vs "network timeout".
    var lastFailure: GenerationFailure?
    var selectedOccasion: Occasion = .casual

    // MARK: - Thumbnail Cache

    /// Maps wardrobe item ID → signed thumbnail URL.
    var thumbnailURLs: [UUID: URL] = [:]

    // MARK: - Dependencies

    private let outfitRepository: any OutfitRepositoryProtocol
    private let wardrobeRepository: any WardrobeRepositoryProtocol
    private let generationService: OutfitGenerationService
    private let imageService: any ImageServiceProtocol

    init(
        outfitRepository: any OutfitRepositoryProtocol = OutfitRepository(),
        wardrobeRepository: any WardrobeRepositoryProtocol = WardrobeRepository(),
        generationService: OutfitGenerationService = OutfitGenerationService(),
        imageService: any ImageServiceProtocol = ImageService()
    ) {
        self.outfitRepository = outfitRepository
        self.wardrobeRepository = wardrobeRepository
        self.generationService = generationService
        self.imageService = imageService
    }

    // MARK: - Computed

    var isEmpty: Bool { dailyOutfits.isEmpty && !isLoading && !isGenerating }
    var todayDateString: String { OutfitRepository.todayDateString() }

    // MARK: - Load Today's Outfits

    /// Fetch previously generated outfits for today, resolving item references.
    func loadOutfits(userId: UUID) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        // One-shot legacy-tag backfill. No-op on subsequent launches
        // (UserDefaults flag). Runs BEFORE the fetch so the user sees
        // the broader occasion / season tags reflected in the picks
        // produced by the current generate cycle.
        await AttributeBackfillService.runIfNeeded(
            userId: userId,
            wardrobeRepository: wardrobeRepository
        )

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

            // Update widget with top outfit
            if let top = dailyOutfits.first {
                WidgetDataService.updateWidget(
                    outfitName: top.outfit.editorialName,
                    score: Int(top.outfit.score * 100),
                    itemCount: top.items.count
                )
            }
        } catch {
            errorMessage = "Couldn't load today's outfits."
        }
    }

    // MARK: - Generate Daily Outfits

    /// Run the generation engine, save results, and reload.
    /// Includes a 60-second timeout and duplicate-generation guard.
    ///
    /// On failure sets both `errorMessage` (legacy) and `lastFailure`
    /// (preferred) so the empty-state can render reason-specific copy
    /// and a Try-Again button.
    func generateDailyOutfits(userId: UUID) async {
        await runGeneration(userId: userId, seed: nil)
    }

    /// "Generate New Outfits" — explicitly delete today's cached batch
    /// and regenerate against a fresh `seed`. Distinct from
    /// `generateDailyOutfits(userId:)` because it bypasses the
    /// `hasOutfitsForDate` guard (which would otherwise short-circuit
    /// to the cached results) AND drives a different archetype ordering
    /// via the seeded RNG in `OutfitGenerationService`.
    ///
    /// Sets `isRegenerating` (button-local spinner) instead of
    /// `isGenerating` (whole-screen "Curating…" state).
    func regenerateDailyOutfits(userId: UUID) async {
        isRegenerating = true
        defer { isRegenerating = false }

        let dateString = todayDateString
        do {
            try await outfitRepository.deleteOutfits(userId: userId, date: dateString)
        } catch {
            applyFailure(.unknown(String(describing: error)))
            return
        }

        // Drop the old DailyOutfit cards immediately so the UI doesn't
        // briefly show stale results between delete and reload.
        dailyOutfits = []

        await runGeneration(userId: userId, seed: UInt64.random(in: .min ... .max))
    }

    /// Shared generation path for both the first-time and regenerate
    /// flows. The two callers differ only in whether they pre-clear the
    /// cache and what seed they supply.
    private func runGeneration(userId: UUID, seed: UInt64?) async {
        isGenerating = true
        errorMessage = nil
        lastFailure = nil
        defer { isGenerating = false }

        do {
            // Guard: don't regenerate if outfits already exist for today.
            // Bypassed implicitly by `regenerateDailyOutfits` because
            // it deletes the cached batch first.
            let dateString = todayDateString
            let alreadyExists = try await outfitRepository.hasOutfitsForDate(
                userId: userId, date: dateString
            )
            if alreadyExists {
                await loadOutfits(userId: userId)
                return
            }

            // Pre-check wardrobe size for an actionable error message.
            // The generation service silently returns [] for < 2 items
            // — without this we'd surface a generic "timed out" instead.
            let wardrobeItems = try await wardrobeRepository.fetchItems(userId: userId)
            let activeCount = wardrobeItems.filter { !$0.isArchived }.count
            if activeCount < 2 {
                applyFailure(.wardrobeTooSmall(itemCount: activeCount))
                return
            }

            // Race generation against a 60-second timeout. The outcome
            // enum lets us distinguish empty results from real timeouts.
            let outcome: GenerationOutcome = await withTaskGroup(of: GenerationOutcome.self) {
                [outfitRepository, generationService, selectedOccasion, wardrobeItems, seed] group in
                group.addTask {
                    do {
                        let recentIds = try await outfitRepository.fetchRecentItemIds(userId: userId)

                        let candidates = await generationService.generateDailyOutfits(
                            items: wardrobeItems,
                            occasion: selectedOccasion,
                            recentItemIds: recentIds,
                            seed: seed
                        )

                        if candidates.isEmpty { return .empty }

                        _ = try await generationService.saveDailyOutfits(
                            candidates: candidates,
                            userId: userId
                        )
                        return .success
                    } catch {
                        return .error(String(describing: error))
                    }
                }
                group.addTask {
                    try? await Task.sleep(for: .seconds(60))
                    return .timeout
                }

                let result = await group.next()!
                group.cancelAll()
                return result
            }

            switch outcome {
            case .success:
                await loadOutfits(userId: userId)
            case .empty:
                applyFailure(.noCompatibleOutfits)
            case .timeout:
                applyFailure(.networkTimeout)
            case .error(let msg):
                applyFailure(.unknown(msg))
            }
        } catch {
            applyFailure(.unknown(String(describing: error)))
        }
    }

    /// Surface a failure to both the legacy `errorMessage` (kept for
    /// existing tests) and the richer `lastFailure` state (preferred by
    /// new view code).
    private func applyFailure(_ failure: GenerationFailure) {
        lastFailure = failure
        errorMessage = failure.userMessage
    }

    // MARK: - Reactions

    /// Save user reaction (love / like / skip).
    func react(outfitId: UUID, reaction: String) async {
        do {
            // Guard: skip unknown outfit IDs to avoid wasted network calls
            guard let index = dailyOutfits.firstIndex(where: { $0.id == outfitId }) else { return }

            // Toggle: tapping the same reaction clears it
            let currentReaction = dailyOutfits[index].outfit.reaction
            let newReaction = currentReaction == reaction ? nil : reaction

            try await outfitRepository.updateReaction(outfitId: outfitId, reaction: newReaction)

            // Update local state (index already validated by guard above)
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
