import Foundation

// MARK: - Output Types

/// A scored outfit candidate produced by beam search.
/// Contains the items, archetype/rule context, score breakdown,
/// slot assignments, and editorial copy.
struct OutfitCandidate: Sendable {
    let items: [WardrobeItem]
    let archetype: StyleArchetype
    let rule: StyleRule
    let score: OutfitScore
    let slots: [SlotAssignment]
    let editorialName: String
    let editorialDescription: String
}

/// Maps a wardrobe item to its role in the outfit.
struct SlotAssignment: Sendable {
    let item: WardrobeItem
    let slotName: String   // category key: "top", "bottom", "shoe", etc.
    let role: String        // "hero", "supporting", "completing"
}

// MARK: - Service

/// Generates outfit candidates using beam search over the 7-dimension
/// scoring engine. Supports daily generation (3 diverse outfits) and
/// hero-piece matching (anchor item + complementary pieces).
final class OutfitGenerationService: @unchecked Sendable {

    private let styleEngine = StyleEngineService()
    private let styleDataRepository = StyleDataRepository()

    // MARK: - Configuration

    /// Candidates kept per beam expansion step.
    private let beamWidth = 10
    /// Number of outfits generated per day.
    private let dailyOutfitCount = 3
    /// Max results returned from hero-piece matching.
    private let matchResultCount = 5

    // MARK: - Daily Outfit Generation

    /// Generate daily outfits across diverse archetypes.
    ///
    /// 1. Select archetypes matching the current context (season + occasion).
    /// 2. Enforce family diversity — one archetype per family.
    /// 3. For each archetype, run beam search across all its rules.
    /// 4. Return the top `dailyOutfitCount` results sorted by score.
    ///
    /// - Parameter seed: Optional deterministic seed for the archetype
    ///   tie-break random factor. Pass `nil` (default) for live behaviour
    ///   — `Double.random` runs unseeded so daily picks vary naturally.
    ///   Pass a concrete `UInt64` from "Generate New Outfits" so the
    ///   re-roll yields a different ordering than the previous attempt.
    func generateDailyOutfits(
        items: [WardrobeItem],
        occasion: Occasion = .casual,
        recentItemIds: Set<UUID> = [],
        seed: UInt64? = nil
    ) async -> [OutfitCandidate] {
        let activeItems = items.filter { !$0.isArchived }
        guard activeItems.count >= 2 else { return [] }

        let archetypes = await styleDataRepository.fetchArchetypes()
        let rules = await styleDataRepository.fetchRules()

        let context = StyleEngineService.buildContext(
            occasion: occasion,
            wardrobeSize: activeItems.count,
            recentItemIds: recentItemIds
        )

        // Over-select 3× so the post-loop item-set dedup has enough
        // headroom: family-uniqueness alone doesn't prevent two
        // archetypes from picking IDENTICAL items at slightly
        // different scores, which the user sees as visually-duplicate
        // outfit cards on a small wardrobe.
        let selectedArchetypes = selectDiverseArchetypes(
            archetypes: archetypes,
            context: context,
            count: dailyOutfitCount * 3,
            seed: seed
        )

        var results: [OutfitCandidate] = []
        var usedFamilies: Set<String> = []
        // Larger early-exit threshold than `dailyOutfitCount` so the
        // dedup pass below has duplicates to discard before falling
        // back to a smaller-than-target list.
        let preDedupTarget = dailyOutfitCount * 2

        for archetype in selectedArchetypes {
            guard !usedFamilies.contains(archetype.family) else { continue }

            let archetypeRules = rules.filter { $0.archetypeId == archetype.id }
            guard !archetypeRules.isEmpty else { continue }

            // Best candidate across all rules for this archetype.
            // The `if let best = bestCandidate` form replaces the
            // earlier `bestCandidate!.score.totalScore` force-unwrap
            // — currently safe via the `bestCandidate == nil ||`
            // short-circuit, but a future refactor reordering the
            // condition would silently land a crash hazard. The let-
            // binding makes the safety load-bearing.
            var bestCandidate: OutfitCandidate?
            for rule in archetypeRules {
                let candidates = beamSearch(
                    items: activeItems,
                    archetype: archetype,
                    rule: rule,
                    context: context
                )
                guard let top = candidates.first else { continue }
                if let best = bestCandidate {
                    if top.score.totalScore > best.score.totalScore {
                        bestCandidate = top
                    }
                } else {
                    bestCandidate = top
                }
            }

            if let best = bestCandidate {
                results.append(best)
                usedFamilies.insert(archetype.family)
            }

            if results.count >= preDedupTarget { break }
        }

        // Hard occasion filter — the OccasionContextScorer's 0.10
        // weight is too small to reorder outfits between subtabs
        // against ColorHarmony's 0.25, so the same "Nordic Clean"
        // candidate surfaced on every subtab. Filtering candidates to
        // those with at least one item explicitly tagged for the
        // selected occasion guarantees subtabs differ. Small-wardrobe
        // rescue: fall back to the unfiltered ranking when the strict
        // filter would drop us below `dailyOutfitCount` so the user
        // never sees an empty carousel.
        let pool = filteredByOccasion(
            candidates: results,
            occasion: occasion,
            minimum: dailyOutfitCount
        )

        // Dedup by item-set to collapse "Saturday Refined" + "The
        // Capsule" with identical items into a single card, keeping
        // the higher-scoring version. Falls back gracefully when the
        // wardrobe is small enough that fewer than `dailyOutfitCount`
        // distinct outfits exist — better to show 1-2 real options
        // than 3 cards where two are duplicates.
        let sorted = pool.sorted { $0.score.totalScore > $1.score.totalScore }
        return deduplicateCandidates(sorted, limit: dailyOutfitCount)
    }

