import Testing
@testable import WardrobeReDo

// MARK: - OutfitGenerationService Tests

private let service = OutfitGenerationService()

// MARK: - assignSlots

@Test func assignSlotsHeroPriorityOuterwear() {
    let rule = TestFixtures.makeStyleRule()
    let items = [
        TestFixtures.makeWardrobeItem(category: .top, subcategory: .tshirt),
        TestFixtures.makeWardrobeItem(category: .bottom, subcategory: .jeans),
        TestFixtures.makeWardrobeItem(category: .outerwear, subcategory: .leatherJacket),
    ]
    let slots = service.assignSlots(items: items, rule: rule)
    let hero = slots.first { $0.role == "hero" }
    #expect(hero?.item.category == .outerwear)
}

@Test func assignSlotsHeroPriorityDressOverSaturation() {
    let rule = TestFixtures.makeStyleRule()
    let saturated = TestFixtures.makeColorProfile(saturation: 0.95, colorFamily: "red")
    let items = [
        TestFixtures.makeWardrobeItem(category: .top, subcategory: .tshirt, dominantColors: [saturated]),
        TestFixtures.makeWardrobeItem(category: .dress, subcategory: .casualDress),
    ]
    let slots = service.assignSlots(items: items, rule: rule)
    let hero = slots.first { $0.role == "hero" }
    #expect(hero?.item.category == .dress)
}

@Test func assignSlotsHeroFallsBackToMostSaturated() {
    let rule = TestFixtures.makeStyleRule()
    let bright = TestFixtures.makeColorProfile(saturation: 0.9, colorFamily: "red")
    let muted = TestFixtures.makeColorProfile(saturation: 0.1, colorFamily: "gray", isNeutral: true)
    let items = [
        TestFixtures.makeWardrobeItem(category: .top, subcategory: .tshirt, dominantColors: [bright]),
        TestFixtures.makeWardrobeItem(category: .bottom, subcategory: .jeans, dominantColors: [muted]),
    ]
    let slots = service.assignSlots(items: items, rule: rule)
    let hero = slots.first { $0.role == "hero" }
    #expect(hero?.item.category == .top)
}

// MARK: - generateDescription

@Test func generateDescriptionStandoutForHighScore() {
    let archetype = TestFixtures.makeStyleArchetype()
    let breakdown = ScoringDimension.allCases.map {
        DimensionScore(dimension: $0, value: 0.9, reasoning: "")
    }
    let score = OutfitScore(breakdown: breakdown)
    let items = [TestFixtures.makeWardrobeItem()]

    let description = service.generateDescription(items: items, archetype: archetype, score: score)
    #expect(description.contains("standout"))
}

@Test func generateDescriptionInterestingForLowScore() {
    let archetype = TestFixtures.makeStyleArchetype()
    let breakdown = ScoringDimension.allCases.map {
        DimensionScore(dimension: $0, value: 0.3, reasoning: "")
    }
    let score = OutfitScore(breakdown: breakdown)
    let items = [TestFixtures.makeWardrobeItem()]

    let description = service.generateDescription(items: items, archetype: archetype, score: score)
    #expect(description.contains("interesting"))
}

@Test func generateDescriptionTonalForMonochromatic() {
    let archetype = TestFixtures.makeStyleArchetype()
    let blue = TestFixtures.makeColorProfile(colorFamily: "blue")
    let breakdown = ScoringDimension.allCases.map {
        DimensionScore(dimension: $0, value: 0.7, reasoning: "")
    }
    let score = OutfitScore(breakdown: breakdown)
    let items = [
        TestFixtures.makeWardrobeItem(category: .top, subcategory: .tshirt, dominantColors: [blue]),
        TestFixtures.makeWardrobeItem(category: .bottom, subcategory: .jeans, dominantColors: [blue]),
    ]

    let description = service.generateDescription(items: items, archetype: archetype, score: score)
    #expect(description.contains("tonal"))
}

// MARK: - deduplicateCandidates

@Test func deduplicateRemovesIdenticalItemSets() {
    let archetype = TestFixtures.makeStyleArchetype()
    let rule = TestFixtures.makeStyleRule()
    let items = [TestFixtures.makeWardrobeItem(), TestFixtures.makeWardrobeItem(category: .bottom, subcategory: .jeans)]

    let breakdown = ScoringDimension.allCases.map {
        DimensionScore(dimension: $0, value: 0.7, reasoning: "")
    }
    let score = OutfitScore(breakdown: breakdown)
    let slots = items.map { SlotAssignment(item: $0, slotName: $0.category.rawValue, role: "supporting") }

    let candidate = OutfitCandidate(
        items: items, archetype: archetype, rule: rule, score: score,
        slots: slots, editorialName: "Test", editorialDescription: "Test"
    )

    // Same items in both candidates
    let result = service.deduplicateCandidates([candidate, candidate], limit: 5)
    #expect(result.count == 1)
}

