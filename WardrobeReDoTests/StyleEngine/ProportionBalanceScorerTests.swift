import Testing
@testable import WardrobeReDo

// MARK: - ProportionBalanceScorer Tests

private let scorer = ProportionBalanceScorer()
private let archetype = TestFixtures.makeStyleArchetype()
private let rule = TestFixtures.makeStyleRule()
private let context = TestFixtures.makeScoringContext()

@Test func dressAutoScoresHighProportion() {
    let items = [TestFixtures.makeWardrobeItem(category: .dress, subcategory: .casualDress)]
    let result = scorer.score(items: items, archetype: archetype, rule: rule, context: context)
    #expect(result.value == 0.85)
}

@Test func oversizedTopSlimBottomScoresHigh() {
    let items = [
        TestFixtures.makeWardrobeItem(category: .top, subcategory: .hoodie, fitAttribute: .oversized),
        TestFixtures.makeWardrobeItem(category: .bottom, subcategory: .jeans, fitAttribute: .slim),
    ]
    let result = scorer.score(items: items, archetype: archetype, rule: rule, context: context)
    #expect(result.value >= 0.85)
}

@Test func oversizedTopOversizedBottomScoresLow() {
    let items = [
        TestFixtures.makeWardrobeItem(category: .top, subcategory: .hoodie, fitAttribute: .oversized),
        TestFixtures.makeWardrobeItem(category: .bottom, subcategory: .joggers, fitAttribute: .oversized),
    ]
    let result = scorer.score(items: items, archetype: archetype, rule: rule, context: context)
    #expect(result.value <= 0.35)
}

@Test func slimTopSlimBottomScoresWell() {
    let items = [
        TestFixtures.makeWardrobeItem(category: .top, subcategory: .tshirt, fitAttribute: .slim),
        TestFixtures.makeWardrobeItem(category: .bottom, subcategory: .jeans, fitAttribute: .slim),
    ]
    let result = scorer.score(items: items, archetype: archetype, rule: rule, context: context)
    #expect(result.value >= 0.75)
}

@Test func regularTopRegularBottomScoresModerate() {
    let items = [
        TestFixtures.makeWardrobeItem(category: .top, subcategory: .tshirt, fitAttribute: .regular),
        TestFixtures.makeWardrobeItem(category: .bottom, subcategory: .chinos, fitAttribute: .regular),
    ]
    let result = scorer.score(items: items, archetype: archetype, rule: rule, context: context)
    #expect(result.value >= 0.65 && result.value <= 0.8)
}

@Test func missingFitAttributeDefaultsToMiddleScore() {
    let items = [
        TestFixtures.makeWardrobeItem(category: .top, subcategory: .tshirt, fitAttribute: nil),
        TestFixtures.makeWardrobeItem(category: .bottom, subcategory: .jeans, fitAttribute: nil),
    ]
    let result = scorer.score(items: items, archetype: archetype, rule: rule, context: context)
    #expect(result.value == 0.5)
}

@Test func archetypePreferredBalancesBoostScore() {
    let propPrefs = ArchetypeProportionPreferences(
        preferredBalances: [["slim", "slim"]],
        allowOversized: true
    )
    let customArchetype = TestFixtures.makeStyleArchetype(proportionPreferences: propPrefs)

    let items = [
        TestFixtures.makeWardrobeItem(category: .top, subcategory: .tshirt, fitAttribute: .slim),
        TestFixtures.makeWardrobeItem(category: .bottom, subcategory: .jeans, fitAttribute: .slim),
    ]
    let result = scorer.score(items: items, archetype: customArchetype, rule: rule, context: context)
    #expect(result.value >= 0.85)
}

@Test func archetypeNoOversizedPenalizesOversized() {
    let propPrefs = ArchetypeProportionPreferences(
        preferredBalances: nil,
        allowOversized: false
    )
    let customArchetype = TestFixtures.makeStyleArchetype(proportionPreferences: propPrefs)

    let items = [
        TestFixtures.makeWardrobeItem(category: .top, subcategory: .hoodie, fitAttribute: .oversized),
        TestFixtures.makeWardrobeItem(category: .bottom, subcategory: .jeans, fitAttribute: .slim),
    ]
    let withoutPenalty = scorer.score(items: items, archetype: archetype, rule: rule, context: context)
    let withPenalty = scorer.score(items: items, archetype: customArchetype, rule: rule, context: context)

    #expect(withPenalty.value < withoutPenalty.value)
}

@Test func ruleForbiddenProportionPenalty() {
    let propRule = ProportionRule(
        topFit: nil, bottomFit: nil, allowed: nil,
        forbidden: [["oversized", "slim"]]
    )
    let customRule = TestFixtures.makeStyleRule(proportionRule: propRule)

    let items = [
        TestFixtures.makeWardrobeItem(category: .top, subcategory: .hoodie, fitAttribute: .oversized),
        TestFixtures.makeWardrobeItem(category: .bottom, subcategory: .jeans, fitAttribute: .slim),
    ]
    let result = scorer.score(items: items, archetype: archetype, rule: customRule, context: context)
    // Should be penalized by -0.3 from the base score
    #expect(result.value <= 0.65)
}

@Test func croppedTopSlimBottomScoresWell() {
    let items = [
        TestFixtures.makeWardrobeItem(category: .top, subcategory: .cropTop, fitAttribute: .cropped),
        TestFixtures.makeWardrobeItem(category: .bottom, subcategory: .jeans, fitAttribute: .slim),
    ]
    let result = scorer.score(items: items, archetype: archetype, rule: rule, context: context)
    #expect(result.value >= 0.75)
}