    // MARK: - Occasion Filter

    /// Filter candidates to outfits where at least one item carries the
    /// selected occasion in its `occasions` array. Falls back to the
    /// unfiltered list when the strict filter would yield fewer than
    /// `minimum` candidates — small wardrobes never surface an empty
    /// carousel even when no item is tagged for the active subtab.
    func filteredByOccasion(
        candidates: [OutfitCandidate],
        occasion: Occasion,
        minimum: Int
    ) -> [OutfitCandidate] {
        let strictlyFiltered = candidates.filter { candidate in
            candidate.items.contains { $0.occasions.contains(occasion) }
        }
        return strictlyFiltered.count >= minimum ? strictlyFiltered : candidates
    }

    // MARK: - Hero Piece Matching

    /// Find outfits anchored by a specific "hero" item.
    ///
    /// Iterates archetypes whose rules include a slot matching the hero
    /// item's category, runs beam search with the hero fixed, and returns
    /// the top `matchResultCount` unique outfits.
    func matchOutfits(
        heroItem: WardrobeItem,
        allItems: [WardrobeItem],
        occasion: Occasion = .casual,
        recentItemIds: Set<UUID> = []
    ) async -> [OutfitCandidate] {
        let activeItems = allItems.filter { !$0.isArchived && $0.id != heroItem.id }
        guard !activeItems.isEmpty else { return [] }

        let archetypes = await styleDataRepository.fetchArchetypes()
        let rules = await styleDataRepository.fetchRules()

        let context = StyleEngineService.buildContext(
            occasion: occasion,
            wardrobeSize: allItems.count,
            recentItemIds: recentItemIds
        )

        var results: [OutfitCandidate] = []

        for archetype in archetypes {
            let archetypeRules = rules.filter { $0.archetypeId == archetype.id }

            for rule in archetypeRules {
                // Only consider rules that have a slot for the hero item.
                // Uses alias-aware matching so a "sneakers" item satisfies a
                // rule that requires "sneaker_low" (see SubcategoryAliases).
                let heroFitsRule = rule.slotRequirements.contains { req in
                    guard req.category == heroItem.category.rawValue else { return false }
                    guard let subs = req.subcategories, !subs.isEmpty else { return true }
                    return subs.contains { sub in
                        SubcategoryAliases.matches(
                            itemSubcategory: heroItem.subcategory.rawValue,
                            requiredSubcategory: sub
                        )
                    }
                }
                guard heroFitsRule else { continue }

                let candidates = beamSearchWithAnchor(
                    anchor: heroItem,
                    items: activeItems,
                    archetype: archetype,
                    rule: rule,
                    context: context
                )
                // Take top 2 per rule to build a diverse pool
                results.append(contentsOf: candidates.prefix(2))
            }
        }

        return deduplicateCandidates(
            results.sorted { $0.score.totalScore > $1.score.totalScore },
            limit: matchResultCount
        )
    }

    // MARK: - Persistence Bridge

