import Testing
@testable import WardrobeReDo

// MARK: - FormalityCoherenceScorer Tests

private let scorer = FormalityCoherenceScorer()
private let archetype = TestFixtures.makeStyleArchetype(formalityMin: 0.2, formalityMax: 0.5)
private let rule = TestFixtures.makeStyleRule()
private let context = TestFixtures.makeScoringContext()

@Test func formalityEmptyItemsDefaultToHalf() {
    let result = scorer.score(items: [], archetype: archetype, rule: rule, context: context)
    #expect(result.value == 0.5)
}

@Test func singleItemSelfCoherent() {
    let items = [TestFixtures.makeWardrobeItem(formalityComputed: 0.3)]
    let result = scorer.score(items: items, archetype: archetype, rule: rule, context: context)
    #expect(result.value == 0.7)
    #expect(result.reasoning.contains("self-coherent"))
}

@Test func tightCoherenceHighScore() {
    // All items at formality ~0.35 (within archetype range 0.2-0.5)
    let items = [
        TestFixtures.makeWardrobeItem(formalityComputed: 0.35),
        TestFixtures.makeWardrobeItem(category: .bottom, subcategory: .chinos, formalityComputed: 0.37),
        TestFixtures.makeWardrobeItem(category: .shoe, subcategory: .sneakers, formalityComputed: 0.33),
    ]
    let result = scorer.score(items: items, archetype: archetype, rule: rule, context: context)
    // Tight spread + in archetype range + casual occasion = high score
    #expect(result.value >= 0.7)
}

@Test func formalityCashPenalized() {
    // Flip-flop level: dress shoes (0.8) + joggers (0.1) = big spread
    let items = [
        TestFixtures.makeWardrobeItem(formalityComputed: 0.85),
        TestFixtures.makeWardrobeItem(category: .bottom, subcategory: .joggers, formalityComputed: 0.1),
    ]
    let result = scorer.score(items: items, archetype: archetype, rule: rule, context: context)
    #expect(result.value < 0.6)
}

@Test func archetypeRangeFitBoost() {
    // Items at 0.35 average -> within casual archetype 0.2-0.5
    let items = [
        TestFixtures.makeWardrobeItem(formalityComputed: 0.3),
        TestFixtures.makeWardrobeItem(category: .bottom, subcategory: .chinos, formalityComputed: 0.4),
    ]
    let result = scorer.score(items: items, archetype: archetype, rule: rule, context: context)
    #expect(result.reasoning.contains("fits"))
}

@Test func tooFormalForCasualArchetypePenalized() {
    // High formality (0.8) with casual archetype (0.2-0.5)
    let formalArchetype = TestFixtures.makeStyleArchetype(formalityMin: 0.2, formalityMax: 0.5)
    let items = [
        TestFixtures.makeWardrobeItem(formalityComputed: 0.8),
        TestFixtures.makeWardrobeItem(category: .bottom, subcategory: .dressPants, formalityComputed: 0.85),
    ]
    let result = scorer.score(items: items, archetype: formalArchetype, rule: rule, context: context)
    #expect(result.reasoning.contains("too formal"))
}

@Test func casualOccasionAcceptsCasualFormality() {
    let casualContext = TestFixtures.makeScoringContext(occasion: .casual)
    let items = [
        TestFixtures.makeWardrobeItem(formalityComputed: 0.25),
        TestFixtures.makeWardrobeItem(category: .bottom, subcategory: .jeans, formalityComputed: 0.2),
    ]
    let result = scorer.score(items: items, archetype: archetype, rule: rule, context: casualContext)
    #expect(result.reasoning.contains("Appropriate") || result.value > 0.5)
}

@Test func formalOccasionPenalizesTooCasual() {
    let formalContext = TestFixtures.makeScoringContext(occasion: .formal)
    let items = [
        TestFixtures.makeWardrobeItem(formalityComputed: 0.15),
        TestFixtures.makeWardrobeItem(category: .bottom, subcategory: .joggers, formalityComputed: 0.1),
    ]
    let result = scorer.score(items: items, archetype: archetype, rule: rule, context: formalContext)
    #expect(result.reasoning.contains("underdressed"))
}

@Test func textureBasedFormalityEstimation() {
    // Items without formalityComputed should estimate from texture
    let items = [
        TestFixtures.makeWardrobeItem(texture: .silk, formalityComputed: nil),
        TestFixtures.makeWardrobeItem(category: .bottom, subcategory: .dressPants, texture: .wool, formalityComputed: nil),
    ]
    let result = scorer.score(items: items, archetype: archetype, rule: rule, context: context)
    // Should not be 0.5 (the empty fallback) — should compute from texture
    #expect(result.value != 0.5)
}
