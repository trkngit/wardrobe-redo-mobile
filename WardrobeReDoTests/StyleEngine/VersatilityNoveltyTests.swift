import Foundation
import Testing
@testable import WardrobeReDo

// MARK: - VersatilityScorer novelty bonus (build 6)
//
// Before build 6 the scorer's docstring promised a "novel
// combination bonus" that was never implemented. Phase 5 wires it
// up: generate the candidate outfit's unordered item-pair set,
// compare against `ScoringContext.recentOutfitItemPairs` (pairs
// seen in the last 30 saved outfits), reward novelty up to +0.20.
// These tests pin the contract.

@Test func noveltyContributesPositiveValueWhenNoPairsSeen() {
    let topID = UUID()
    let bottomID = UUID()
    let items = [
        TestFixtures.makeWardrobeItem(id: topID, category: .top, subcategory: .tshirt),
        TestFixtures.makeWardrobeItem(id: bottomID, category: .bottom, subcategory: .jeans),
    ]
    // Non-empty recent set (so the novelty axis IS covered) but
    // the candidate's pair isn't in it.
    let unrelated = UUID()
    let context = ScoringContext(
        season: .spring,
        occasion: .casual,
        dayOfWeek: "monday",
        wardrobeItemCount: 10,
        recentOutfitItemIds: [],
        recentOutfitItemPairs: [UnorderedItemPair(unrelated, UUID())]
    )

    let result = VersatilityScorer().score(
        items: items,
        archetype: TestFixtures.makeStyleArchetype(),
        rule: TestFixtures.makeStyleRule(),
        context: context
    )

    #expect(result.reasoning.contains("Brand-new pairing"))
    #expect(result.coverage > 0)
}

@Test func noveltyAddsNoBonusWhenEveryPairWasRecentlySeen() {
    let topID = UUID()
    let bottomID = UUID()
    let items = [
        TestFixtures.makeWardrobeItem(id: topID, category: .top, subcategory: .tshirt),
        TestFixtures.makeWardrobeItem(id: bottomID, category: .bottom, subcategory: .jeans),
    ]
    // The exact pair is in recent history.
    let context = ScoringContext(
        season: .spring,
        occasion: .casual,
        dayOfWeek: "monday",
        wardrobeItemCount: 10,
        recentOutfitItemIds: [],
        recentOutfitItemPairs: [UnorderedItemPair(topID, bottomID)]
    )

    let result = VersatilityScorer().score(
        items: items,
        archetype: TestFixtures.makeStyleArchetype(),
        rule: TestFixtures.makeStyleRule(),
        context: context
    )

    #expect(result.reasoning.contains("Familiar pairing"))
    #expect(result.coverage > 0)
}

@Test func noveltyCoverageZeroWhenNoRecentHistory() {
    // Fresh user — no saved outfits yet. Novelty axis should
    // report coverage=0 (no signal) instead of falsely awarding
    // a "brand-new" bonus.
    let items = [
        TestFixtures.makeWardrobeItem(category: .top, subcategory: .tshirt),
        TestFixtures.makeWardrobeItem(category: .bottom, subcategory: .jeans),
    ]
    let context = ScoringContext(
        season: .spring,
        occasion: .casual,
        dayOfWeek: "monday",
        wardrobeItemCount: 10,
        recentOutfitItemIds: [],
        recentOutfitItemPairs: []
    )

    let result = VersatilityScorer().score(
        items: items,
        archetype: TestFixtures.makeStyleArchetype(),
        rule: TestFixtures.makeStyleRule(),
        context: context
    )

    #expect(result.coverage == 0.0)
    #expect(!result.reasoning.contains("Brand-new pairing"))
}

@Test func unorderedItemPairIsHashIdentityRegardlessOfOrder() {
    let a = UUID()
    let b = UUID()
    let pairAB = UnorderedItemPair(a, b)
    let pairBA = UnorderedItemPair(b, a)
    #expect(pairAB == pairBA)
    #expect(pairAB.hashValue == pairBA.hashValue)
}