    /// Convert generated candidates into DTOs and save to Supabase.
    func saveDailyOutfits(
        candidates: [OutfitCandidate],
        userId: UUID,
        date: String? = nil
    ) async throws -> [Outfit] {
        let repository = OutfitRepository()
        let dateString = date ?? OutfitRepository.todayDateString()

        var saved: [Outfit] = []

        for candidate in candidates {
            let outfitId = UUID()

            let newOutfit = NewOutfit(
                id: outfitId,
                userId: userId,
                archetypeId: candidate.archetype.id,
                editorialName: candidate.editorialName,
                editorialDescription: candidate.editorialDescription,
                date: dateString,
                score: candidate.score.totalScore,
                scoreBreakdown: candidate.score.toScoreBreakdown(),
                isWorn: false,
                // Idempotency key dedupes this insert if the retry path
                // kicks in after a lost-response network timeout. See
                // migration 00010.
                idempotencyKey: UUID()
            )

            let newSlots = candidate.slots.map { assignment in
                NewOutfitSlot(
                    outfitId: outfitId,
                    wardrobeItemId: assignment.item.id,
                    slotName: assignment.slotName,
                    role: assignment.role
                )
            }

            let outfit = try await repository.saveOutfit(newOutfit, slots: newSlots)
            saved.append(outfit)
        }

        return saved
    }

    // MARK: - Beam Search (Full)

    /// Standard beam search: expand each required slot, then try optional
    /// slots, keeping the top `beamWidth` candidates at each step.
    private func beamSearch(
        items: [WardrobeItem],
        archetype: StyleArchetype,
        rule: StyleRule,
        context: ScoringContext
    ) -> [OutfitCandidate] {
        let itemsByCategory = Dictionary(grouping: items, by: \.category)

        let requiredSlots = rule.slotRequirements.filter(\.isRequired)
        let optionalSlots = rule.slotRequirements.filter { !$0.isRequired }

        guard !requiredSlots.isEmpty else { return [] }

        // Seed the beam with empty candidates
        var beam: [[WardrobeItem]] = [[]]

        // Expand required slots — all must be satisfiable
        for slot in requiredSlots {
            beam = expandBeam(
                beam: beam, slot: slot,
                itemsByCategory: itemsByCategory,
                archetype: archetype, rule: rule, context: context
            )
            if beam.isEmpty { return [] }
        }

        // Expand optional slots — candidates without the slot are kept as fallbacks
        for slot in optionalSlots {
            beam = expandBeamWithOptional(
                beam: beam, slot: slot,
                itemsByCategory: itemsByCategory,
                archetype: archetype, rule: rule, context: context
            )
        }

        return buildCandidates(beam: beam, archetype: archetype, rule: rule, context: context)
    }

    // MARK: - Beam Search (Anchored)

    /// Beam search with one item pre-fixed as the hero/anchor.
    /// Skips the first slot matching the anchor's category.
    private func beamSearchWithAnchor(
        anchor: WardrobeItem,
        items: [WardrobeItem],
        archetype: StyleArchetype,
        rule: StyleRule,
        context: ScoringContext
    ) -> [OutfitCandidate] {
        let itemsByCategory = Dictionary(grouping: items, by: \.category)

        // Remove exactly one matching required slot for the anchor.
        // Uses alias-aware matching to bridge camelCase enum rawValues
        // (e.g. "sneakers") with snake_case rule strings (e.g. "sneaker_low").
        var remainingRequired = rule.slotRequirements.filter(\.isRequired)
        if let anchorIndex = remainingRequired.firstIndex(where: { req in
            guard req.category == anchor.category.rawValue else { return false }
            guard let subs = req.subcategories, !subs.isEmpty else { return true }
            return subs.contains { sub in
                SubcategoryAliases.matches(
                    itemSubcategory: anchor.subcategory.rawValue,
                    requiredSubcategory: sub
                )
            }
        }) {
            remainingRequired.remove(at: anchorIndex)
        }

        let optionalSlots = rule.slotRequirements.filter { req in
            !req.isRequired && req.category != anchor.category.rawValue
        }

        // Seed beam with the anchor item
        var beam: [[WardrobeItem]] = [[anchor]]

        for slot in remainingRequired {
            beam = expandBeam(
                beam: beam, slot: slot,
                itemsByCategory: itemsByCategory,
                archetype: archetype, rule: rule, context: context
            )
            if beam.isEmpty { return [] }
        }

        for slot in optionalSlots {
            beam = expandBeamWithOptional(
                beam: beam, slot: slot,
                itemsByCategory: itemsByCategory,
                archetype: archetype, rule: rule, context: context
            )
        }

        return buildCandidates(beam: beam, archetype: archetype, rule: rule, context: context)
    }

