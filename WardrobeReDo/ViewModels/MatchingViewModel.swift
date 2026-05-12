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
    /// Build 6 — vibe preset for the match flow. Mirrors
    /// `OutfitViewModel.selectedVibe`: ephemeral per-generation,
    /// seeded from `profile.defaultVibe` by the view. The slider
    /// re-ranks the five returned matches without changing which
    /// archetype the engine picks.
    var selectedVibe: VibeStop = .balanced
    var selectedCategory: ClothingCategory?
    var isLoading = false
    var isMatching = false
    var errorMessage: String?
    /// Reason the most recent matching attempt failed.
    /// `nil` after a successful run, or before any item is selected.
    var lastFailure: GenerationFailure?

    /// Build 7 — transient post-regen confirmation. Set by
    /// `requestRegeneration(reason: .pickerChange)` after a
    /// successful debounced regen so the view can mount a brief
    /// `StatusToast`. Nil otherwise.
    var statusToastMessage: String?

    /// Thumbnail URL cache shared across hero picker and result items.
    var thumbnailURLs: [UUID: URL] = [:]

    /// Tracks which match results have been saved as outfits.
    var savedResultIndices: Set<Int> = []

    // MARK: - Build 7 — regeneration plumbing

    /// Active regeneration task, if any. Cancelled at the head of
    /// every new `requestRegeneration` so rapid picker changes
    /// collapse into a single beam search.
    ///
    /// `internal` visibility (not `private`) so tests can await
    /// `matchingTask?.value` and assert end-state deterministically
    /// instead of racing a `Task.sleep`. Production callers
    /// observe `isMatching` + the data fields the task mutates.
    var matchingTask: Task<Void, Never>?

    /// Recent-item history cache. Same shape as
    /// `OutfitViewModel.cachedRecentIds`. Invalidated when the
    /// user saves a match result as a real outfit.
    private var cachedRecentIds: Set<UUID>?
    private var cachedRecentPairs: Set<UnorderedItemPair>?

    /// Why the regeneration fired. Mirrors `OutfitViewModel`.
    enum RegenerationReason: Sendable {
        case pickerChange
        case surpriseMe
    }

    /// 250 ms — matches `BackgroundQualityMonitor.debounceInterval`
    /// and `OutfitViewModel.regenerationDebounce` so picker
    /// responsiveness feels identical across the two surfaces.
    private let regenerationDebounce: Duration = .milliseconds(250)

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

        VibeTelemetry.logGenerationVibe(selectedVibe, source: "match")
        OccasionTelemetry.logGenerationOccasion(selectedOccasion, source: "match")

        // Build 7 — same recent-item history cache as
        // `OutfitViewModel`. Avoids re-fetching from Supabase on
        // every picker tap during a tight regen sequence.
        if cachedRecentIds == nil {
            async let idsTask = outfitRepository.fetchRecentItemIds(userId: userId)
            async let pairsTask = outfitRepository.fetchRecentItemPairs(userId: userId)
            cachedRecentIds = (try? await idsTask) ?? []
            cachedRecentPairs = (try? await pairsTask) ?? []
        }
        let recentIds = cachedRecentIds ?? []
        let recentPairs = cachedRecentPairs ?? []

        let results = await generationService.matchOutfits(
            heroItem: hero,
            allItems: wardrobeItems,
            occasion: selectedOccasion,
            recentItemIds: recentIds,
            recentItemPairs: recentPairs,
            vibe: selectedVibe
        )

        matchResults = results

        // Pre-load thumbnails for result items
        let resultItems = results.flatMap(\.items)
        await loadThumbnails(for: resultItems)

        if results.isEmpty {
            applyFailure(.noCompatibleOutfits)
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
            // Build 7 — the recent-item caches are stale now
            // (this candidate just hit the 30-outfit history
            // window). Drop them so the next regen refetches.
            cachedRecentIds = nil
            cachedRecentPairs = nil
        } catch {
            errorMessage = "Couldn't save outfit."
        }
    }

    /// Build 10 — bulk-save every unsaved match result in one
    /// round-trip. The user gets back five suggestions; needing to
    /// tap "save" five times to keep all of them was friction we
    /// could remove with a single button. Persists each unsaved
    /// candidate via the same `saveDailyOutfits` path used by the
    /// single-save flow, then marks the indices saved in one batch
    /// so the buttons' "Saved" state updates with the result list
    /// in one animation tick.
    ///
    /// No-op when there are no unsaved results — the view hides
    /// the button in that case, but the guard makes the method
    /// safe to call from anywhere (telemetry, future UI tests).
    func saveAllResults(userId: UUID) async {
        let unsavedCandidates: [(Int, OutfitCandidate)] = matchResults.enumerated()
            .compactMap { (index, candidate) in
                savedResultIndices.contains(index) ? nil : (index, candidate)
            }
        guard !unsavedCandidates.isEmpty else { return }

        do {
            _ = try await generationService.saveDailyOutfits(
                candidates: unsavedCandidates.map(\.1),
                userId: userId
            )
            for (index, _) in unsavedCandidates {
                savedResultIndices.insert(index)
            }
            // Same cache-invalidation rationale as the single
            // save: the just-persisted candidates now live in the
            // recent-pair history window the novelty scorer reads.
            cachedRecentIds = nil
            cachedRecentPairs = nil
        } catch {
            errorMessage = "Couldn't save outfits."
        }
    }

    /// Build 10 — count of result rows that haven't been saved
    /// yet. The view binds the bulk button's title (e.g.
    /// "Save all (3)") and its visibility to this value.
    var unsavedResultCount: Int {
        matchResults.indices.filter { !savedResultIndices.contains($0) }.count
    }

    // MARK: - Build 7 — regeneration funnel

    /// Single entry point for occasion / vibe / re-roll requests.
    /// Cancels the in-flight matching task, waits the 250 ms
    /// debounce window, then re-runs `findMatches`. No-op when no
    /// hero is selected — the view's prompt state covers that
    /// case.
    ///
    /// On `.pickerChange` success, surfaces a brief toast so the
    /// user sees that their tap committed. `.surpriseMe` skips
    /// the toast — the visible card swap is the feedback.
    func requestRegeneration(userId: UUID, reason: RegenerationReason) {
        guard selectedItem != nil else { return }
        matchingTask?.cancel()
        matchingTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: self.regenerationDebounce)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }

            // `.surpriseMe` semantics: re-run with the same hero
            // + occasion + vibe but force a fresh evaluation. The
            // match engine doesn't take a seed today (no random
            // tiebreaker), so re-running is enough — the recent-
            // pair history changes the novelty signal naturally
            // between runs.
            await self.findMatches(userId: userId)

            if reason == .pickerChange, self.lastFailure == nil {
                // Build 14 — localized toast template (see
                // `OutfitViewModel` for the same pattern).
                let occasion = String(localized: self.selectedOccasion.localizedName)
                let vibe = String(localized: self.selectedVibe.localizedName)
                self.statusToastMessage = String(localized: "Updated for \(occasion) · \(vibe)")
            }
        }
    }

    // MARK: - Thumbnails

    func loadThumbnails(for items: [WardrobeItem]) async {
        // Prefer the per-item masked cutout (`maskedImagePath`) over the
        // framed source-photo thumbnail. PR #20 added this fallback to the
        // wardrobe grid via `ItemCardView.displayPath`; the match tab's
        // piece selector + outfit-suggestion result cards both feed off
        // this `thumbnailURLs` cache, so applying the same rule here
        // fixes the source-photo backdrop on every multi-pick item.
        //
        // Build 8 — parallelize via TaskGroup. The match flow's
        // first load resolves the entire hero picker AND each
        // result card; that's 15-40 thumbnails on a typical
        // wardrobe and was sequential, ~1-2 s wall clock for
        // the initial wardrobe paint.
        // Pre-compute path on the @MainActor side before fanning
        // out. Same pattern as `OutfitViewModel.loadThumbnails` —
        // `displayPath` reads from the item on the main actor, the
        // network call is the only thing parallelized.
        let pending: [(UUID, String)] = items
            .filter { thumbnailURLs[$0.id] == nil }
            .map { ($0.id, ItemCardView.displayPath(for: $0)) }

        let resolved: [(UUID, URL?)] = await withTaskGroup(of: (UUID, URL?).self) { group in
            for (id, path) in pending {
                group.addTask { [imageService] in
                    let url = try? await imageService.signedURL(for: path)
                    return (id, url)
                }
            }
            var out: [(UUID, URL?)] = []
            for await pair in group { out.append(pair) }
            return out
        }

        for (id, url) in resolved {
            thumbnailURLs[id] = url
        }
    }
}
