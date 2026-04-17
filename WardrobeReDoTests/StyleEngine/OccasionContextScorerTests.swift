import Testing
@testable import WardrobeReDo

// MARK: - OccasionContextScorer Tests

private let scorer = OccasionContextScorer()
private let archetype = TestFixtures.makeStyleArchetype(
    seasons: ["spring", "summer", "fall", "winter"],
    occasions: ["casual"]
)
private let rule = TestFixtures.makeStyleRule()

@Test func allItemsMatchSeasonScoresHigh() {
    let context = TestFixtures.makeScoringContext(season: .spring)
    let items = [
        TestFixtures.makeWardrobeItem(seasons: [.spring, .summer, .fall]),
        TestFixtures.makeWardrobeItem(category: .bottom, subcategory: .jeans, seasons: [.spring, .summer]),
    ]
    let result = scorer.score(items: items, archetype: archetype, rule: rule, context: context)
    // All items match season -> 0.3 for season
    #expect(result.reasoning.contains("seasonally appropriate"))
}

@Test func lessThanHalfSeasonMatchPenalized() {
    let context = TestFixtures.makeScoringContext(season: .winter)
    let items = [
        TestFixtures.makeWardrobeItem(seasons: [.summer]),
        TestFixtures.makeWardrobeItem(category: .bottom, subcategory: .shorts, seasons: [.summer]),
        TestFixtures.makeWardrobeItem(category: .shoe, subcategory: .sandals, seasons: [.summer]),
    ]
    let result = scorer.score(items: items, archetype: archetype, rule: rule, context: context)
    // 0/3 match winter -> "Most items are wrong"
    #expect(result.reasoning.contains("wrong for this season"))
}

@Test func allItemsMatchOccasionScoresHigh() {
    let context = TestFixtures.makeScoringContext(occasion: .casual)
    let items = [
        TestFixtures.makeWardrobeItem(occasions: [.casual]),
        TestFixtures.makeWardrobeItem(category: .bottom, subcategory: .jeans, occasions: [.casual, .date]),
    ]
    let result = scorer.score(items: items, archetype: archetype, rule: rule, context: context)
    #expect(result.reasoning.contains("suit the Casual context"))
}

@Test func occasionMismatchPenalized() {
    let context = TestFixtures.makeScoringContext(occasion: .formal)
    let items = [
        TestFixtures.makeWardrobeItem(occasions: [.casual]),
        TestFixtures.makeWardrobeItem(category: .bottom, subcategory: .jeans, occasions: [.casual]),
    ]
    let result = scorer.score(items: items, archetype: archetype, rule: rule, context: context)
    #expect(result.reasoning.contains("don't match"))
}

@Test func archetypeFitBothMatchPerfect() {
    let context = TestFixtures.makeScoringContext(season: .spring, occasion: .casual)
    let items = [TestFixtures.makeWardrobeItem()]
    let result = scorer.score(items: items, archetype: archetype, rule: rule, context: context)
    #expect(result.reasoning.contains("perfect"))
}

@Test func archetypeFitNeitherMatchLow() {
    // Archetype only matches casual in spring, but context is formal in winter
    let formalArchetype = TestFixtures.makeStyleArchetype(seasons: ["summer"], occasions: ["formal"])
    let context = TestFixtures.makeScoringContext(season: .winter, occasion: .casual)
    let items = [TestFixtures.makeWardrobeItem()]
    let result = scorer.score(items: items, archetype: formalArchetype, rule: rule, context: context)
    #expect(result.reasoning.contains("unconventional"))
}

@Test func seasonalBoostApplied() {
    let boostConditions = BoostConditions(
        seasonalBoosts: ["spring": 0.1],
        dayOfWeekBoosts: nil
    )
    let boostedRule = TestFixtures.makeStyleRule(boostConditions: boostConditions)
    let context = TestFixtures.makeScoringContext(season: .spring)
    let items = [TestFixtures.makeWardrobeItem()]

    let result = scorer.score(items: items, archetype: archetype, rule: boostedRule, context: context)
    #expect(result.reasoning.contains("seasonal boost"))
}

@Test func dayOfWeekBoostApplied() {
    let boostConditions = BoostConditions(
        seasonalBoosts: nil,
        dayOfWeekBoosts: ["friday": 0.15]
    )
    let boostedRule = TestFixtures.makeStyleRule(boostConditions: boostConditions)
    let context = TestFixtures.makeScoringContext(dayOfWeek: "friday")
    let items = [TestFixtures.makeWardrobeItem()]

    let result = scorer.score(items: items, archetype: archetype, rule: boostedRule, context: context)
    #expect(result.reasoning.contains("day-of-week boost"))
}

@Test func seasonPenaltyApplied() {
    let penaltyConditions = PenaltyConditions(
        avoidSeasons: ["winter"],
        avoidOccasions: nil
    )
    let penaltyRule = TestFixtures.makeStyleRule(penaltyConditions: penaltyConditions)
    let context = TestFixtures.makeScoringContext(season: .winter)
    let items = [TestFixtures.makeWardrobeItem()]

    let result = scorer.score(items: items, archetype: archetype, rule: penaltyRule, context: context)
    #expect(result.reasoning.contains("Season penalty"))
}

@Test func occasionPenaltyApplied() {
    let penaltyConditions = PenaltyConditions(
        avoidSeasons: nil,
        avoidOccasions: ["formal"]
    )
    let penaltyRule = TestFixtures.makeStyleRule(penaltyConditions: penaltyConditions)
    let context = TestFixtures.makeScoringContext(occasion: .formal)
    let items = [TestFixtures.makeWardrobeItem()]

    let result = scorer.score(items: items, archetype: archetype, rule: penaltyRule, context: context)
    #expect(result.reasoning.contains("Occasion penalty"))
}