    // MARK: - Beam Expansion

    /// Expand beam by adding one item per slot. Every candidate must
    /// include this slot — empty expansions discard the candidate.
    private func expandBeam(
        beam: [[WardrobeItem]],
        slot: SlotRequirement,
        itemsByCategory: [ClothingCategory: [WardrobeItem]],
        archetype: StyleArchetype,
        rule: StyleRule,
        context: ScoringContext
    ) -> [[WardrobeItem]] {
        let matchingItems = findMatchingItems(for: slot, in: itemsByCategory)
        guard !matchingItems.isEmpty else { return [] }

        var newBeam: [(items: [WardrobeItem], score: Double)] = []

        for candidate in beam {
            let usedIds = Set(candidate.map(\.id))

            for item in matchingItems where !usedIds.contains(item.id) {
                var expanded = candidate
                expanded.append(item)

                let score = styleEngine.scoreOutfit(
                    items: expanded,
                    archetype: archetype,
                    rule: rule,
                    context: context
                )
                newBeam.append((items: expanded, score: score.totalScore))
            }
        }

        return Array(
            newBeam
                .sorted { $0.score > $1.score }
                .prefix(beamWidth)
                .map(\.items)
        )
    }

    /// Expand beam with an optional slot. Keeps candidates both with
    /// and without the optional item, then prunes to beam width.
    private func expandBeamWithOptional(
        beam: [[WardrobeItem]],
        slot: SlotRequirement,
        itemsByCategory: [ClothingCategory: [WardrobeItem]],
        archetype: StyleArchetype,
        rule: StyleRule,
        context: ScoringContext
    ) -> [[WardrobeItem]] {
        let matchingItems = findMatchingItems(for: slot, in: itemsByCategory)
        guard !matchingItems.isEmpty else { return beam }

        var newBeam: [(items: [WardrobeItem], score: Double)] = []

        for candidate in beam {
            // Keep the candidate without the optional item
            let baseScore = styleEngine.scoreOutfit(
                items: candidate, archetype: archetype, rule: rule, context: context
            )
            newBeam.append((items: candidate, score: baseScore.totalScore))

            // Try adding each optional item
            let usedIds = Set(candidate.map(\.id))
            for item in matchingItems where !usedIds.contains(item.id) {
                var expanded = candidate
                expanded.append(item)

                let score = styleEngine.scoreOutfit(
                    items: expanded, archetype: archetype, rule: rule, context: context
                )
                newBeam.append((items: expanded, score: score.totalScore))
            }
        }

        return Array(
            newBeam
                .sorted { $0.score > $1.score }
                .prefix(beamWidth)
                .map(\.items)
        )
    }

    // MARK: - Candidate Construction

    /// Score final beam entries and wrap them as OutfitCandidates.
    private func buildCandidates(
        beam: [[WardrobeItem]],
        archetype: StyleArchetype,
        rule: StyleRule,
        context: ScoringContext
    ) -> [OutfitCandidate] {
        beam.map { candidateItems in
            let score = styleEngine.scoreOutfit(
                items: candidateItems,
                archetype: archetype,
                rule: rule,
                context: context
            )
            let slots = assignSlots(items: candidateItems, rule: rule)
            let description = generateDescription(
                items: candidateItems, archetype: archetype, score: score
            )

            return OutfitCandidate(
                items: candidateItems,
                archetype: archetype,
                rule: rule,
                score: score,
                slots: slots,
                editorialName: archetype.editorialName,
                editorialDescription: description
            )
        }
        .sorted { $0.score.totalScore > $1.score.totalScore }
    }

    // MARK: - Item Lookup

    /// Find wardrobe items matching a slot's category and optional subcategory filter.
    ///
    /// Uses alias-aware subcategory matching (`SubcategoryAliases.matches`)
    /// so a "sneakers" item satisfies a slot requiring "sneaker_low".
    /// Falls back to category-only matching when no item satisfies the
    /// fine-grained taxonomy — small wardrobes never hard-fail.
    private func findMatchingItems(
        for slot: SlotRequirement,
        in itemsByCategory: [ClothingCategory: [WardrobeItem]]
    ) -> [WardrobeItem] {
        guard let category = ClothingCategory(rawValue: slot.category),
              let categoryItems = itemsByCategory[category] else { return [] }

        guard let subcategories = slot.subcategories, !subcategories.isEmpty else {
            return categoryItems
        }

        let aliasMatched = categoryItems.filter { item in
            subcategories.contains { req in
                SubcategoryAliases.matches(
                    itemSubcategory: item.subcategory.rawValue,
                    requiredSubcategory: req
                )
            }
        }

        // Soft fallback: if no item satisfies the fine-grained taxonomy,
        // accept any item in the same category. The OutfitFormulaScorer
        // still rewards better subcategory fits, but a small wardrobe
        // never produces zero candidates and a false "Generation timed
        // out" message.
        return aliasMatched.isEmpty ? categoryItems : aliasMatched
    }

