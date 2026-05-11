import Foundation
import Testing
@testable import WardrobeReDo

// MARK: - Coverage-aware aggregation (build 6)
//
// `OutfitScore.init(breakdown:)` switched from a raw weighted sum to
// a weight-renormalized average that excludes zero-coverage
// dimensions. These tests pin the new contract end to end:
//
//   1. Full coverage matches the legacy weighted-sum formula
//      exactly, so happy-path outputs are stable across the upgrade.
//   2. Zero-coverage dimensions are excluded from the average;
//      their weight is removed from the denominator.
//   3. Partial coverage scales contribution proportionally.
//   4. The `isLowCoverage` flag fires below 4 covered dimensions.
//   5. Legacy persisted JSON without `coverage` keys still
//      deserializes with `coverage = 1.0`, preserving historical
//      scores byte-for-byte.

@Test func outfitScoreFullCoverageMatchesLegacyWeightedSum() {
    // Every dimension at coverage=1.0 reduces the new formula to
    // the pre-build-6 Σ wᵢ·sᵢ — the weighted average's denominator
    // becomes Σ wᵢ = 1.0 (the dimension weights sum to 1.0 by
    // contract). Sanity-check that the upgrade preserves stable
    // scores on outfits with full data.
    let breakdown: [DimensionScore] = ScoringDimension.allCases.map { dim in
        DimensionScore(dimension: dim, value: 0.7, coverage: 1.0, reasoning: "")
    }
    let score = OutfitScore(breakdown: breakdown)

    // Expected = 0.7 (every dimension same value, weights sum to 1).
    #expect(abs(score.totalScore - 0.7) < 0.0001)
    #expect(score.coveredDimensionCount == ScoringDimension.allCases.count)
    #expect(score.isLowCoverage == false)
}

@Test func outfitScoreExcludesZeroCoverageDimensions() {
    // Two dimensions covered, five at coverage=0 — the average
    // should reflect only the two covered dimensions' weights.
    let covered: [DimensionScore] = [
        DimensionScore(dimension: .colorHarmony, value: 0.8, coverage: 1.0, reasoning: ""),
        DimensionScore(dimension: .occasionContext, value: 0.6, coverage: 1.0, reasoning: ""),
    ]
    let zeroed: [DimensionScore] = ScoringDimension.allCases
        .filter { $0 != .colorHarmony && $0 != .occasionContext }
        .map { DimensionScore(dimension: $0, value: 0.5, coverage: 0.0, reasoning: "") }
    let score = OutfitScore(breakdown: covered + zeroed)

    // Hand-computed: (0.8 * 0.25 + 0.6 * 0.10) / (0.25 + 0.10) ≈ 0.7429
    let expected = (0.8 * 0.25 + 0.6 * 0.10) / (0.25 + 0.10)
    #expect(abs(score.totalScore - expected) < 0.0001)
    #expect(score.coveredDimensionCount == 2)
}

@Test func outfitScorePartialCoverageRescalesProportionally() {
    // Coverage=0.4 means a dimension contributes 40% of its weight
    // to both the weighted sum and the denominator. The resulting
    // average lies between the contributions weighted by their
    // partial coverage shares.
    let breakdown: [DimensionScore] = [
        DimensionScore(dimension: .colorHarmony, value: 1.0, coverage: 1.0, reasoning: ""),
        DimensionScore(dimension: .textureMix, value: 0.0, coverage: 0.4, reasoning: ""),
    ]
    let score = OutfitScore(breakdown: breakdown)

    // Expected: (1.0 * 0.25 * 1.0 + 0.0 * 0.10 * 0.4) / (0.25 * 1.0 + 0.10 * 0.4)
    //         = 0.25 / 0.29 ≈ 0.8621
    let expected = (1.0 * 0.25 * 1.0 + 0.0 * 0.10 * 0.4) / (0.25 * 1.0 + 0.10 * 0.4)
    #expect(abs(score.totalScore - expected) < 0.0001)
}

@Test func outfitScoreReturnsHalfWhenAllZeroCoverage() {
    let breakdown: [DimensionScore] = ScoringDimension.allCases.map { dim in
        DimensionScore(dimension: dim, value: 0.7, coverage: 0.0, reasoning: "")
    }
    let score = OutfitScore(breakdown: breakdown)

    #expect(score.totalScore == 0.5)
    #expect(score.coveredDimensionCount == 0)
    #expect(score.isLowCoverage == true)
}

@Test func outfitScoreIsLowCoverageBelowFourDimensions() {
    // Three covered dimensions — below the 4-of-7 floor.
    let breakdown: [DimensionScore] = [
        DimensionScore(dimension: .colorHarmony, value: 0.8, coverage: 1.0, reasoning: ""),
        DimensionScore(dimension: .occasionContext, value: 0.7, coverage: 1.0, reasoning: ""),
        DimensionScore(dimension: .outfitFormula, value: 0.6, coverage: 1.0, reasoning: ""),
    ]
    let score = OutfitScore(breakdown: breakdown)
    #expect(score.coveredDimensionCount == 3)
    #expect(score.isLowCoverage == true)
}

@Test func outfitScoreIsHighCoverageAtFourDimensions() {
    let breakdown: [DimensionScore] = [
        DimensionScore(dimension: .colorHarmony, value: 0.8, coverage: 1.0, reasoning: ""),
        DimensionScore(dimension: .occasionContext, value: 0.7, coverage: 1.0, reasoning: ""),
        DimensionScore(dimension: .outfitFormula, value: 0.6, coverage: 1.0, reasoning: ""),
        DimensionScore(dimension: .proportionBalance, value: 0.7, coverage: 1.0, reasoning: ""),
    ]
    let score = OutfitScore(breakdown: breakdown)
    #expect(score.coveredDimensionCount == 4)
    #expect(score.isLowCoverage == false)
}

@Test func dimensionScoreCoverageDefaultsToOneWhenDecodingLegacyJson() throws {
    // Pre-build-6 persisted JSON omits the `coverage` field. The
    // decoder must hydrate it as 1.0 so the historical score
    // recomputes identically under the new aggregator.
    let legacy = """
    {
      "dimension": "color_harmony",
      "value": 0.8,
      "reasoning": "Three colors well-balanced"
    }
    """.data(using: .utf8)!
    let decoded = try JSONDecoder().decode(DimensionScore.self, from: legacy)
    #expect(decoded.coverage == 1.0)
    #expect(decoded.value == 0.8)
}

@Test func outfitScoreEncodesCoverageWhenPresent() throws {
    let breakdown = [
        DimensionScore(dimension: .colorHarmony, value: 0.9, coverage: 0.6, reasoning: "Partial"),
    ]
    let score = OutfitScore(breakdown: breakdown)
    let data = try JSONEncoder().encode(score)
    let json = String(data: data, encoding: .utf8) ?? ""
    #expect(json.contains("\"coverage\":0.6"))
    #expect(json.contains("\"coveredDimensionCount\":1"))
}
