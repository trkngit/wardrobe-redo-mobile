import Foundation
import Testing
@testable import WardrobeReDo

// MARK: - Fast Add quality guardrail (TF52)
//
// The "how much matching do we lose?" proof. Fast Add (`isFastAddEnabled`)
// drops the manual tagging form and saves items with AUTO-ONLY attributes:
//   • best-guess category/subcategory (assumed correct here — this test
//     isolates attribute-tagging loss, not category-prediction error),
//   • rules-derived texture (`AttributeRulesEngine.deriveTexture`),
//   • a neutral `.regular` fit default,
//   • k-means dominant colors (identical either way — extraction doesn't
//     depend on tagging), and
//   • formality computed + persisted by `FormalityFormula`.
//
// This test builds a fixture wardrobe, then scores a set of representative
// outfits twice — once with fully hand-tagged items, once with auto-only
// items — and asserts the aggregate outfit-score loss is small and that no
// load-bearing scoring dimension collapses to zero coverage. It is the
// regression guard for the TF52 trade-off: if a future change to the
// auto-fill defaults degrades scores, this fails.

/// Maximum tolerated mean relative loss in aggregate outfit score when
/// switching from fully hand-tagged to auto-only attributes. The TF52
/// design committed to "guard quality" while optimizing for speed; 8% is
/// the agreed ceiling on how much matching quality auto-fill may cost.
private let maxMeanScoreLoss = 0.08

private struct ItemSpec {
    let category: ClothingCategory
    let subcategory: ClothingSubcategory
    let colors: [ColorProfile]
    let handTexture: TextureType
    let handFit: FitAttribute
}

/// Builds the fully-tagged and auto-only variants of one item. Both share
/// the same identity, category/subcategory, and colors; they differ only
/// in the attributes Fast Add defaults rather than asks for (texture, fit)
/// and the formality derived from them. Seasons/occasions come from the
/// same rules derivation in both paths — the app derives those for every
/// item regardless of how it was added.
private func makeVariants(_ spec: ItemSpec) -> (full: WardrobeItem, auto: WardrobeItem) {
    let id = UUID()

    // Auto-only — exactly what Fast Add persists.
    let autoTexture = AttributeRulesEngine.deriveTexture(
        category: spec.category, subcategory: spec.subcategory
    )
    let autoFit: FitAttribute = .regular
    let (autoSeasons, autoOccasions) = AttributeRulesEngine.derive(
        category: spec.category, subcategory: spec.subcategory, texture: autoTexture
    )
    let autoFormality = FormalityFormula.compute(
        category: spec.category, texture: autoTexture,
        dominantColors: spec.colors, fitAttribute: autoFit
    ).value

    // Fully hand-tagged — a specific texture + fit the user picked, with
    // formality recomputed from those richer inputs by the same formula.
    let (handSeasons, handOccasions) = AttributeRulesEngine.derive(
        category: spec.category, subcategory: spec.subcategory, texture: spec.handTexture
    )
    let handFormality = FormalityFormula.compute(
        category: spec.category, texture: spec.handTexture,
        dominantColors: spec.colors, fitAttribute: spec.handFit
    ).value

    let full = TestFixtures.makeWardrobeItem(
        id: id, category: spec.category, subcategory: spec.subcategory,
        dominantColors: spec.colors, texture: spec.handTexture, fitAttribute: spec.handFit,
        formalityComputed: handFormality, seasons: Array(handSeasons), occasions: Array(handOccasions)
    )
    let auto = TestFixtures.makeWardrobeItem(
        id: id, category: spec.category, subcategory: spec.subcategory,
        dominantColors: spec.colors, texture: autoTexture, fitAttribute: autoFit,
        formalityComputed: autoFormality, seasons: Array(autoSeasons), occasions: Array(autoOccasions)
    )
    return (full, auto)
}

private func color(_ hex: String, lightness: Double) -> ColorProfile {
    TestFixtures.makeColorProfile(hex: hex, lightness: lightness)
}

