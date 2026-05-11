import Foundation
import Testing
@testable import WardrobeReDo

// MARK: - Vibe slider integration (build 6)
//
// Verifies the slider actually changes outfit ranking — picking
// `.bold` instead of `.safe` should produce a measurably different
// total score on the same outfit. This is the user-visible
// promise of the feature.

@Test func vibeIsThreadedThroughScoringContext() {
    let context = StyleEngineService.buildContext(
        season: .spring,
        occasion: .casual,
        wardrobeSize: 12,
        vibe: .bold
    )
    #expect(context.vibePreset.stop == .bold)
}

@Test func boldVibeRanksColorRichOutfitsHigherThanSafe() {
    let engine = StyleEngineService()
    let archetype = TestFixtures.makeStyleArchetype()
    let rule = TestFixtures.makeStyleRule()

    // Color-rich outfit: 4 distinct color families. Bold's cap is
    // 5; Safe's cap is 2, so the same items will score very
    // differently on the color axis.
    let items = [
        TestFixtures.makeWardrobeItem(
            category: .top,
            subcategory: .tshirt,
            dominantColors: [TestFixtures.makeColorProfile(colorFamily: "red")]
        ),
        TestFixtures.makeWardrobeItem(
            category: .bottom,
            subcategory: .jeans,
            dominantColors: [TestFixtures.makeColorProfile(colorFamily: "blue")]
        ),
        TestFixtures.makeWardrobeItem(
            category: .outerwear,
            subcategory: .blazer,
            dominantColors: [TestFixtures.makeColorProfile(colorFamily: "green")]
        ),
        TestFixtures.makeWardrobeItem(
            category: .accessory,
            subcategory: .belt,
            dominantColors: [TestFixtures.makeColorProfile(colorFamily: "yellow")]
        ),
    ]

    let safeContext = StyleEngineService.buildContext(
        season: .spring, occasion: .casual, wardrobeSize: 4, vibe: .safe
    )
    let boldContext = StyleEngineService.buildContext(
        season: .spring, occasion: .casual, wardrobeSize: 4, vibe: .bold
    )

    let safeScore = engine.scoreOutfit(items: items, archetype: archetype, rule: rule, context: safeContext)
    let boldScore = engine.scoreOutfit(items: items, archetype: archetype, rule: rule, context: boldContext)

    #expect(boldScore.totalScore > safeScore.totalScore,
            "4-color outfit must score higher under .bold (\(boldScore.totalScore)) than .safe (\(safeScore.totalScore))")
}

@Test func vibeAffectsColorReasoningText() {
    let scorer = ColorHarmonyScorer()
    let archetype = TestFixtures.makeStyleArchetype()
    let rule = TestFixtures.makeStyleRule()

    let items = [
        TestFixtures.makeWardrobeItem(
            category: .top,
            subcategory: .tshirt,
            dominantColors: [TestFixtures.makeColorProfile(colorFamily: "red")]
        ),
        TestFixtures.makeWardrobeItem(
            category: .bottom,
            subcategory: .jeans,
            dominantColors: [TestFixtures.makeColorProfile(colorFamily: "blue")]
        ),
        TestFixtures.makeWardrobeItem(
            category: .outerwear,
            subcategory: .blazer,
            dominantColors: [TestFixtures.makeColorProfile(colorFamily: "green")]
        ),
    ]

    let safeContext = TestFixtures.makeScoringContext()
    let safeAware = ScoringContext(
        season: safeContext.season,
        occasion: safeContext.occasion,
        dayOfWeek: safeContext.dayOfWeek,
        wardrobeItemCount: safeContext.wardrobeItemCount,
        recentOutfitItemIds: safeContext.recentOutfitItemIds,
        recentOutfitItemPairs: safeContext.recentOutfitItemPairs,
        vibePreset: VibePreset.preset(for: .safe)
    )
    let safeResult = scorer.score(items: items, archetype: archetype, rule: rule, context: safeAware)
    // 3 families on a Safe vibe (cap = 2) → "too many" branch
    #expect(safeResult.reasoning.contains("Too many colors") ||
            safeResult.reasoning.contains("above your vibe's cap"),
            "Safe vibe should flag 3 families as exceeding the cap; got: \(safeResult.reasoning)")
}
