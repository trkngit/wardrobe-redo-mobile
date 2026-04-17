import Testing
@testable import WardrobeReDo

// MARK: - TextureMixScorer Tests

private let scorer = TextureMixScorer()
private let archetype = TestFixtures.makeStyleArchetype()
private let rule = TestFixtures.makeStyleRule()
private let context = TestFixtures.makeScoringContext()

@Test func noTextureDefaultsToHalf() {
    let items = [TestFixtures.makeWardrobeItem(texture: nil)]
    let result = scorer.score(items: items, archetype: archetype, rule: rule, context: context)
    #expect(result.value == 0.5)
}

@Test func singleTextureLacksDepth() {
    let items = [
        TestFixtures.makeWardrobeItem(texture: .cotton),
        TestFixtures.makeWardrobeItem(texture: .cotton),
    ]
    let result = scorer.score(items: items, archetype: archetype, rule: rule, context: context)
    // Single unique texture = 0.2 for count
    #expect(result.value < 0.7)
    #expect(result.reasoning.contains("lacks depth") || result.reasoning.contains("Single texture"))
}

@Test func twoTexturesOptimal() {
    let items = [
        TestFixtures.makeWardrobeItem(texture: .cotton),
        TestFixtures.makeWardrobeItem(texture: .denim),
    ]
    let result = scorer.score(items: items, archetype: archetype, rule: rule, context: context)
    #expect(result.value > 0.4)
}

@Test func threeTexturesOptimal() {
    let items = [
        TestFixtures.makeWardrobeItem(texture: .cotton),
        TestFixtures.makeWardrobeItem(texture: .leather),
        TestFixtures.makeWardrobeItem(texture: .silk),
    ]
    let result = scorer.score(items: items, archetype: archetype, rule: rule, context: context)
    #expect(result.value > 0.5)
}

@Test func heavyLightContrastBonus() {
    // leather (heavy) + silk (light) should get contrast bonus
    let items = [
        TestFixtures.makeWardrobeItem(texture: .leather),
        TestFixtures.makeWardrobeItem(texture: .silk),
    ]
    let result = scorer.score(items: items, archetype: archetype, rule: rule, context: context)
    #expect(result.reasoning.contains("heavy-light") || result.reasoning.contains("contrast"))
}

@Test func formalitySmoothnessCoherence() {
    // Similar smoothness = cohesive (cotton ~5.0, linen ~4.0 -> range 1.0 < 3.0)
    let items = [
        TestFixtures.makeWardrobeItem(texture: .cotton),
        TestFixtures.makeWardrobeItem(texture: .linen),
    ]
    let result = scorer.score(items: items, archetype: archetype, rule: rule, context: context)
    #expect(result.reasoning.contains("cohesive") || result.value > 0.4)
}

@Test func ruleMinTexturesPenalty() {
    let textureRule = TextureRule(minTextures: 3, maxTextures: nil, requiredContrast: nil)
    let customRule = TestFixtures.makeStyleRule(textureRule: textureRule)

    let items = [
        TestFixtures.makeWardrobeItem(texture: .cotton),
        TestFixtures.makeWardrobeItem(texture: .cotton),
    ]
    let result = scorer.score(items: items, archetype: archetype, rule: customRule, context: context)
    #expect(result.reasoning.contains("Below minimum"))
}

@Test func archetypePreferredTextureBonus() {
    let texPrefs = ArchetypeTexturePreferences(preferred: ["silk", "satin"], avoided: nil, maxCount: nil)
    let customArchetype = TestFixtures.makeStyleArchetype(texturePreferences: texPrefs)

    let items = [
        TestFixtures.makeWardrobeItem(texture: .silk),
        TestFixtures.makeWardrobeItem(texture: .cotton),
    ]
    let result = scorer.score(items: items, archetype: customArchetype, rule: rule, context: context)
    #expect(result.reasoning.contains("preferred textures"))
}

@Test func archetypeAvoidedTexturePenalty() {
    let texPrefs = ArchetypeTexturePreferences(preferred: nil, avoided: ["denim"], maxCount: nil)
    let customArchetype = TestFixtures.makeStyleArchetype(texturePreferences: texPrefs)

    let items = [
        TestFixtures.makeWardrobeItem(texture: .denim),
        TestFixtures.makeWardrobeItem(texture: .cotton),
    ]
    let result = scorer.score(items: items, archetype: customArchetype, rule: rule, context: context)
    #expect(result.reasoning.contains("avoided"))
}