@Test func deduplicateRespectsLimit() {
    let archetype = TestFixtures.makeStyleArchetype()
    let rule = TestFixtures.makeStyleRule()
    let breakdown = ScoringDimension.allCases.map {
        DimensionScore(dimension: $0, value: 0.7, reasoning: "")
    }
    let score = OutfitScore(breakdown: breakdown)

    var candidates: [OutfitCandidate] = []
    for _ in 0..<10 {
        let items = [TestFixtures.makeWardrobeItem()] // Each has unique UUID
        let slots = items.map { SlotAssignment(item: $0, slotName: $0.category.rawValue, role: "hero") }
        candidates.append(OutfitCandidate(
            items: items, archetype: archetype, rule: rule, score: score,
            slots: slots, editorialName: "Test", editorialDescription: "Test"
        ))
    }

    let result = service.deduplicateCandidates(candidates, limit: 3)
    #expect(result.count == 3)
}

// MARK: - Additional Coverage

@Test func assignSlotsEmptyItemsNoCrash() {
    let rule = TestFixtures.makeStyleRule()
    let slots = service.assignSlots(items: [], rule: rule)
    #expect(slots.isEmpty)
}

@Test func deduplicateEmptyInputReturnsEmpty() {
    let result = service.deduplicateCandidates([], limit: 5)
    #expect(result.isEmpty)
}

@Test func selectDiverseArchetypesEnforcesFamilyDiversity() {
    let arch1 = TestFixtures.makeStyleArchetype(family: "classic")
    let arch2 = TestFixtures.makeStyleArchetype(family: "classic")
    let arch3 = TestFixtures.makeStyleArchetype(family: "bohemian")
    let context = TestFixtures.makeScoringContext()

    let selected = service.selectDiverseArchetypes(
        archetypes: [arch1, arch2, arch3],
        context: context,
        count: 2
    )

    // Should prefer diversity: one classic + one bohemian
    let families = Set(selected.map(\.family))
    #expect(families.count == 2)
}

@Test func generateDailyOutfitsMinimumItemsGuard() async {
    // With fewer than 2 active items, should return empty
    let singleItem = [TestFixtures.makeWardrobeItem()]
    let result = await service.generateDailyOutfits(items: singleItem)
    #expect(result.isEmpty)
}

@Test func generateDescriptionWellBalancedForMidScore() {
    let archetype = TestFixtures.makeStyleArchetype()
    let breakdown = ScoringDimension.allCases.map {
        DimensionScore(dimension: $0, value: 0.6, reasoning: "")
    }
    let score = OutfitScore(breakdown: breakdown)
    let items = [TestFixtures.makeWardrobeItem()]

    let description = service.generateDescription(items: items, archetype: archetype, score: score)
    #expect(description.contains("well-balanced"))
}

// MARK: - B1: Hard occasion filter

/// Helper: builds a minimal OutfitCandidate around a set of items so we
/// can test `filteredByOccasion` without going through the full beam
/// search / Supabase pipeline.
private func makeCandidate(
    items: [WardrobeItem],
    totalScore: Double = 0.7
) -> OutfitCandidate {
    let archetype = TestFixtures.makeStyleArchetype()
    let rule = TestFixtures.makeStyleRule()
    let breakdown = ScoringDimension.allCases.map {
        DimensionScore(dimension: $0, value: totalScore, reasoning: "")
    }
    return OutfitCandidate(
        items: items,
        archetype: archetype,
        rule: rule,
        score: OutfitScore(breakdown: breakdown),
        slots: items.map {
            SlotAssignment(item: $0, slotName: $0.category.rawValue, role: "supporting")
        },
        editorialName: "Test",
        editorialDescription: "Test"
    )
}

@Test func casualSubtabSurfacesOutfitsWithCasualItems() {
    // Mixed pool: three candidates with at least one .casual item, plus
    // three work-only candidates that should be filtered out when the
    // user is on the Casual subtab.
    let casualTop = TestFixtures.makeWardrobeItem(
        category: .top, subcategory: .tshirt, occasions: [.casual]
    )
    let casualBottom = TestFixtures.makeWardrobeItem(
        category: .bottom, subcategory: .jeans, occasions: [.casual]
    )
    let workTop = TestFixtures.makeWardrobeItem(
        category: .top, subcategory: .buttonDown, occasions: [.work]
    )
    let workBottom = TestFixtures.makeWardrobeItem(
        category: .bottom, subcategory: .dressPants, occasions: [.work]
    )

    let casualCandidates = (0..<3).map { _ in
        makeCandidate(items: [casualTop, casualBottom])
    }
    let workCandidates = (0..<3).map { _ in
        makeCandidate(items: [workTop, workBottom])
    }

    let result = service.filteredByOccasion(
        candidates: casualCandidates + workCandidates,
        occasion: .casual,
        minimum: 3
    )

    #expect(result.count == 3)
    for candidate in result {
        #expect(candidate.items.contains { $0.occasions.contains(.casual) })
    }
}

