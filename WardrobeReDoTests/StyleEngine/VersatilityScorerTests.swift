import Foundation
import Testing
@testable import WardrobeReDo

// MARK: - VersatilityScorer Tests

private let scorer = VersatilityScorer()
private let archetype = TestFixtures.makeStyleArchetype()
private let rule = TestFixtures.makeStyleRule()

@Test func freshItemsScoreHigh() {
    let context = TestFixtures.makeScoringContext()
    let items = [
        TestFixtures.makeWardrobeItem(wearCount: 0),
        TestFixtures.makeWardrobeItem(category: .bottom, subcategory: .jeans, wearCount: 1),
        TestFixtures.makeWardrobeItem(category: .shoe, subcategory: .sneakers, wearCount: 2),
    ]
    let result = scorer.score(items: items, archetype: archetype, rule: rule, context: context)
    // avg wearCount = 1 -> 0.35 for frequency + bonuses
    #expect(result.value >= 0.6)
}

@Test func heavilyWornItemsScoreLow() {
    let context = TestFixtures.makeScoringContext()
    let items = [
        TestFixtures.makeWardrobeItem(wearCount: 15),
        TestFixtures.makeWardrobeItem(category: .bottom, subcategory: .jeans, wearCount: 20),
    ]
    let result = scorer.score(items: items, archetype: archetype, rule: rule, context: context)
    // avg > 10 -> only 0.05
    #expect(result.value < 0.6)
}

@Test func noRecentRepeatsBonus() {
    let context = TestFixtures.makeScoringContext(recentOutfitItemIds: [])
    let items = [
        TestFixtures.makeWardrobeItem(wearCount: 3),
        TestFixtures.makeWardrobeItem(category: .bottom, subcategory: .jeans, wearCount: 3),
    ]
    let result = scorer.score(items: items, archetype: archetype, rule: rule, context: context)
    #expect(result.reasoning.contains("fresh") || result.reasoning.contains("no recent repeats"))
}

@Test func allRecentPenalty() {
    let id1 = UUID()
    let id2 = UUID()
    let context = TestFixtures.makeScoringContext(recentOutfitItemIds: [id1, id2])
    let items = [
        TestFixtures.makeWardrobeItem(id: id1, wearCount: 5),
        TestFixtures.makeWardrobeItem(id: id2, category: .bottom, subcategory: .jeans, wearCount: 5),
    ]
    let result = scorer.score(items: items, archetype: archetype, rule: rule, context: context)
    #expect(result.reasoning.contains("worn in the last week") || result.reasoning.contains("recently"))
}

@Test func neverWornItemBonus() {
    let context = TestFixtures.makeScoringContext()
    let items = [
        TestFixtures.makeWardrobeItem(wearCount: 0),
        TestFixtures.makeWardrobeItem(category: .bottom, subcategory: .jeans, wearCount: 5),
    ]
    let result = scorer.score(items: items, archetype: archetype, rule: rule, context: context)
    #expect(result.reasoning.contains("never-worn"))
}

@Test func multiCategoryCoverageBonus() {
    let context = TestFixtures.makeScoringContext()
    let items = [
        TestFixtures.makeWardrobeItem(category: .top, subcategory: .tshirt, wearCount: 2),
        TestFixtures.makeWardrobeItem(category: .bottom, subcategory: .jeans, wearCount: 2),
        TestFixtures.makeWardrobeItem(category: .shoe, subcategory: .sneakers, wearCount: 2),
    ]
    let result = scorer.score(items: items, archetype: archetype, rule: rule, context: context)
    // 3 categories -> multi-category bonus
    #expect(result.reasoning.contains("Multi-category") || result.value > 0.5)
}

@Test func versatilityEmptyItemsDefaultToHalf() {
    let context = TestFixtures.makeScoringContext()
    let result = scorer.score(items: [], archetype: archetype, rule: rule, context: context)
    #expect(result.value == 0.5)
}

@Test func moderateWearCountGoodRotation() {
    let context = TestFixtures.makeScoringContext()
    let items = [
        TestFixtures.makeWardrobeItem(wearCount: 4),
        TestFixtures.makeWardrobeItem(category: .bottom, subcategory: .jeans, wearCount: 5),
    ]
    let result = scorer.score(items: items, archetype: archetype, rule: rule, context: context)
    #expect(result.reasoning.contains("rotation") || result.reasoning.contains("Moderate"))
}
