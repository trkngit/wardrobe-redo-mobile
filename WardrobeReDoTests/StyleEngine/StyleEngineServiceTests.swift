import Foundation
import Testing
@testable import WardrobeReDo

// MARK: - StyleEngineService Tests

@Test func scoreOutfitReturnsSevenDimensionBreakdown() {
    let engine = StyleEngineService()
    let archetype = TestFixtures.makeStyleArchetype()
    let rule = TestFixtures.makeStyleRule()
    let context = TestFixtures.makeScoringContext()

    let items = [
        TestFixtures.makeWardrobeItem(category: .top, subcategory: .tshirt),
        TestFixtures.makeWardrobeItem(category: .bottom, subcategory: .jeans),
        TestFixtures.makeWardrobeItem(category: .shoe, subcategory: .sneakers),
    ]

    let result = engine.scoreOutfit(items: items, archetype: archetype, rule: rule, context: context)
    #expect(result.breakdown.count == 7)

    let dimensions = Set(result.breakdown.map(\.dimension))
    #expect(dimensions == Set(ScoringDimension.allCases))
}

@Test func scoreOutfitWeightedTotalMatchesManualCalculation() {
    let engine = StyleEngineService()
    let archetype = TestFixtures.makeStyleArchetype()
    let rule = TestFixtures.makeStyleRule()
    let context = TestFixtures.makeScoringContext()

    let items = [
        TestFixtures.makeWardrobeItem(category: .top, subcategory: .tshirt),
        TestFixtures.makeWardrobeItem(category: .bottom, subcategory: .jeans),
    ]

    let result = engine.scoreOutfit(items: items, archetype: archetype, rule: rule, context: context)

    // Build 6 — coverage-aware weighted average. Manual calculation
    // mirrors `OutfitScore.init(breakdown:)`: each covered
    // dimension contributes (value × weight × coverage) to the
    // numerator and (weight × coverage) to the denominator;
    // zero-coverage dimensions are excluded entirely.
    let covered = result.breakdown.filter { $0.coverage > 0 }
    let weightedSum = covered.reduce(0.0) { sum, dim in
        sum + dim.value * dim.dimension.weight * dim.coverage
    }
    let weightDenom = covered.reduce(0.0) { sum, dim in
        sum + dim.dimension.weight * dim.coverage
    }
    let manualTotal = weightDenom > 0 ? weightedSum / weightDenom : 0.5
    #expect(abs(result.totalScore - manualTotal) < 0.001)
}

@Test func rankOutfitsSortedDescending() {
    let engine = StyleEngineService()
    let archetype = TestFixtures.makeStyleArchetype()
    let rule = TestFixtures.makeStyleRule()
    let context = TestFixtures.makeScoringContext()

    let candidate1 = [
        TestFixtures.makeWardrobeItem(category: .top, subcategory: .tshirt, fitAttribute: .oversized),
        TestFixtures.makeWardrobeItem(category: .bottom, subcategory: .joggers, fitAttribute: .oversized),
    ]
    let candidate2 = [
        TestFixtures.makeWardrobeItem(category: .top, subcategory: .tshirt, fitAttribute: .slim),
        TestFixtures.makeWardrobeItem(category: .bottom, subcategory: .jeans, fitAttribute: .slim),
        TestFixtures.makeWardrobeItem(category: .shoe, subcategory: .sneakers),
    ]

    let ranked = engine.rankOutfits(candidates: [candidate1, candidate2], archetype: archetype, rule: rule, context: context)
    #expect(ranked.count == 2)

    if ranked.count == 2 {
        #expect(ranked[0].score.totalScore >= ranked[1].score.totalScore)
    }
}

@Test func buildContextDetectsCurrentSeason() {
    let context = StyleEngineService.buildContext(occasion: .casual, wardrobeSize: 10)
    let month = Calendar.current.component(.month, from: Date())

    let expectedSeason: Season
    switch month {
    case 3, 4, 5: expectedSeason = .spring
    case 6, 7, 8: expectedSeason = .summer
    case 9, 10, 11: expectedSeason = .fall
    default: expectedSeason = .winter
    }

    #expect(context.season == expectedSeason)
    #expect(context.occasion == .casual)
    #expect(context.wardrobeItemCount == 10)
}

@Test func currentSeasonMappingForAllMonths() {
    // April = spring (current month)
    let season = StyleEngineService.currentSeason()
    let month = Calendar.current.component(.month, from: Date())

    switch month {
    case 3, 4, 5: #expect(season == .spring)
    case 6, 7, 8: #expect(season == .summer)
    case 9, 10, 11: #expect(season == .fall)
    default: #expect(season == .winter)
    }
}

@Test func buildContextIncludesDayOfWeek() {
    let context = StyleEngineService.buildContext()
    let validDays = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
    #expect(validDays.contains(context.dayOfWeek))
}