@Test func workSubtabSurfacesOutfitsWithWorkItems() {
    let casualTop = TestFixtures.makeWardrobeItem(
        category: .top, subcategory: .tshirt, occasions: [.casual]
    )
    let casualBottom = TestFixtures.makeWardrobeItem(
        category: .bottom, subcategory: .jeans, occasions: [.casual]
    )
    let workTop = TestFixtures.makeWardrobeItem(
        category: .top, subcategory: .buttonDown, occasions: [.work]
    )
    let workBottom = TestFixtures.makeWardrobeItem(
        category: .bottom, subcategory: .dressPants, occasions: [.work]
    )

    let casualCandidates = (0..<3).map { _ in
        makeCandidate(items: [casualTop, casualBottom])
    }
    let workCandidates = (0..<3).map { _ in
        makeCandidate(items: [workTop, workBottom])
    }

    let result = service.filteredByOccasion(
        candidates: casualCandidates + workCandidates,
        occasion: .work,
        minimum: 3
    )

    #expect(result.count == 3)
    for candidate in result {
        #expect(candidate.items.contains { $0.occasions.contains(.work) })
    }
}

@Test func tinyWardrobeFallsBackToUnfilteredRanking() {
    // Pool with only ONE work-tagged candidate — the strict filter
    // would yield 1 result, below the requested 3, so the helper falls
    // back to returning the unfiltered pool. This guarantees the user
    // sees a populated carousel even when their wardrobe doesn't
    // contain enough items tagged for the active subtab.
    let casualTop = TestFixtures.makeWardrobeItem(
        category: .top, subcategory: .tshirt, occasions: [.casual]
    )
    let casualBottom = TestFixtures.makeWardrobeItem(
        category: .bottom, subcategory: .jeans, occasions: [.casual]
    )
    let workTop = TestFixtures.makeWardrobeItem(
        category: .top, subcategory: .buttonDown, occasions: [.work]
    )

    let casualOnly1 = makeCandidate(items: [casualTop, casualBottom])
    let casualOnly2 = makeCandidate(items: [casualTop, casualBottom])
    let workMix = makeCandidate(items: [workTop, casualBottom])

    let pool = [casualOnly1, casualOnly2, workMix]
    let result = service.filteredByOccasion(
        candidates: pool,
        occasion: .work,
        minimum: 3
    )

    // Strict filter would return only `workMix` (1 candidate). Falls
    // back to the full unfiltered pool to keep the carousel populated.
    #expect(result.count == 3)
}

// MARK: - B2: Description prepends top dimension's reasoning

@Test func descriptionPrependsTopDimensionReasoning() {
    let archetype = TestFixtures.makeStyleArchetype()
    // ColorHarmony with high value + meaningful reasoning should win;
    // the other dimensions have empty reasoning so they're skipped by
    // the filter even though some have higher values.
    let breakdown: [DimensionScore] = [
        DimensionScore(dimension: .proportionBalance, value: 0.95, reasoning: ""),
        DimensionScore(dimension: .colorHarmony, value: 0.9, reasoning: "Cohesive navy palette anchors this look"),
        DimensionScore(dimension: .textureMix, value: 0.5, reasoning: "Light-and-medium texture pairing"),
        DimensionScore(dimension: .formalityCoherence, value: 0.6, reasoning: ""),
        DimensionScore(dimension: .outfitFormula, value: 0.4, reasoning: ""),
        DimensionScore(dimension: .versatility, value: 0.3, reasoning: ""),
        DimensionScore(dimension: .occasionContext, value: 0.7, reasoning: "All items suit the casual context."),
    ]
    let score = OutfitScore(breakdown: breakdown)
    let items = [
        TestFixtures.makeWardrobeItem(category: .top, subcategory: .tshirt),
        TestFixtures.makeWardrobeItem(category: .bottom, subcategory: .jeans),
    ]

    let description = service.generateDescription(items: items, archetype: archetype, score: score)

    // Highest value among non-empty reasoning is colorHarmony (0.9).
    #expect(description.hasPrefix("Cohesive navy palette anchors this look — "))
    // Legacy copy is preserved after the separator.
    #expect(description.contains("t-shirt"))
}

@Test func descriptionFallsBackToBaseCopyWhenAllReasoningEmpty() {
    let archetype = TestFixtures.makeStyleArchetype()
    let breakdown = ScoringDimension.allCases.map {
        DimensionScore(dimension: $0, value: 0.8, reasoning: "")
    }
    let score = OutfitScore(breakdown: breakdown)
    let items = [
        TestFixtures.makeWardrobeItem(category: .top, subcategory: .tshirt),
        TestFixtures.makeWardrobeItem(category: .bottom, subcategory: .jeans),
    ]

    let description = service.generateDescription(items: items, archetype: archetype, score: score)

    // No prepended reasoning, no leading separator — must equal the
    // legacy "<qualityNote> — <items> <colorNote>." format exactly.
    #expect(description.hasPrefix("A standout combination — "))
    #expect(!description.contains(" — A standout"))
}