    // MARK: - Archetype Selection

    /// Select archetypes matching the current context, preferring family diversity.
    /// Adds a small random factor so daily results vary across days.
    ///
    /// - Parameter seed: When non-nil, the random tie-break uses a
    ///   `SystemRandomNumberGenerator`-flavoured seedable RNG so the
    ///   ordering is reproducible inside a single generation but
    ///   different from any other seed. The generator produces a uniform
    ///   `[0, 0.2)` value per archetype, identical in distribution to
    ///   the unseeded `Double.random(in: 0...0.2)` used otherwise.
    func selectDiverseArchetypes(
        archetypes: [StyleArchetype],
        context: ScoringContext,
        count: Int,
        seed: UInt64? = nil
    ) -> [StyleArchetype] {
        // Score each archetype with the context bonuses + a small random
        // factor for day-to-day / re-roll variety. The seeded path uses a
        // deterministic RNG so the same `seed` reproduces the same
        // ordering, while different seeds produce different orderings.
        // The unseeded branch is intentionally left bit-identical to the
        // pre-seed implementation so existing tests + production callers
        // pass through unchanged.
        let scored: [(archetype: StyleArchetype, score: Double)]
        if let seed = seed {
            var rng = SeededRNG(seed: seed)
            scored = archetypes.map { archetype -> (archetype: StyleArchetype, score: Double) in
                var s = 0.0
                if archetype.seasons.contains(context.season.rawValue) { s += 0.4 }
                if archetype.occasions.contains(context.occasion.rawValue) { s += 0.4 }
                s += Double.random(in: 0..<0.2, using: &rng)
                return (archetype: archetype, score: s)
            }
        } else {
            scored = archetypes.map { archetype -> (archetype: StyleArchetype, score: Double) in
                var s = 0.0
                if archetype.seasons.contains(context.season.rawValue) { s += 0.4 }
                if archetype.occasions.contains(context.occasion.rawValue) { s += 0.4 }
                // Small random factor for day-to-day variety
                s += Double.random(in: 0...0.2)
                return (archetype: archetype, score: s)
            }
        }

        let sorted = scored.sorted { $0.score > $1.score }

        // First pass: one per family
        var selected: [StyleArchetype] = []
        var usedFamilies: Set<String> = []

        for item in sorted {
            if !usedFamilies.contains(item.archetype.family) {
                selected.append(item.archetype)
                usedFamilies.insert(item.archetype.family)
            }
            if selected.count >= count { break }
        }

        // Second pass: fill remaining slots (allow same family)
        if selected.count < count {
            for item in sorted where !selected.contains(where: { $0.id == item.archetype.id }) {
                selected.append(item.archetype)
                if selected.count >= count { break }
            }
        }

        return selected
    }

    // MARK: - Slot Assignment

    /// Assign each item a slot name and role (hero / supporting / completing).
    func assignSlots(items: [WardrobeItem], rule: StyleRule) -> [SlotAssignment] {
        // Identify the hero piece: outerwear > dress > most saturated item
        let heroItem = items.first { $0.category == .outerwear }
            ?? items.first { $0.category == .dress }
            ?? items.max(by: {
                ($0.dominantColors.first?.saturation ?? 0) <
                    ($1.dominantColors.first?.saturation ?? 0)
            })

        return items.map { item in
            let role: String
            if item.id == heroItem?.id {
                role = "hero"
            } else if rule.slotRequirements.contains(where: {
                $0.category == item.category.rawValue && $0.isRequired
            }) {
                role = "supporting"
            } else {
                role = "completing"
            }

            return SlotAssignment(
                item: item,
                slotName: item.category.rawValue,
                role: role
            )
        }
    }

    // MARK: - Editorial Description

