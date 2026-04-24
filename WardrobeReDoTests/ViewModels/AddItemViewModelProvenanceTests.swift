import Foundation
import Testing
@testable import WardrobeReDo

/// Tests for `AddItemViewModel.computeAttributeProvenance` — the pure
/// helper that diffs an `applyPrefill` snapshot against the final user-
/// edited form values and produces the `{field: "ai" | "user" |
/// "user_changed_from_ai"}` map that lands in
/// `wardrobe_items.detected_attributes` (migration 00009).
///
/// The function is the only thing under test here; we don't drive it
/// through the VM so each edge case stays isolated.
///
/// See [docs/plans/2026-04-19-auto-attribute-detection.md](../../docs/plans/2026-04-19-auto-attribute-detection.md)
/// Phase 7 for the full spec.
struct AddItemViewModelProvenanceTests {

    // MARK: - Helpers

    /// Trivial wrapper around the static helper. Matches the argument
    /// shape produced by `save(userId:)` at the call site, so the tests
    /// read as "given this snapshot + form state, expect this map."
    private func provenance(
        snapshot: [String: String] = [:],
        category: String = "top",
        subcategory: String = "tshirt",
        texture: String? = nil,
        fit: String? = nil,
        seasons: [String] = ["spring", "summer", "fall", "winter"],
        occasions: [String] = ["casual"]
    ) -> [String: String] {
        AddItemViewModel.computeAttributeProvenance(
            snapshot: snapshot,
            finalCategory: category,
            finalSubcategory: subcategory,
            finalTexture: texture,
            finalFit: fit,
            finalSeasons: seasons,
            finalOccasions: occasions
        )
    }

    // MARK: - "ai" — pre-fill accepted

    @Test func acceptedCategoryIsMarkedAI() {
        let result = provenance(
            snapshot: ["category": "outerwear"],
            category: "outerwear"
        )
        #expect(result["category"] == "ai")
    }

    @Test func acceptedTextureIsMarkedAI() {
        let result = provenance(
            snapshot: ["texture": "leather"],
            texture: "leather"
        )
        #expect(result["texture"] == "ai")
    }

    @Test func acceptedSeasonsAreMarkedAI() {
        // `applyPrefill` sorts + joins with ","; the final form value is
        // reconstructed the same way (sorted comma-join) before diffing,
        // so the ordering of the input array here doesn't matter.
        let result = provenance(
            snapshot: ["seasons": "fall,winter"],
            seasons: ["winter", "fall"]
        )
        #expect(result["seasons"] == "ai")
    }

    // MARK: - "user_changed_from_ai" — pre-fill overridden

    @Test func changedCategoryIsMarkedUserChanged() {
        let result = provenance(
            snapshot: ["category": "outerwear"],
            category: "top"
        )
        #expect(result["category"] == "user_changed_from_ai")
    }

    @Test func clearedOptionalFieldIsMarkedUserChanged() {
        // Texture was pre-filled to "leather" but the user cleared the
        // picker before saving — final value is nil.
        let result = provenance(
            snapshot: ["texture": "leather"],
            texture: nil
        )
        #expect(result["texture"] == "user_changed_from_ai")
    }

    @Test func narrowedSeasonsAreMarkedUserChanged() {
        let result = provenance(
            snapshot: ["seasons": "fall,winter"],
            seasons: ["winter"]
        )
        #expect(result["seasons"] == "user_changed_from_ai")
    }

    // MARK: - "user" — no pre-fill

    @Test func unPrefilledCategoryIsMarkedUser() {
        // Snapshot empty → ML never pre-filled; whatever category the
        // user saved is their own answer.
        let result = provenance(
            snapshot: [:],
            category: "top"
        )
        #expect(result["category"] == "user")
    }

    @Test func fallbackAllSeasonsIsMarkedUser() {
        // Rules engine returned empty seasons → `applyPrefill` seeded
        // `selectedSeasons = Set(Season.allCases)` AND snapshot["seasons"]
        // was never written. On save we join the full set and compare to
        // the absent snapshot key → "user" (not "ai"), because the user
        // didn't get an ML-driven suggestion for this field.
        let result = provenance(
            snapshot: [:],
            seasons: ["spring", "summer", "fall", "winter"]
        )
        #expect(result["seasons"] == "user")
    }

    // MARK: - Omission — nothing to record

    @Test func nilTextureWithNoSnapshotIsOmitted() {
        // User never touched texture (still nil) AND ML never pre-filled.
        // There's no signal to record, so the key is left out entirely.
        let result = provenance(snapshot: [:], texture: nil)
        #expect(result["texture"] == nil)
    }

    @Test func nilFitWithNoSnapshotIsOmitted() {
        let result = provenance(snapshot: [:], fit: nil)
        #expect(result["fit"] == nil)
    }

    // MARK: - End-to-end happy path

    @Test func fullMixedProvenanceMapMatchesExpectation() {
        // Scenario from docs/plans/2026-04-19-auto-attribute-detection.md:
        //   - category pre-filled, user accepted        → ai
        //   - subcategory pre-filled, user accepted     → ai
        //   - texture pre-filled, user overrode         → user_changed_from_ai
        //   - fit not pre-filled, user typed from scratch → user
        //   - seasons pre-filled, user accepted         → ai
        //   - occasions not pre-filled, user accepted fallback → user
        let result = provenance(
            snapshot: [
                "category": "outerwear",
                "subcategory": "leatherJacket",
                "texture": "leather",
                "seasons": "fall,winter",
            ],
            category: "outerwear",
            subcategory: "leatherJacket",
            texture: "wool",          // overridden
            fit: "oversized",         // user typed from scratch, no snapshot
            seasons: ["fall", "winter"],
            occasions: ["casual"]     // fallback default, no snapshot
        )

        #expect(result["category"] == "ai")
        #expect(result["subcategory"] == "ai")
        #expect(result["texture"] == "user_changed_from_ai")
        #expect(result["fit"] == "user")
        #expect(result["seasons"] == "ai")
        #expect(result["occasions"] == "user")
        #expect(result.count == 6)
    }

    @Test func emptyInputProducesEmptyMap() {
        // Nothing was pre-filled AND every optional field is nil AND
        // required fields defaulted. The required fields (category /
        // subcategory / seasons / occasions) still record "user" because
        // they have a final value even without ML input — only the
        // optional fields drop out.
        let result = provenance()
        #expect(result["texture"] == nil)
        #expect(result["fit"] == nil)
        #expect(result["category"] == "user")
        #expect(result["subcategory"] == "user")
        #expect(result["seasons"] == "user")
        #expect(result["occasions"] == "user")
    }
}
