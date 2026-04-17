import Testing
@testable import WardrobeReDo

// MARK: - ScoringDimension Tests

@Test func scoringDimensionWeightsSumToOne() {
    let totalWeight = ScoringDimension.allCases.reduce(0.0) { $0 + $1.weight }
    #expect(abs(totalWeight - 1.0) < 0.001, "Weights should sum to 1.0, got \(totalWeight)")
}

@Test func scoringDimensionWeightsMatchDesignSpec() {
    #expect(ScoringDimension.proportionBalance.weight == 0.15)
    #expect(ScoringDimension.colorHarmony.weight == 0.25)
    #expect(ScoringDimension.textureMix.weight == 0.10)
    #expect(ScoringDimension.formalityCoherence.weight == 0.15)
    #expect(ScoringDimension.outfitFormula.weight == 0.15)
    #expect(ScoringDimension.versatility.weight == 0.10)
    #expect(ScoringDimension.occasionContext.weight == 0.10)
}

@Test func scoringDimensionDisplayNamesAreNonEmpty() {
    for dim in ScoringDimension.allCases {
        #expect(!dim.displayName.isEmpty, "\(dim) has empty displayName")
    }
}
