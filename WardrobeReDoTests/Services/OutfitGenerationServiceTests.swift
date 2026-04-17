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
