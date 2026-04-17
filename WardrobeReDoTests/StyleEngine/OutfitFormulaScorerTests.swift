import Testing
@testable import WardrobeReDo

// MARK: - OutfitFormulaScorer Tests

private let scorer = OutfitFormulaScorer()
private let archetype = TestFixtures.makeStyleArchetype()
private let rule = TestFixtures.makeStyleRule()
private let context = TestFixtures.makeScoringContext()

@Test func emptyItemsScoreZero() {
    let result = scorer.score(items: [], archetype: archetype, rule: rule, context: context)
    #expect(result.value == 0.0)
}

@Test func slotRequirementsSatisfied() {
    // Rule requires top + bottom, optional shoe
    let items = [
        TestFixtures.makeWardrobeItem(category: .top, subcategory: .tshirt),
        TestFixtures.makeWardrobeItem(category: .bottom, subcategory: .jeans),
        TestFixtures.makeWardrobeItem(category: .shoe, subcategory: .sneakers),
    ]
    let result = scorer.score(items: items, archetype: archetype, rule: rule, context: context)
    #expect(result.reasoning.contains("2/2 required slots filled"))
}

@Test func missingRequiredSlotPenalty() {
    // Only a top, missing required bottom
    let items = [TestFixtures.makeWardrobeItem(category: .top, subcategory: .tshirt)]
    let result = scorer.score(items: items, archetype: archetype, rule: rule, context: context)
    #expect(result.reasoning.contains("1/2 required slots filled"))
}

@Test func heroPieceOuterwear() {
    let items = [
        TestFixtures.makeWardrobeItem(category: .top, subcategory: .tshirt),
        TestFixtures.makeWardrobeItem(category: .bottom, subcategory: .jeans),
        TestFixtures.makeWardrobeItem(category: .outerwear, subcategory: .leatherJacket),
    ]
    let result = scorer.score(items: items, archetype: archetype, rule: rule, context: context)
    #expect(result.reasoning.contains("hero piece"))
}

@Test func heroPieceDress() {
    let items = [
        TestFixtures.makeWardrobeItem(category: .dress, subcategory: .casualDress),
        TestFixtures.makeWardrobeItem(category: .shoe, subcategory: .sandals),
    ]
    let result = scorer.score(items: items, archetype: archetype, rule: rule, context: context)
    #expect(result.reasoning.contains("hero piece"))
}

@Test func heroPieceMostSaturatedColor() {
    // No outerwear/dress -> find most saturated item
    let brightRed = TestFixtures.makeColorProfile(saturation: 0.9, colorFamily: "red")
    let mutedGray = TestFixtures.makeColorProfile(saturation: 0.1, colorFamily: "gray", isNeutral: true)

    let items = [
        TestFixtures.makeWardrobeItem(category: .top, subcategory: .tshirt, dominantColors: [brightRed]),
        TestFixtures.makeWardrobeItem(category: .bottom, subcategory: .jeans, dominantColors: [mutedGray]),
    ]
    let result = scorer.score(items: items, archetype: archetype, rule: rule, context: context)
    #expect(result.reasoning.contains("focal point") || result.reasoning.contains("hero"))
}

@Test func twoOfThreeColorMatchBonus() {
    let blue = TestFixtures.makeColorProfile(colorFamily: "blue")
    let items = [
        TestFixtures.makeWardrobeItem(category: .top, subcategory: .tshirt, dominantColors: [blue]),
        TestFixtures.makeWardrobeItem(category: .bottom, subcategory: .jeans, dominantColors: [blue]),
        TestFixtures.makeWardrobeItem(category: .shoe, subcategory: .sneakers,
                                       dominantColors: [TestFixtures.makeColorProfile(colorFamily: "white", isNeutral: true)]),
    ]
    let result = scorer.score(items: items, archetype: archetype, rule: rule, context: context)
    #expect(result.reasoning.contains("share a color family") || result.reasoning.contains("cohesive"))
}

@Test func thirdPieceOuterwearElevates() {
    let items = [
        TestFixtures.makeWardrobeItem(category: .top, subcategory: .tshirt),
        TestFixtures.makeWardrobeItem(category: .bottom, subcategory: .jeans),
        TestFixtures.makeWardrobeItem(category: .outerwear, subcategory: .denimJacket),
    ]
    let result = scorer.score(items: items, archetype: archetype, rule: rule, context: context)
    #expect(result.reasoning.contains("Third piece elevates") || result.reasoning.contains("elevate"))
}

@Test func thirdPieceAccessoryElevates() {
    let items = [
        TestFixtures.makeWardrobeItem(category: .top, subcategory: .tshirt),
        TestFixtures.makeWardrobeItem(category: .bottom, subcategory: .chinos),
        TestFixtures.makeWardrobeItem(category: .accessory, subcategory: .watch),
    ]
    let result = scorer.score(items: items, archetype: archetype, rule: rule, context: context)
    #expect(result.reasoning.contains("elevates"))
}

@Test func noThirdPieceSuggestsElevation() {
    let items = [
        TestFixtures.makeWardrobeItem(category: .top, subcategory: .tshirt),
        TestFixtures.makeWardrobeItem(category: .bottom, subcategory: .jeans),
    ]
    let result = scorer.score(items: items, archetype: archetype, rule: rule, context: context)
    #expect(result.reasoning.contains("would elevate") || result.reasoning.contains("Solid base"))
}
