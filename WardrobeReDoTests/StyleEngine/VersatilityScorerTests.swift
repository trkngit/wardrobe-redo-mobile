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

// MARK: - Build 49 / TF49 #7 — per-item uniqueness weighting

/// A staple — worn often, neutral colour, valid for many occasions —
/// should read as low uniqueness (≈0): repeating it day-to-day is fine.
@Test func uniquenessIsLowForStaple() {
    let staple = TestFixtures.makeWardrobeItem(
        dominantColors: [TestFixtures.makeColorProfile(isNeutral: true)],
        occasions: Array(Occasion.allCases.prefix(4)),
        wearCount: 20
    )
    #expect(VersatilityScorer.uniqueness(staple) < 0.2)
}

/// A statement piece — rarely worn, bold colour, single niche occasion —
/// should read as high uniqueness (1.0): wearing it back-to-back is the
/// "same outfit again" the user complained about.
@Test func uniquenessIsHighForStatementPiece() {
    let statement = TestFixtures.makeWardrobeItem(
        dominantColors: [TestFixtures.makeColorProfile(isNeutral: false)],
        occasions: [Occasion.allCases.first!],
        wearCount: 1
    )
    #expect(VersatilityScorer.uniqueness(statement) > 0.9)
}

/// The core TF49 #7 behaviour: when exactly one recently-worn item is
/// repeated, repeating a BASIC costs far less versatility than repeating
/// a STATEMENT piece. The two outfits are identical in every other
/// scored signal (same wear counts, same categories, same fresh
/// partner) so the only delta is the repeated item's uniqueness.
@Test func basicRepeatScoresHigherThanStatementRepeat() {
    let repeatedId = UUID()

    let basicRepeat = TestFixtures.makeWardrobeItem(
        id: repeatedId,
        dominantColors: [TestFixtures.makeColorProfile(isNeutral: true)],
        occasions: Array(Occasion.allCases.prefix(4)),
        wearCount: 5
    )
    let statementRepeat = TestFixtures.makeWardrobeItem(
        id: repeatedId,
        dominantColors: [TestFixtures.makeColorProfile(isNeutral: false)],
        occasions: [Occasion.allCases.first!],
        wearCount: 5
    )
    // Identical fresh partner in both outfits (different category so
    // the coverage component is equal at 2 categories).
    let freshPartner = TestFixtures.makeWardrobeItem(
        category: .bottom, subcategory: .jeans, wearCount: 5
    )

    let context = TestFixtures.makeScoringContext(recentOutfitItemIds: [repeatedId])

    let basicResult = scorer.score(
        items: [basicRepeat, freshPartner], archetype: archetype, rule: rule, context: context
    )
    let statementResult = scorer.score(
        items: [statementRepeat, freshPartner], archetype: archetype, rule: rule, context: context
    )

    #expect(basicResult.value > statementResult.value)
    #expect(basicResult.reasoning.contains("basics"))
    #expect(statementResult.reasoning.contains("statement"))
}

// MARK: - Build 49 / TF49 #6 — exact-combination 2-week cooldown

/// An outfit whose exact item-set was suggested/worn in the last 14 days
/// is hard-penalized so it won't resurface, while the identical outfit
/// with no such history scores normally.
@Test func exactCombinationCooldownPenalizesExactRepeat() {
    let idA = UUID()
    let idB = UUID()
    let items = [
        TestFixtures.makeWardrobeItem(id: idA, wearCount: 3),
        TestFixtures.makeWardrobeItem(id: idB, category: .bottom, subcategory: .jeans, wearCount: 3),
    ]

    let noHistory = TestFixtures.makeScoringContext()
    let withCooldown = TestFixtures.makeScoringContext(
        recentOutfitItemSets: [[idA, idB]]
    )

    let baseline = scorer.score(items: items, archetype: archetype, rule: rule, context: noHistory)
    let penalized = scorer.score(items: items, archetype: archetype, rule: rule, context: withCooldown)

    #expect(penalized.value < baseline.value)
    #expect(penalized.reasoning.contains("last 2 weeks"))
}

/// The cooldown matches on the EXACT set — a different combination that
/// merely shares items with a recent outfit is not penalized.
@Test func exactCombinationCooldownIgnoresDifferentSet() {
    let idA = UUID()
    let idB = UUID()
    let idC = UUID()
    let items = [
        TestFixtures.makeWardrobeItem(id: idA, wearCount: 3),
        TestFixtures.makeWardrobeItem(id: idB, category: .bottom, subcategory: .jeans, wearCount: 3),
    ]

    // History contains {A, C}, but the candidate is {A, B} — only one
    // item overlaps, so the exact-set cooldown must NOT fire.
    let context = TestFixtures.makeScoringContext(recentOutfitItemSets: [[idA, idC]])
    let baseline = TestFixtures.makeScoringContext()

    let result = scorer.score(items: items, archetype: archetype, rule: rule, context: context)
    let unpenalized = scorer.score(items: items, archetype: archetype, rule: rule, context: baseline)

    #expect(result.value == unpenalized.value)
    #expect(!result.reasoning.contains("last 2 weeks"))
}
