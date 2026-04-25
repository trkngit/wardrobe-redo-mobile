import Foundation
import Testing
@testable import WardrobeReDo

/// Coverage for `OutfitGenerationService.deduplicateCandidates(_:limit:)`.
///
/// The daily-outfit flow now runs every result list through this
/// helper so two archetypes that pick identical item sets at slightly
/// different scores collapse to a single card. Without this, a small
/// wardrobe surfaces duplicate outfits with different editorial names
/// (e.g. "Saturday Refined" 77 + "The Capsule" 78 — same items, same
/// description, different score).
///
/// `deduplicateCandidates` is the existing helper at
/// `OutfitGenerationService.swift` — these tests pin the contract so
/// the daily-outfit caller can rely on it.
@Suite("OutfitGenerationService.deduplicateCandidates") struct OutfitDeduplicationTests {

    @Test func collapsesIdenticalItemSetsKeepsHigherScore() {
        let items: [WardrobeItem] = [
            TestFixtures.makeWardrobeItem(category: .top, subcategory: .tshirt),
            TestFixtures.makeWardrobeItem(category: .bottom, subcategory: .jeans),
            TestFixtures.makeWardrobeItem(category: .shoe, subcategory: .sneakers),
        ]
        let archetype = TestFixtures.makeStyleArchetype()
        let rule = TestFixtures.makeStyleRule()

        let lowScore = OutfitCandidate(
            items: items, archetype: archetype, rule: rule,
            score: dimensionScore(0.77),
            slots: [], editorialName: "Saturday Refined", editorialDescription: ""
        )
        let highScore = OutfitCandidate(
            items: items, archetype: archetype, rule: rule,
            score: dimensionScore(0.78),
            slots: [], editorialName: "The Capsule", editorialDescription: ""
        )

        let service = OutfitGenerationService()
        let result = service.deduplicateCandidates([highScore, lowScore], limit: 3)

        #expect(result.count == 1)
        #expect(result.first?.editorialName == "The Capsule")
    }

    @Test func keepsDistinctItemSets() {
        let topA = TestFixtures.makeWardrobeItem(category: .top, subcategory: .tshirt)
        let topB = TestFixtures.makeWardrobeItem(category: .top, subcategory: .polo)
        let bottom = TestFixtures.makeWardrobeItem(category: .bottom, subcategory: .jeans)
        let shoe = TestFixtures.makeWardrobeItem(category: .shoe, subcategory: .sneakers)
        let archetype = TestFixtures.makeStyleArchetype()
        let rule = TestFixtures.makeStyleRule()

        let outfitA = OutfitCandidate(
            items: [topA, bottom, shoe], archetype: archetype, rule: rule,
            score: dimensionScore(0.78),
            slots: [], editorialName: "Outfit A", editorialDescription: ""
        )
        let outfitB = OutfitCandidate(
            items: [topB, bottom, shoe], archetype: archetype, rule: rule,
            score: dimensionScore(0.75),
            slots: [], editorialName: "Outfit B", editorialDescription: ""
        )

        let service = OutfitGenerationService()
        let result = service.deduplicateCandidates([outfitA, outfitB], limit: 3)
        #expect(result.count == 2)
    }

    @Test func limitCapsResultLength() {
        let archetype = TestFixtures.makeStyleArchetype()
        let rule = TestFixtures.makeStyleRule()
        // Five candidates with distinct item sets, scores descending.
        let candidates: [OutfitCandidate] = (0..<5).map { i in
            let item = TestFixtures.makeWardrobeItem(category: .top, subcategory: .tshirt)
            return OutfitCandidate(
                items: [item], archetype: archetype, rule: rule,
                score: dimensionScore(0.9 - Double(i) * 0.05),
                slots: [], editorialName: "Outfit \(i)", editorialDescription: ""
            )
        }

        let service = OutfitGenerationService()
        let result = service.deduplicateCandidates(candidates, limit: 3)
        #expect(result.count == 3)
    }

    // MARK: - Helpers

    private func dimensionScore(_ total: Double) -> OutfitScore {
        let breakdown = ScoringDimension.allCases.map {
            DimensionScore(dimension: $0, value: total, reasoning: "")
        }
        return OutfitScore(breakdown: breakdown)
    }
}
