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

// MARK: - End-to-end vibe + recent-pairs integration

@Test func novelOutfitRanksHigherUnderBoldThanSafe() {
    // Build an outfit whose pair set is entirely novel against the
    // user's history. Bold rewards novelty 3× more than Safe
    // (1.5 vs 0.5 multiplier), and Bold also weights Versatility
    // higher in the dimension vector. Combined, the same outfit
    // should rank higher under Bold than Safe.
    let engine = StyleEngineService()
    let archetype = TestFixtures.makeStyleArchetype()
    let rule = TestFixtures.makeStyleRule()

    let topID = UUID()
    let bottomID = UUID()
    let items = [
        TestFixtures.makeWardrobeItem(id: topID, category: .top, subcategory: .tshirt,
                                      dominantColors: [TestFixtures.makeColorProfile(colorFamily: "navy")]),
        TestFixtures.makeWardrobeItem(id: bottomID, category: .bottom, subcategory: .jeans,
                                      dominantColors: [TestFixtures.makeColorProfile(colorFamily: "blue")]),
    ]

    // Non-empty pair history that does NOT include the candidate
    // pair — gives the novelty axis "coverage = 1" (we have data
    // to compare against) while leaving the candidate fully novel.
    let unrelatedPair = UnorderedItemPair(UUID(), UUID())

    let safeContext = StyleEngineService.buildContext(
        season: .spring, occasion: .casual, wardrobeSize: 8,
        recentItemPairs: [unrelatedPair],
        vibe: .safe
    )
    let boldContext = StyleEngineService.buildContext(
        season: .spring, occasion: .casual, wardrobeSize: 8,
        recentItemPairs: [unrelatedPair],
        vibe: .bold
    )

    let safeScore = engine.scoreOutfit(items: items, archetype: archetype, rule: rule, context: safeContext)
    let boldScore = engine.scoreOutfit(items: items, archetype: archetype, rule: rule, context: boldContext)

    #expect(boldScore.totalScore > safeScore.totalScore,
            "Novel pairing should rank higher under .bold (\(boldScore.totalScore)) than .safe (\(safeScore.totalScore))")
}

@Test func formulaStrictnessLowersFormulaScoreUnderBold() {
    // Phase 6 wired `formulaStrictness` but the scorer only
    // started consuming it in the follow-up. Pin the contract: the
    // same outfit's Formula dimension reads lower under Bold than
    // under Safe because Bold multiplies the raw value by < 1 (0.92
    // in the post-tightening preset) while Safe multiplies by > 1
    // (1.05).
    let scorer = OutfitFormulaScorer()
    let archetype = TestFixtures.makeStyleArchetype()
    let rule = TestFixtures.makeStyleRule()

    let items = [
        TestFixtures.makeWardrobeItem(category: .top, subcategory: .tshirt,
                                      dominantColors: [TestFixtures.makeColorProfile(colorFamily: "navy")]),
        TestFixtures.makeWardrobeItem(category: .bottom, subcategory: .jeans,
                                      dominantColors: [TestFixtures.makeColorProfile(colorFamily: "navy")]),
        TestFixtures.makeWardrobeItem(category: .outerwear, subcategory: .blazer,
                                      dominantColors: [TestFixtures.makeColorProfile(colorFamily: "navy")]),
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
    let boldAware = ScoringContext(
        season: safeContext.season,
        occasion: safeContext.occasion,
        dayOfWeek: safeContext.dayOfWeek,
        wardrobeItemCount: safeContext.wardrobeItemCount,
        recentOutfitItemIds: safeContext.recentOutfitItemIds,
        recentOutfitItemPairs: safeContext.recentOutfitItemPairs,
        vibePreset: VibePreset.preset(for: .bold)
    )

    let safe = scorer.score(items: items, archetype: archetype, rule: rule, context: safeAware)
    let bold = scorer.score(items: items, archetype: archetype, rule: rule, context: boldAware)

    #expect(safe.value > bold.value,
            "Formula value should be stricter under .safe (\(safe.value)) than .bold (\(bold.value))")
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
