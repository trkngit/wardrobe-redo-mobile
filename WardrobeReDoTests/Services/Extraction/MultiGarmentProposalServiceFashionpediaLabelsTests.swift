import Foundation
import Testing
@testable import WardrobeReDo

/// Drift guard between the Fashionpedia label array in
/// `MultiGarmentProposalService.fashionpediaLabels` and the
/// `ClothingCategory.fromFashionpediaClass` mapping.
///
/// Without these tests, the following regression would be silent at
/// build time and only surface when the trained model ships:
///   1. Someone adds "blazer_coat" to the notebook's `FASHIONPEDIA_CLASSES`
///   2. They copy the new list into `fashionpediaLabels` here
///   3. They forget to extend `fromFashionpediaClass` with a case for it
///   4. At runtime, every "blazer_coat" detection returns
///      `predictedCategory = nil`, the multi-pick overlay drops the
///      category chip, and the user sees an unlabelled proposal.
///
/// These tests fail the build at step 2 instead, before the model even
/// runs.
struct MultiGarmentProposalServiceFashionpediaLabelsTests {

    // MARK: - Drift guard (the important one)

    @Test func everyLabelEitherMapsOrIsExplicitlyExcluded() {
        for label in MultiGarmentProposalService.fashionpediaLabels {
            let mapped = ClothingCategory.fromFashionpediaClass(label)
            let excluded = MultiGarmentProposalService.fashionpediaExcludedLabels.contains(label)
            #expect(
                mapped != nil || excluded,
                "Fashionpedia label '\(label)' neither maps to a ClothingCategory nor is in the excluded set"
            )
        }
    }

    @Test func everyExcludedLabelIsAlsoInTheMainLabelArray() {
        for excluded in MultiGarmentProposalService.fashionpediaExcludedLabels {
            #expect(
                MultiGarmentProposalService.fashionpediaLabels.contains(excluded),
                "'\(excluded)' is in excluded set but not in fashionpediaLabels — set went out of sync"
            )
        }
    }

    @Test func excludedLabelsMapToNil() {
        for excluded in MultiGarmentProposalService.fashionpediaExcludedLabels {
            #expect(
                ClothingCategory.fromFashionpediaClass(excluded) == nil,
                "'\(excluded)' is in excluded set but fromFashionpediaClass returned a category"
            )
        }
    }

    // MARK: - Array shape

    @Test func labelArrayHasThirtyThreeEntries() {
        // Must match the notebook's FASHIONPEDIA_CLASSES list. Bump this
        // + the notebook in lockstep when Fashionpedia's schema evolves.
        #expect(MultiGarmentProposalService.fashionpediaLabels.count == 33)
    }

    @Test func labelArrayHasNoDuplicates() {
        let labels = MultiGarmentProposalService.fashionpediaLabels
        #expect(Set(labels).count == labels.count, "fashionpediaLabels contains duplicate entries")
    }

    // MARK: - labelForIndex round-trips

    @Test func labelForIndexZeroIsShirtBlouse() {
        // Head of the array. If someone reshuffles, a Fashionpedia label
        // fixture test will also fail — belt-and-suspenders.
        #expect(MultiGarmentProposalService.labelForIndex(0) == "shirt_blouse")
    }

    @Test func labelForIndexLastIsUmbrella() {
        let last = MultiGarmentProposalService.fashionpediaLabels.count - 1
        #expect(MultiGarmentProposalService.labelForIndex(last) == "umbrella")
    }

    @Test func labelForIndexNegativeFallsBackToClassPrefix() {
        #expect(MultiGarmentProposalService.labelForIndex(-1) == "class_-1")
    }

    @Test func labelForIndexOutOfRangeFallsBackToClassPrefix() {
        let over = MultiGarmentProposalService.fashionpediaLabels.count + 5
        #expect(MultiGarmentProposalService.labelForIndex(over) == "class_\(over)")
    }
}