/// 12-item fixture wardrobe spanning tops, bottoms, and shoes across the
/// casual→smart formality range.
private let wardrobeSpecs: [ItemSpec] = [
    // Tops
    .init(category: .top, subcategory: .tshirt, colors: [color("#3A6EA5", lightness: 0.45)], handTexture: .cotton, handFit: .regular),
    .init(category: .top, subcategory: .dressShirt, colors: [color("#F2F2F2", lightness: 0.92)], handTexture: .cotton, handFit: .slim),
    .init(category: .top, subcategory: .sweater, colors: [color("#7A7A7A", lightness: 0.48)], handTexture: .knit, handFit: .regular),
    .init(category: .top, subcategory: .hoodie, colors: [color("#1E1E1E", lightness: 0.12)], handTexture: .synthetic, handFit: .relaxed),
    // Bottoms
    .init(category: .bottom, subcategory: .jeans, colors: [color("#2B3A55", lightness: 0.30)], handTexture: .denim, handFit: .slim),
    .init(category: .bottom, subcategory: .chinos, colors: [color("#B6A179", lightness: 0.62)], handTexture: .cotton, handFit: .regular),
    .init(category: .bottom, subcategory: .dressPants, colors: [color("#36393F", lightness: 0.22)], handTexture: .wool, handFit: .slim),
    .init(category: .bottom, subcategory: .joggers, colors: [color("#23304A", lightness: 0.25)], handTexture: .synthetic, handFit: .relaxed),
    // Shoes
    .init(category: .shoe, subcategory: .sneakers, colors: [color("#FAFAFA", lightness: 0.95)], handTexture: .synthetic, handFit: .regular),
    .init(category: .shoe, subcategory: .dressShoes, colors: [color("#5A3A22", lightness: 0.28)], handTexture: .leather, handFit: .structured),
    .init(category: .shoe, subcategory: .boots, colors: [color("#1A1A1A", lightness: 0.10)], handTexture: .leather, handFit: .regular),
    .init(category: .shoe, subcategory: .loafers, colors: [color("#8B6B4A", lightness: 0.42)], handTexture: .suede, handFit: .structured),
]

/// Representative top+bottom+shoe outfits, indexing into `wardrobeSpecs`.
private let outfitIndexSets: [[Int]] = [
    [0, 4, 8],   // tee · jeans · sneakers
    [1, 6, 9],   // dress shirt · dress pants · dress shoes
    [2, 5, 10],  // sweater · chinos · boots
    [3, 7, 8],   // hoodie · joggers · sneakers
    [0, 5, 11],  // tee · chinos · loafers
]

@Test func fastAddAutoTaggingPreservesOutfitQuality() {
    #expect(wardrobeSpecs.count >= 12)

    let engine = StyleEngineService()
    let archetype = TestFixtures.makeStyleArchetype()
    let rule = TestFixtures.makeStyleRule()
    let context = TestFixtures.makeScoringContext()

    let variants = wardrobeSpecs.map(makeVariants)

    var relativeLosses: [Double] = []
    var autoCoveredCounts: [Int] = []

    for indices in outfitIndexSets {
        let fullItems = indices.map { variants[$0].full }
        let autoItems = indices.map { variants[$0].auto }

        let fullScore = engine.scoreOutfit(items: fullItems, archetype: archetype, rule: rule, context: context)
        let autoScore = engine.scoreOutfit(items: autoItems, archetype: archetype, rule: rule, context: context)

        // Relative loss in aggregate score (full is the reference).
        #expect(fullScore.totalScore > 0)
        relativeLosses.append(abs(fullScore.totalScore - autoScore.totalScore) / fullScore.totalScore)
        autoCoveredCounts.append(autoScore.coveredDimensionCount)

        // Coverage guarantees on the AUTO-only outfit.
        func coverage(_ dimension: ScoringDimension) -> Double {
            autoScore.breakdown.first { $0.dimension == dimension }?.coverage ?? 0
        }
        // ColorHarmony (highest weight) + Formality keep full coverage:
        // colors are always k-means-extracted and formality is persisted.
        #expect(coverage(.colorHarmony) == 1.0)
        #expect(coverage(.formalityCoherence) == 1.0)
        // TextureMix + ProportionBalance must not collapse to zero: the
        // rules texture and the `.regular` fit default keep them covered.
        #expect(coverage(.textureMix) > 0)
        #expect(coverage(.proportionBalance) > 0)
        // Majority of dimensions still contribute real signal.
        #expect(autoScore.coveredDimensionCount >= OutfitScore.minCoveredDimensions)
    }

    let meanLoss = relativeLosses.reduce(0, +) / Double(relativeLosses.count)
    let meanCovered = Double(autoCoveredCounts.reduce(0, +)) / Double(autoCoveredCounts.count)
    let worstLoss = relativeLosses.max() ?? 0
    // Surfaced in the test log so the actual quality cost is visible, not
    // just the pass/fail — this is the literal answer to "how much do we
    // lose?" the TF52 design set out to measure.
    print("[fast-add-guardrail] meanLoss=\(meanLoss) worstLoss=\(worstLoss) meanCovered=\(meanCovered)")

    // Primary guardrail: auto-fill costs at most `maxMeanScoreLoss` of
    // aggregate outfit quality on average.
    #expect(meanLoss <= maxMeanScoreLoss, "mean outfit-score loss \(meanLoss) exceeded ceiling \(maxMeanScoreLoss)")
    #expect(meanCovered >= Double(OutfitScore.minCoveredDimensions))
}
