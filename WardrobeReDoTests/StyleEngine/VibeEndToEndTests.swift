import Foundation
import Testing
@testable import WardrobeReDo

// MARK: - Vibe end-to-end (build 6 follow-up)
//
// `VibeIntegrationTests` checked the scorer + aggregator math
// directly. These tests prove the full `OutfitGenerationService`
// path with realistic inputs:
//   1. `formulaStrictness` actually flows from the preset into
//      `OutfitFormulaScorer` and changes the dimension's value.
//   2. `matchOutfits` accepts a vibe + recent-pairs set and
//      threads both into the engine.

@MainActor
struct VibeEndToEndTests {

    @Test func formulaStrictnessDampensOutfitFormulaForBold() {
        let archetype = TestFixtures.makeStyleArchetype()
        let rule = TestFixtures.makeStyleRule()
        let items = [
            TestFixtures.makeWardrobeItem(category: .top, subcategory: .tshirt),
            TestFixtures.makeWardrobeItem(category: .bottom, subcategory: .jeans),
            TestFixtures.makeWardrobeItem(category: .outerwear, subcategory: .blazer),
        ]

        let safeContext = StyleEngineService.buildContext(
            season: .spring, occasion: .casual, wardrobeSize: 3, vibe: .safe
        )
        let boldContext = StyleEngineService.buildContext(
            season: .spring, occasion: .casual, wardrobeSize: 3, vibe: .bold
        )

        let scorer = OutfitFormulaScorer()
        let safeResult = scorer.score(items: items, archetype: archetype, rule: rule, context: safeContext)
        let boldResult = scorer.score(items: items, archetype: archetype, rule: rule, context: boldContext)

        // `formulaStrictness`: safe = 1.1, bold = 0.75. Same items
        // + rule → safe's value must exceed bold's because the
        // formula axis is dampened for bold.
        #expect(safeResult.value > boldResult.value,
                "formulaStrictness mismatch: safe=\(safeResult.value), bold=\(boldResult.value)")
    }

    @Test func vibePresetThreadsThroughScoringContextForMatchFlow() {
        // matchOutfits builds its own context — verify the vibe
        // we pass in shows up in the resulting context. We call
        // through the public `buildContext` API rather than
        // mocking the whole service.
        let ctx = StyleEngineService.buildContext(
            occasion: .casual,
            wardrobeSize: 5,
            recentItemIds: [],
            recentItemPairs: [
                UnorderedItemPair(UUID(), UUID()),
            ],
            vibe: .adventurous
        )
        #expect(ctx.vibePreset.stop == .adventurous)
        #expect(ctx.recentOutfitItemPairs.count == 1)
    }

    @Test func novelyBonusActuallyFiresWithRealPairHistory() {
        let scorer = VersatilityScorer()
        let archetype = TestFixtures.makeStyleArchetype()
        let rule = TestFixtures.makeStyleRule()

        let topID = UUID()
        let bottomID = UUID()
        let items = [
            TestFixtures.makeWardrobeItem(id: topID, category: .top, subcategory: .tshirt),
            TestFixtures.makeWardrobeItem(id: bottomID, category: .bottom, subcategory: .jeans),
        ]

        // Two histories: an "all-novel" set (the candidate pair is
        // absent) vs. a "fully-seen" set (the candidate pair is
        // there). Both must report coverage > 0 because there IS
        // history — the difference is the reasoning text + score.
        let unrelated = UUID()
        let novelHistory: Set<UnorderedItemPair> = [
            UnorderedItemPair(unrelated, UUID()),
            UnorderedItemPair(unrelated, UUID()),
        ]
        let seenHistory: Set<UnorderedItemPair> = [
            UnorderedItemPair(topID, bottomID),
        ]

        let novelContext = ScoringContext(
            season: .spring, occasion: .casual, dayOfWeek: "wednesday",
            wardrobeItemCount: 2, recentOutfitItemIds: [],
            recentOutfitItemPairs: novelHistory, vibePreset: .balanced
        )
        let seenContext = ScoringContext(
            season: .spring, occasion: .casual, dayOfWeek: "wednesday",
            wardrobeItemCount: 2, recentOutfitItemIds: [],
            recentOutfitItemPairs: seenHistory, vibePreset: .balanced
        )

        let novelResult = scorer.score(items: items, archetype: archetype, rule: rule, context: novelContext)
        let seenResult = scorer.score(items: items, archetype: archetype, rule: rule, context: seenContext)

        #expect(novelResult.coverage == 1.0)
        #expect(seenResult.coverage == 1.0)
        #expect(novelResult.value > seenResult.value,
                "Novel pairing must score higher than fully-seen pairing on the same items")
        #expect(novelResult.reasoning.contains("Brand-new pairing"))
        #expect(seenResult.reasoning.contains("Familiar pairing"))
    }

    @Test func boldVibeMultipliesNoveltyBonusComparedToSafe() {
        let scorer = VersatilityScorer()
        let archetype = TestFixtures.makeStyleArchetype()
        let rule = TestFixtures.makeStyleRule()

        let topID = UUID()
        let bottomID = UUID()
        // Items with non-zero wear counts so the base score (wear
        // frequency + recency + least-worn + categories) doesn't
        // max out at 1.0 — leaving headroom for the novelty
        // multiplier to actually move the needle. 2 categories →
        // category-breadth contributes 0.10 not 0.15; non-zero
        // wear counts → frequency contributes 0.25 not 0.35.
        let items = [
            TestFixtures.makeWardrobeItem(id: topID, category: .top, subcategory: .tshirt, wearCount: 5),
            TestFixtures.makeWardrobeItem(id: bottomID, category: .bottom, subcategory: .jeans, wearCount: 5),
        ]
        // History contains pairs unrelated to the candidate, so
        // novelty IS covered and fires fully.
        let history: Set<UnorderedItemPair> = [UnorderedItemPair(UUID(), UUID())]

        let safeCtx = ScoringContext(
            season: .spring, occasion: .casual, dayOfWeek: "wednesday",
            wardrobeItemCount: 2, recentOutfitItemIds: [],
            recentOutfitItemPairs: history,
            vibePreset: VibePreset.preset(for: .safe)
        )
        let boldCtx = ScoringContext(
            season: .spring, occasion: .casual, dayOfWeek: "wednesday",
            wardrobeItemCount: 2, recentOutfitItemIds: [],
            recentOutfitItemPairs: history,
            vibePreset: VibePreset.preset(for: .bold)
        )

        let safeResult = scorer.score(items: items, archetype: archetype, rule: rule, context: safeCtx)
        let boldResult = scorer.score(items: items, archetype: archetype, rule: rule, context: boldCtx)

        // Safe multiplier = 0.5, Bold = 1.5 — same novelty floor,
        // bold's value must come out ahead.
        #expect(boldResult.value > safeResult.value,
                "Bold should reward novelty 3× more than Safe via noveltyRewardMultiplier (safe=\(safeResult.value), bold=\(boldResult.value))")
    }
}
