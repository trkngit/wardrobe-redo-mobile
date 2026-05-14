import Testing
@testable import WardrobeReDo

// MARK: - OutfitScore Tests

@Test func outfitScoreWeightedTotalMatchesManualCalculation() {
    let breakdown = [
        DimensionScore(dimension: .proportionBalance, value: 0.8, reasoning: ""),
        DimensionScore(dimension: .colorHarmony, value: 0.7, reasoning: ""),
        DimensionScore(dimension: .textureMix, value: 0.6, reasoning: ""),
        DimensionScore(dimension: .formalityCoherence, value: 0.9, reasoning: ""),
        DimensionScore(dimension: .outfitFormula, value: 0.5, reasoning: ""),
        DimensionScore(dimension: .versatility, value: 0.4, reasoning: ""),
        DimensionScore(dimension: .occasionContext, value: 1.0, reasoning: ""),
    ]

    let score = OutfitScore(breakdown: breakdown)

    // Manual: 0.8*0.15 + 0.7*0.25 + 0.6*0.10 + 0.9*0.15 + 0.5*0.15 + 0.4*0.10 + 1.0*0.10
    //       = 0.12 + 0.175 + 0.06 + 0.135 + 0.075 + 0.04 + 0.10 = 0.705
    let expected = 0.8 * 0.15 + 0.7 * 0.25 + 0.6 * 0.10 + 0.9 * 0.15 + 0.5 * 0.15 + 0.4 * 0.10 + 1.0 * 0.10
    #expect(abs(score.totalScore - expected) < 0.001, "Expected \(expected) but got \(score.totalScore)")
}

@Test func outfitScoreBreakdownContainsAllDimensions() {
    let breakdown = ScoringDimension.allCases.map {
        DimensionScore(dimension: $0, value: 0.5, reasoning: "test")
    }
    let score = OutfitScore(breakdown: breakdown)
    #expect(score.breakdown.count == 7)

    let dimensions = Set(score.breakdown.map(\.dimension))
    #expect(dimensions == Set(ScoringDimension.allCases))
}

@Test func outfitScoreWithEmptyBreakdownReturnsNeutralFallback() {
    // Build 6: coverage-aware aggregation. An empty breakdown has no
    // covered dimensions, so the weighted-average denominator is 0 and
    // we fall back to 0.5 (a neutral "no information" score) rather
    // than 0.0. `isLowCoverage` is true because zero dimensions
    // contributed real data — UI surfaces this as "Insufficient data".
    let score = OutfitScore(breakdown: [])
    #expect(score.totalScore == 0.5)
    #expect(score.breakdown.isEmpty)
    #expect(score.coveredDimensionCount == 0)
    #expect(score.isLowCoverage == true)
}
