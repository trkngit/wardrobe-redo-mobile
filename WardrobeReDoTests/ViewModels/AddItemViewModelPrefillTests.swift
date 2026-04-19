import Foundation
import Testing
import UIKit
@testable import WardrobeReDo

/// Tests for the Phase 0 auto-attribute pre-fill path in
/// `AddItemViewModel.startNextProposal()`. The ViewModel pulls predicted
/// attributes from the current `MaskProposal` and seeds the Add Item form
/// with them, thresholding each field by `AttributePrefill.minConfidence`
/// so low-confidence guesses never land on the picker.
///
/// Tests drive the ViewModel directly via `vm.proposals` +
/// `onMultiPickConfirmed()` rather than going through
/// `ImageService.processImage`, which keeps the surface tight: the pre-
/// fill logic is the only thing under test. Service-layer integration
/// lives in `ImageServiceProposalsTests` / `AutoAttributeE2ETests`.
///
/// See [docs/plans/2026-04-19-auto-attribute-detection.md](../../docs/plans/2026-04-19-auto-attribute-detection.md)
/// Phase 0 for the full spec.

// MARK: - Category threshold

@Test @MainActor func addItemPrefillsCategoryWhenConfidenceAboveThreshold() {
    let vm = AddItemViewModel()
    let proposal = MaskProposalFixture.make(
        predictedCategory: .outerwear,
        predictedCategoryConfidence: 0.95
    )
    vm.proposals = [proposal]
    vm.selectedProposalIDs = [proposal.id]

    vm.onMultiPickConfirmed()

    #expect(vm.category == .outerwear)
    #expect(vm.detectedAttributes["category"] == ClothingCategory.outerwear.rawValue)
}

@Test @MainActor func addItemSkipsCategoryPrefillWhenBelowThreshold() {
    let vm = AddItemViewModel()
    let proposal = MaskProposalFixture.make(
        predictedCategory: .outerwear,
        predictedCategoryConfidence: 0.50
    )
    vm.proposals = [proposal]
    vm.selectedProposalIDs = [proposal.id]

    vm.onMultiPickConfirmed()

    #expect(vm.category == .top, "sub-threshold prediction should fall back to the default .top")
    #expect(vm.detectedAttributes["category"] == nil, "snapshot should omit fields that weren't pre-filled")
}

@Test @MainActor func addItemSkipsCategoryPrefillWhenPredictionMissing() {
    let vm = AddItemViewModel()
    let proposal = MaskProposalFixture.make(
        predictedCategory: nil,
        predictedCategoryConfidence: 0.0
    )
    vm.proposals = [proposal]
    vm.selectedProposalIDs = [proposal.id]

    vm.onMultiPickConfirmed()

    #expect(vm.category == .top)
    #expect(vm.detectedAttributes["category"] == nil)
}

// MARK: - Subcategory

@Test @MainActor func addItemUsesPredictedSubcategoryWhenCategoryMatches() {
    let vm = AddItemViewModel()
    let proposal = MaskProposalFixture.make(
        predictedCategory: .top,
        predictedCategoryConfidence: 0.95,
        predictedSubcategory: .buttonDown
    )
    vm.proposals = [proposal]
    vm.selectedProposalIDs = [proposal.id]

    vm.onMultiPickConfirmed()

    #expect(vm.subcategory == .buttonDown)
    #expect(vm.detectedAttributes["subcategory"] == ClothingSubcategory.buttonDown.rawValue)
}

@Test @MainActor func addItemDropsSubcategoryWhenCategoryMismatch() {
    // Predicted subcategory .sneakers belongs to .shoe, but the category
    // prediction falls below the threshold so the final category stays
    // .top. The subcategory can't dangle on .top's picker, so the guard
    // should drop the prediction and fall back to the .top default.
    let vm = AddItemViewModel()
    let proposal = MaskProposalFixture.make(
        predictedCategory: .shoe,
        predictedCategoryConfidence: 0.50, // below threshold, category stays .top
        predictedSubcategory: .sneakers
    )
    vm.proposals = [proposal]
    vm.selectedProposalIDs = [proposal.id]

    vm.onMultiPickConfirmed()

    #expect(vm.category == .top)
    #expect(vm.subcategory == .tshirt, "mismatched subcategory should fall back to category default")
    #expect(vm.detectedAttributes["subcategory"] == nil)
}

// MARK: - Texture threshold

@Test @MainActor func addItemPrefillsTextureWhenConfidenceAboveThreshold() {
    let vm = AddItemViewModel()
    let proposal = MaskProposalFixture.make(
        predictedTexture: .leather,
        predictedTextureConfidence: 0.85
    )
    vm.proposals = [proposal]
    vm.selectedProposalIDs = [proposal.id]

    vm.onMultiPickConfirmed()

    #expect(vm.texture == .leather)
    #expect(vm.detectedAttributes["texture"] == TextureType.leather.rawValue)
}

