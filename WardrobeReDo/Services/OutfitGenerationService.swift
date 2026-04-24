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
    func generateDailyOutfits(
        items: [WardrobeItem],
        occasion: Occasion = .casual,
        recentItemIds: Set<UUID> = []
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

        // Over-select so we have fallback candidates
        let selectedArchetypes = selectDiverseArchetypes(
            archetypes: archetypes,
            context: context,
            count: dailyOutfitCount * 2
        )

        var results: [OutfitCandidate] = []
        var usedFamilies: Set<String> = []

        for archetype in selectedArchetypes {
            guard !usedFamilies.contains(archetype.family) else { continue }

            let archetypeRules = rules.filter { $0.archetypeId == archetype.id }
            guard !archetypeRules.isEmpty else { continue }

            // Best candidate across all rules for this archetype
            var bestCandidate: OutfitCandidate?
            for rule in archetypeRules {
                let candidates = beamSearch(
                    items: activeItems,
                    archetype: archetype,
                    rule: rule,
                    context: context
                )
                if let top = candidates.first,
                   bestCandidate == nil || top.score.totalScore > bestCandidate!.score.totalScore {
                    bestCandidate = top
                }
            }

            if let best = bestCandidate {
                results.append(best)
                usedFamilies.insert(archetype.family)
            }

            if results.count >= dailyOutfitCount { break }
        }

        return results.sorted { $0.score.totalScore > $1.score.totalScore }
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
    func selectDiverseArchetypes(
        archetypes: [StyleArchetype],
        context: ScoringContext,
        count: Int
    ) -> [StyleArchetype] {
        let scored = archetypes.map { archetype -> (archetype: StyleArchetype, score: Double) in
            var s = 0.0
            if archetype.seasons.contains(context.season.rawValue) { s += 0.4 }
            if archetype.occasions.contains(context.occasion.rawValue) { s += 0.4 }
            // Small random factor for day-to-day variety
            s += Double.random(in: 0...0.2)
            return (archetype: archetype, score: s)
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

    /// Generate a short editorial description from the outfit's items and score.
    func generateDescription(
        items: [WardrobeItem],
        archetype: StyleArchetype,
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
