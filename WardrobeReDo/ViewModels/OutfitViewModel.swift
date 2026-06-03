import Foundation
import Observation
import os

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

    // MARK: - Logger (build 24)

    /// Subsystem-scoped logger for surfaces that previously
    /// `try? await`-swallowed errors. All call sites go through
    /// `LogPrivacy` so the error message itself stays private but
    /// the category prefix (e.g. "loadOutfits.wardrobeFetch") is
    /// public for log correlation.
    @ObservationIgnored
    private let logger = Logger(subsystem: "com.wardroberedo", category: "OutfitViewModel")

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
    /// Build 6 — vibe preset selector. Defaults to `.balanced`; the
    /// view layer can flip this before tapping "Generate New
    /// Outfits" to ask for a more or less adventurous re-roll. We
    /// don't persist this on the VM (it's ephemeral per generation);
    /// the user's saved default lives on `UserProfile.defaultVibe`
    /// once that field ships.
    var selectedVibe: VibeStop = .balanced

    /// Build 7 — transient post-regen confirmation. Set by
    /// `requestRegeneration(reason: .pickerChange)` after a
    /// successful debounced regen, so the view can mount a brief
    /// "Updated for [occasion] · [vibe]" `StatusToast`. Nil
    /// otherwise.
    var statusToastMessage: String?

    // MARK: - Thumbnail Cache

    /// Maps wardrobe item ID → signed thumbnail URL.
    var thumbnailURLs: [UUID: URL] = [:]

    // MARK: - Build 7 — regeneration plumbing

    /// Active regeneration task, if any. Held so a rapid picker
    /// change can cancel the in-flight run before starting a new
    /// one — prevents overlapping generations writing stale
    /// results after the user has moved on.
    ///
    /// `internal` visibility (not `private`) so tests can await
    /// `currentRegenerationTask?.value` and assert end-state
    /// deterministically instead of racing a `Task.sleep`. The
    /// view never reads this — it observes `isRegenerating`
    /// and the data fields the task mutates.
    var generationTask: Task<Void, Never>?

    /// Recent-item history cache. Avoids re-fetching from Supabase
    /// on every regeneration during a tight sequence of picker
    /// changes — saves ~200-300 ms of round trips per tap.
    /// Invalidated by `toggleWorn` and `saveOutfit` paths so the
    /// novelty scorer sees fresh history after the user takes a
    /// real action.
    private var cachedRecentIds: Set<UUID>?
    private var cachedRecentPairs: Set<UnorderedItemPair>?
    /// Build 49 — full item-sets of outfits suggested or worn in the
    /// last 14 days, for the exact-combination cooldown (TF49 #6).
    /// Cached and invalidated alongside the ids/pairs caches.
    private var cachedRecentSets: Set<Set<UUID>>?

    /// Why the regeneration fired — drives seed selection and
    /// whether a status toast appears on completion.
    enum RegenerationReason: Sendable {
        /// User changed occasion or vibe. Passes `seed = nil`
        /// (deterministic for the new parameters) and surfaces
        /// a brief "Updated for [occasion] · [vibe]" toast.
        case pickerChange
        /// User tapped "🎲 Surprise me". Passes a fresh random
        /// `UInt64` seed for genuine variety; no toast — the
        /// visible card swap IS the feedback.
        case surpriseMe
    }

    /// Debounce window between picker change and regeneration.
    /// Matches `BackgroundQualityMonitor.debounceInterval` —
    /// codebase precedent for "wait for the user to settle".
    private let regenerationDebounce: Duration = .milliseconds(250)

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
                // Proactive empty-wardrobe nudge: if there's nothing
                // cached for today AND the wardrobe is too small to
                // generate anything, surface the actionable copy from
                // GenerationFailure now instead of waiting for the
                // user to tap "Generate" and hit the same wall. Skips
                // the network call when wardrobe is rich (count >= 2)
                // since the generic empty-state is fine then.
                //
                // Build 24 — was `(try? await ...) ?? []` which
                // silently treated a network error as "user has no
                // wardrobe", surfacing the wrong failure message
                // ("wardrobe too small" instead of "couldn't load").
                // Now we distinguish the two: on fetch failure we
                // surface `.unknown` so the user knows to retry.
                do {
                    let wardrobeItems = try await wardrobeRepository.fetchItems(userId: userId)
                    let activeCount = wardrobeItems.filter { !$0.isArchived }.count
                    if activeCount < 2 {
                        applyFailure(.wardrobeTooSmall(itemCount: activeCount))
                    }
                } catch {
                    LogPrivacy.error(logger, category: "loadOutfits.wardrobeFetch", reason: error)
                    applyFailure(.unknown(String(describing: error)))
                }
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

    /// Build 7 — single funnel for both picker-change auto-regens
    /// and explicit "Surprise me" re-rolls.
    ///
    /// Cancels any in-flight generation, then waits a 250 ms
    /// debounce window (so a flurry of picker taps collapses into
    /// a single regen). After the wait, kicks the same shared
    /// `regenerateDailyOutfits` pipeline that was previously
    /// driven only from the bottom button.
    ///
    /// On `.pickerChange` success, a `statusToastMessage` is set
    /// so the view mounts a brief confirmation toast. On
    /// `.surpriseMe` the toast stays nil — the visible card swap
    /// is the feedback.
    func requestRegeneration(userId: UUID, reason: RegenerationReason) {
        generationTask?.cancel()
        generationTask = Task { [weak self] in
            guard let self else { return }
            // Debounce window. If a newer request arrives the
            // sleep throws `CancellationError`, we honour it and
            // bail without calling regenerate.
            do {
                try await Task.sleep(for: self.regenerationDebounce)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }

            let seed: UInt64? = switch reason {
            case .pickerChange: nil
            case .surpriseMe:   UInt64.random(in: .min ... .max)
            }
            await self.regenerateDailyOutfits(userId: userId, seed: seed)

            // Only the picker-change path surfaces a toast — the
            // re-roll path's feedback is the visible card swap.
            if reason == .pickerChange, self.lastFailure == nil {
                // Build 14 — pull localized labels via
                // `String(localized:)` so a Turkish phone renders
                // the Turkish chip names inside the toast, not the
                // English ones. Catalog key is "Updated for %@ · %@";
                // interpolation provides the two %@ slots.
                let occasion = String(localized: self.selectedOccasion.localizedName)
                let vibe = String(localized: self.selectedVibe.localizedName)
                self.statusToastMessage = String(localized: "Updated for \(occasion) · \(vibe)")
            }
        }
    }

    /// Internal regeneration entry point. Pass `seed: nil` for a
    /// deterministic regen with the current picker state; pass a
    /// random `UInt64` for a "Surprise me" re-roll.
    ///
    /// Sets `isRegenerating` (button-local spinner) instead of
    /// `isGenerating` (whole-screen "Curating…" state).
    ///
    /// Visibility: `internal` (default) so tests can drive the
    /// underlying flow directly, bypassing the debounce + Task
    /// wrapper in `requestRegeneration`. Production view code
    /// should always go through `requestRegeneration` so picker
    /// taps stay debounced.
    func regenerateDailyOutfits(userId: UUID, seed: UInt64?) async {
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

        await runGeneration(userId: userId, seed: seed)
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

            // Build 7 — recent-item history cache. Avoids hammering
            // Supabase on every picker tap during a tight regen
            // sequence (typical: user drags vibe slider through 5
            // stops in 2 s). Cache invalidates on toggleWorn /
            // saveOutfit success so the novelty scorer sees fresh
            // history after the user takes a real action.
            if cachedRecentIds == nil {
                async let idsTask = outfitRepository.fetchRecentItemIds(userId: userId)
                async let pairsTask = outfitRepository.fetchRecentItemPairs(userId: userId)
                async let setsTask = outfitRepository.fetchRecentItemSets(userId: userId)
                cachedRecentIds = (try? await idsTask) ?? []
                cachedRecentPairs = (try? await pairsTask) ?? []
                cachedRecentSets = (try? await setsTask) ?? []
            }
            let recentIds = cachedRecentIds ?? []
            let recentPairs = cachedRecentPairs ?? []
            let recentSets = cachedRecentSets ?? []

            // Race generation against a 60-second timeout. The outcome
            // enum lets us distinguish empty results from real timeouts.
            VibeTelemetry.logGenerationVibe(selectedVibe, source: "outfits")
            OccasionTelemetry.logGenerationOccasion(selectedOccasion, source: "outfits")
            let outcome: GenerationOutcome = await withTaskGroup(of: GenerationOutcome.self) {
                [generationService, selectedOccasion, selectedVibe, wardrobeItems, seed, recentIds, recentPairs, recentSets] group in
                group.addTask {
                    do {
                        let candidates = await generationService.generateDailyOutfits(
                            items: wardrobeItems,
                            occasion: selectedOccasion,
                            recentItemIds: recentIds,
                            recentItemPairs: recentPairs,
                            recentItemSets: recentSets,
                            seed: seed,
                            vibe: selectedVibe
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

                // Build 19 — defensive: `group.next()` returns nil
                // only when the group is empty (impossible here — we
                // added two tasks above) OR when both tasks resolved
                // before `next()` polled, which the structured-concurrency
                // contract doesn't guarantee won't happen. Force-unwrap
                // would crash in that edge case; treating it as a timeout
                // is the safe interpretation since we're racing against
                // a 60s timer anyway.
                let result = await group.next() ?? .timeout
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

            // Build 6: bump per-item `wear_count` only on the
            // un-worn → worn transition so the count is monotonic
            // and matches observed wears. Failure here is logged
            // but doesn't roll back the `markAsWorn` write — the
            // worn flag is the user-visible source of truth; the
            // count is a derived signal the engine consumes
            // best-effort.
            if newWorn {
                let itemIds = old.slots.map(\.wardrobeItemId)
                do {
                    try await outfitRepository.incrementWearCounts(itemIds: itemIds)
                } catch {
                    // Log + swallow — see comment above.
                    print("[OutfitViewModel] wear-count increment failed: \(error)")
                }
                // Build 7 — the recent-item caches are stale now
                // (this outfit's pair just hit the 30-outfit history
                // window). Drop them; the next regen will refetch.
                cachedRecentIds = nil
                cachedRecentPairs = nil
                cachedRecentSets = nil
            }

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
    /// Uses `ItemCardView.displayPath` so multi-pick items render the
    /// transparent-bg cutout (`maskedImagePath`) instead of the framed
    /// source-photo thumbnail. Same rule the wardrobe grid follows
    /// after PR #20.
    ///
    /// Build 8 — fans the per-item `signedURL` lookups out across a
    /// `TaskGroup` so a 3-outfit × 5-item set resolves in one
    /// round-trip-batch instead of 15 sequential ones. Previously
    /// felt like the carousel "popped in" cards as each fetch
    /// completed; the parallel pattern lets them all light up
    /// together, which is much less janky during a Surprise me
    /// re-roll. Skips items already cached so subsequent calls
    /// only fan out the new items.
    func loadThumbnails() async {
        // Pre-compute path on @MainActor (where `displayPath` and
        // the item live) before fanning out — avoids needing the
        // TaskGroup body to hop back to main just to read the
        // storage path. Pairs `(id, path)` are Sendable.
        let pending: [(UUID, String)] = dailyOutfits
            .flatMap(\.items)
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

    func thumbnailURL(for item: WardrobeItem) async -> URL? {
        if let cached = thumbnailURLs[item.id] { return cached }
        let url = try? await imageService.signedURL(
            for: ItemCardView.displayPath(for: item)
        )
        thumbnailURLs[item.id] = url
        return url
    }
}