@Test @MainActor func addItemSkipsTexturePrefillWhenBelowThreshold() {
    let vm = AddItemViewModel()
    let proposal = MaskProposalFixture.make(
        predictedTexture: .silk,
        predictedTextureConfidence: 0.70
    )
    vm.proposals = [proposal]
    vm.selectedProposalIDs = [proposal.id]

    vm.onMultiPickConfirmed()

    #expect(vm.texture == nil)
    #expect(vm.detectedAttributes["texture"] == nil)
}

// MARK: - Fit threshold

@Test @MainActor func addItemPrefillsFitWhenConfidenceAboveThreshold() {
    let vm = AddItemViewModel()
    let proposal = MaskProposalFixture.make(
        predictedFit: .oversized,
        predictedFitConfidence: 0.90
    )
    vm.proposals = [proposal]
    vm.selectedProposalIDs = [proposal.id]

    vm.onMultiPickConfirmed()

    #expect(vm.fitAttribute == .oversized)
    #expect(vm.detectedAttributes["fit"] == FitAttribute.oversized.rawValue)
}

// MARK: - Seasons fallback

@Test @MainActor func addItemFallsBackToAllSeasonsWhenPredictedSeasonsEmpty() {
    let vm = AddItemViewModel()
    let proposal = MaskProposalFixture.make(
        predictedSeasons: []
    )
    vm.proposals = [proposal]
    vm.selectedProposalIDs = [proposal.id]

    vm.onMultiPickConfirmed()

    #expect(vm.selectedSeasons == Set(Season.allCases),
           "empty predictions must fall back to all-seasons, never leave the picker empty")
    #expect(vm.detectedAttributes["seasons"] == nil, "fallback values aren't recorded as ML-driven")
}

@Test @MainActor func addItemUsesPredictedSeasonsWhenProvided() {
    let vm = AddItemViewModel()
    let proposal = MaskProposalFixture.make(
        predictedSeasons: [.fall, .winter]
    )
    vm.proposals = [proposal]
    vm.selectedProposalIDs = [proposal.id]

    vm.onMultiPickConfirmed()

    #expect(vm.selectedSeasons == Set([Season.fall, Season.winter]))
    #expect(vm.detectedAttributes["seasons"] == "fall,winter",
           "snapshot joins season rawValues in sorted order")
}

// MARK: - Occasions fallback

@Test @MainActor func addItemFallsBackToCasualWhenPredictedOccasionsEmpty() {
    let vm = AddItemViewModel()
    let proposal = MaskProposalFixture.make(
        predictedOccasions: []
    )
    vm.proposals = [proposal]
    vm.selectedProposalIDs = [proposal.id]

    vm.onMultiPickConfirmed()

    #expect(vm.selectedOccasions == [.casual],
           "empty predictions must fall back to [.casual], never leave the picker empty")
    #expect(vm.detectedAttributes["occasions"] == nil)
}

@Test @MainActor func addItemUsesPredictedOccasionsWhenProvided() {
    let vm = AddItemViewModel()
    let proposal = MaskProposalFixture.make(
        predictedOccasions: [.work, .formal]
    )
    vm.proposals = [proposal]
    vm.selectedProposalIDs = [proposal.id]

    vm.onMultiPickConfirmed()

    #expect(vm.selectedOccasions == Set([Occasion.work, Occasion.formal]))
    #expect(vm.detectedAttributes["occasions"] == "formal,work",
           "snapshot joins occasion rawValues in sorted order")
}

// MARK: - Snapshot lifecycle

@Test @MainActor func addItemRecordsFullDetectedAttributesSnapshot() {
    let vm = AddItemViewModel()
    let proposal = MaskProposalFixture.make(
        predictedCategory: .outerwear,
        predictedCategoryConfidence: 0.95,
        predictedSubcategory: .leatherJacket,
        predictedTexture: .leather,
        predictedTextureConfidence: 0.90,
        predictedFit: .oversized,
        predictedFitConfidence: 0.85,
        predictedSeasons: [.fall, .winter],
        predictedOccasions: [.casual, .date]
    )
    vm.proposals = [proposal]
    vm.selectedProposalIDs = [proposal.id]

    vm.onMultiPickConfirmed()

    #expect(vm.detectedAttributes["category"] == "outerwear")
    #expect(vm.detectedAttributes["subcategory"] == "leatherJacket")
    #expect(vm.detectedAttributes["texture"] == "leather")
    #expect(vm.detectedAttributes["fit"] == "oversized")
    #expect(vm.detectedAttributes["seasons"] == "fall,winter")
    #expect(vm.detectedAttributes["occasions"] == "casual,date")
}

@Test @MainActor func addItemResetClearsDetectedAttributes() {
    let vm = AddItemViewModel()
    vm.detectedAttributes = ["category": "outerwear", "texture": "leather"]

    vm.reset()

    #expect(vm.detectedAttributes.isEmpty)
}
