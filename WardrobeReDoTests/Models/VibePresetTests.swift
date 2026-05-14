import Foundation
import Testing
@testable import WardrobeReDo

// MARK: - VibePreset (build 6)
//
// Pins the per-stop preset table + the weight-renormalization
// helper. The integration check that a Bold outfit ranks
// differently from a Safe one lives in
// `VibeIntegrationTests`.

@Test func presetForEachStopHasCoherentColorAndProportionConstraints() {
    let safe = VibePreset.preset(for: .safe)
    let bold = VibePreset.preset(for: .bold)

    #expect(safe.colorMaxFamilies == 2)
    #expect(bold.colorMaxFamilies == 5)
    #expect(safe.colorMaxFamilies < bold.colorMaxFamilies,
            "Safe must hold the user to fewer color families than Bold")

    #expect(safe.formulaStrictness > 1.0,
            "Safe should require stricter formula adherence")
    #expect(bold.formulaStrictness < 1.0,
            "Bold should relax formula adherence")

    #expect(bold.noveltyRewardMultiplier > safe.noveltyRewardMultiplier,
            "Bold should reward novelty more than Safe")
}

@Test func renormalizedWeightsSumToOne() {
    let baseWeights = Dictionary(
        uniqueKeysWithValues: ScoringDimension.allCases.map { ($0, $0.weight) }
    )
    for stop in VibeStop.allCases {
        let preset = VibePreset.preset(for: stop)
        let weights = VibePreset.renormalizedWeights(base: baseWeights, preset: preset)
        let total = weights.values.reduce(0, +)
        #expect(abs(total - 1.0) < 0.0001,
                "renormalized weights for \(stop) must sum to 1, got \(total)")
    }
}

@Test func boldHasLowerColorWeightThanSafe() {
    let baseWeights = Dictionary(
        uniqueKeysWithValues: ScoringDimension.allCases.map { ($0, $0.weight) }
    )
    let safeWeights = VibePreset.renormalizedWeights(
        base: baseWeights,
        preset: VibePreset.preset(for: .safe)
    )
    let boldWeights = VibePreset.renormalizedWeights(
        base: baseWeights,
        preset: VibePreset.preset(for: .bold)
    )
    let safeColor = safeWeights[.colorHarmony] ?? 0
    let boldColor = boldWeights[.colorHarmony] ?? 0
    #expect(safeColor > boldColor,
            "Safe gives more weight to color harmony (\(safeColor)) than Bold (\(boldColor))")
}

@Test func boldHasHigherVersatilityWeightThanSafe() {
    let baseWeights = Dictionary(
        uniqueKeysWithValues: ScoringDimension.allCases.map { ($0, $0.weight) }
    )
    let safeWeights = VibePreset.renormalizedWeights(
        base: baseWeights,
        preset: VibePreset.preset(for: .safe)
    )
    let boldWeights = VibePreset.renormalizedWeights(
        base: baseWeights,
        preset: VibePreset.preset(for: .bold)
    )
    #expect((boldWeights[.versatility] ?? 0) > (safeWeights[.versatility] ?? 0),
            "Bold should give more weight to versatility (novelty) than Safe")
}

@Test func vibeStopSliderValuesAreOrdered() {
    let values = VibeStop.allCases.map(\.sliderValue)
    #expect(values == values.sorted(),
            "VibeStop.allCases must be ordered from lowest to highest sliderValue")
}

@Test func vibePresetIsCodableRoundTrip() throws {
    let preset = VibePreset.preset(for: .adventurous)
    let data = try JSONEncoder().encode(preset)
    let decoded = try JSONDecoder().decode(VibePreset.self, from: data)
    #expect(decoded == preset)
}