    /// Generate a short editorial description from the outfit's items and
    /// score. Prepends the highest-scoring scoring dimension's reasoning
    /// so users see WHY an outfit works (e.g. "Cohesive navy palette
    /// anchors this look") instead of only WHAT it contains. Falls back
    /// to the legacy item+color summary when no dimension populated
    /// reasoning text.
    func generateDescription(
        items: [WardrobeItem],
        archetype: StyleArchetype,
        score: OutfitScore
    ) -> String {
        let topReasoning = score.breakdown
            .filter { !$0.reasoning.trimmingCharacters(in: .whitespaces).isEmpty }
            .max(by: { $0.value < $1.value })?
            .reasoning
            .trimmingCharacters(in: .whitespaces) ?? ""

        let baseCopy = legacyDescription(items: items, score: score)

        if topReasoning.isEmpty {
            return baseCopy
        }
        return "\(topReasoning) — \(baseCopy)"
    }

    /// Item + color + score-tier summary that previously lived inside
    /// `generateDescription`. Kept as a private helper so the new
    /// dimension-reasoning prefix can prepend on top without losing the
    /// existing copy when reasoning is empty.
    private func legacyDescription(
        items: [WardrobeItem],
        score: OutfitScore
    ) -> String {
        let itemNames = items.map { $0.subcategory.displayName.lowercased() }
        let colorFamilies = Set(items.compactMap { $0.dominantColors.first?.colorFamily })

        let colorNote: String
        if colorFamilies.count == 1, let family = colorFamilies.first {
            colorNote = "in a tonal \(family) palette"
        } else if colorFamilies.count == 2 {
            colorNote = "in \(colorFamilies.joined(separator: " and "))"
        } else {
            colorNote = "with a curated palette"
        }

        let qualityNote: String
        if score.totalScore >= 0.75 {
            qualityNote = "A standout combination"
        } else if score.totalScore >= 0.55 {
            qualityNote = "A well-balanced look"
        } else {
            qualityNote = "An interesting pairing"
        }

        return "\(qualityNote) — \(itemNames.joined(separator: ", ")) \(colorNote)."
    }

    // MARK: - Deduplication

    /// Remove candidates with identical item sets, keeping higher-scored versions.
    func deduplicateCandidates(
        _ candidates: [OutfitCandidate],
        limit: Int
    ) -> [OutfitCandidate] {
        var seen: Set<Set<UUID>> = []
        var unique: [OutfitCandidate] = []

        for candidate in candidates {
            let itemIds = Set(candidate.items.map(\.id))
            if !seen.contains(itemIds) {
                seen.insert(itemIds)
                unique.append(candidate)
            }
            if unique.count >= limit { break }
        }

        return unique
    }
}

// MARK: - Seedable RNG

/// SplitMix64 PRNG — small, fast, deterministic. Used as the seeded
/// random tie-break in `selectDiverseArchetypes` so calling
/// `generateDailyOutfits(seed:)` with the same value produces the same
/// archetype ordering, and different seeds produce different orderings.
///
/// SplitMix64 is the canonical "splittable" generator from
/// http://prng.di.unimi.it/splitmix64.c — 64 bits of state, no warm-up,
/// passes BigCrush, distribution is indistinguishable from uniform for
/// our use case (a handful of `Double.random` calls per generation).
///
/// Lives next to `OutfitGenerationService` because it's the only consumer
/// today; if other services start needing seeded variation, lift it into
/// its own file under `WardrobeReDo/Services/Util/`.
struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        // Avoid an all-zero state — the SplitMix64 mixing function
        // emits 0 forever from state 0. Any non-zero salt does.
        self.state = seed == 0 ? 0x9E3779B97F4A7C15 : seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z &>> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z &>> 27)) &* 0x94D049BB133111EB
        return z ^ (z &>> 31)
    }
}

// MARK: - OutfitScore → ScoreBreakdown Bridge

extension OutfitScore {
    /// Convert the runtime OutfitScore (array of DimensionScores) to
    /// the flat ScoreBreakdown struct used for Supabase persistence.
    func toScoreBreakdown() -> ScoreBreakdown {
        func value(for dimension: ScoringDimension) -> Double {
            breakdown.first { $0.dimension == dimension }?.value ?? 0
        }

        return ScoreBreakdown(
            proportion: value(for: .proportionBalance),
            colorHarmony: value(for: .colorHarmony),
            textureMix: value(for: .textureMix),
            formality: value(for: .formalityCoherence),
            formula: value(for: .outfitFormula),
            versatility: value(for: .versatility),
            occasion: value(for: .occasionContext)
        )
    }
}
