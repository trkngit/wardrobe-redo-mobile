import Foundation
import Testing
import UIKit
@testable import WardrobeReDo

/// Pin-down tests for the Build 5 inversion of accessory + shoe rescue
/// ordering inside `AddItemViewModel.applyPrefill`. Before this fix the
/// `predictedSubcategory` branch ran first, which silently shadowed the
/// raw-class rescue any time the model's downstream prediction landed on
/// the category default (`.hat` for accessories, `.boots` for shoes).
///
/// The contract these tests pin:
///
///   1. For `.accessory`: rescue map (e.g. `belt → .belt`) wins over a
///      stale `predictedSubcategory` even when the prediction's category
///      matches.
///   2. For `.shoe`: rescue map (`boot → .boots`, `sandal → .sandals`)
///      wins over a stale prediction; raw `shoe` falls through to the
///      `.sneakers` default.
///   3. Other categories (top/bottom/dress/outerwear) are untouched —
///      the rescue branch never fires for them, so the existing
///      `predictedSubcategory` happy path stays intact.
///
/// `@Suite(.serialized)` because every test flips
/// `FeatureFlags.isAttributeDetectionEnabled` ON. Cross-suite isolation
/// goes through `FeatureFlagTestIsolation`. Mirrors the setup in
/// `AddItemViewModelPrefillTests`.
@MainActor
@Suite(.serialized)
struct AddItemViewModelAccessoryRescueTests {

    // MARK: - Setup helper

    private struct FlagContext {
        let finalize: () -> Void
    }

    private func enableAttributeDetection() async -> FlagContext {
        await FeatureFlagTestIsolation.shared.acquire()
        FeatureFlags.resetAll()
        FeatureFlags.isAttributeDetectionEnabled = true
        return FlagContext {
            FeatureFlags.resetAll()
            Task { await FeatureFlagTestIsolation.shared.release() }
        }
    }

    // MARK: - Accessory rescue beats predictedSubcategory

    /// Build 4 dogfood failure: a `glasses` detection arrived with
    /// `predictedSubcategory: .hat` (the accessory default), and the
    /// pre-Build-5 ordering took the prediction without checking the
    /// raw class. After the fix, rescue runs first and wins.
    @Test func accessoryRescueFiresEvenWhenPredictedSubcategoryIsHatForGlasses() async {
        let flag = await enableAttributeDetection()
        defer { flag.finalize() }

        let vm = AddItemViewModel()
        let proposal = MaskProposalFixture.make(
            predictedCategory: .accessory,
            predictedCategoryConfidence: 0.95,
            predictedSubcategory: .hat,
            modelClassRaw: "glasses"
        )
        vm.proposals = [proposal]
        vm.selectedProposalIDs = [proposal.id]

        await vm.onMultiPickConfirmed()

        #expect(vm.subcategory == .sunglasses,
                "raw 'glasses' must override the stale predictedSubcategory: .hat")
        #expect(vm.detectedAttributes["subcategory"] == ClothingSubcategory.sunglasses.rawValue)
    }

    @Test func accessoryRescueFiresEvenWhenPredictedSubcategoryIsHatForBelt() async {
        let flag = await enableAttributeDetection()
        defer { flag.finalize() }

        let vm = AddItemViewModel()
        let proposal = MaskProposalFixture.make(
            predictedCategory: .accessory,
            predictedCategoryConfidence: 0.95,
            predictedSubcategory: .hat,
            modelClassRaw: "belt"
        )
        vm.proposals = [proposal]
        vm.selectedProposalIDs = [proposal.id]

        await vm.onMultiPickConfirmed()

        #expect(vm.subcategory == .belt,
                "raw 'belt' must override the stale predictedSubcategory: .hat")
        #expect(vm.detectedAttributes["subcategory"] == ClothingSubcategory.belt.rawValue)
    }

    /// When the rescue map has no opinion (raw class outside the trained
    /// accessory vocabulary), fall through to the predictedSubcategory
    /// when its category matches. Captures the rescue's "additive only"
    /// nature: the second branch still works.
    @Test func accessoryRescueFallsThroughToPredictedSubcategoryWhenRescueReturnsNil() async {
        let flag = await enableAttributeDetection()
        defer { flag.finalize() }

        let vm = AddItemViewModel()
        let proposal = MaskProposalFixture.make(
            predictedCategory: .accessory,
            predictedCategoryConfidence: 0.95,
            predictedSubcategory: .hat,
            modelClassRaw: "umbrella"  // no rescue mapping
        )
        vm.proposals = [proposal]
        vm.selectedProposalIDs = [proposal.id]

        await vm.onMultiPickConfirmed()

        #expect(vm.subcategory == .hat,
                "no rescue → fall through to predictedSubcategory: .hat")
        #expect(vm.detectedAttributes["subcategory"] == ClothingSubcategory.hat.rawValue)
    }

    /// And when neither rescue nor predictedSubcategory has an opinion,
    /// the category default (`.hat`) lands on the picker.
    @Test func accessoryRescueFallsThroughToCategoryDefaultWhenAllElseFails() async {
        let flag = await enableAttributeDetection()
        defer { flag.finalize() }

        let vm = AddItemViewModel()
        let proposal = MaskProposalFixture.make(
            predictedCategory: .accessory,
            predictedCategoryConfidence: 0.95,
            predictedSubcategory: nil,
            modelClassRaw: "umbrella"
        )
        vm.proposals = [proposal]
        vm.selectedProposalIDs = [proposal.id]

        await vm.onMultiPickConfirmed()

        #expect(vm.subcategory == .hat, "rescue + predicted both nil → .hat default")
        #expect(vm.detectedAttributes["subcategory"] == nil,
                "category-default landings are not recorded as ML-driven")
    }

    // MARK: - Shoe rescue contract

    /// Build 4 dogfood failure: a `shoe` detection commonly arrived
    /// with `predictedSubcategory: .boots` (the model's class-id bias),
    /// silently mis-prefilling sneakers as boots. After the fix:
    /// `boot` raw → `.boots` (correct), but a generic `shoe` raw lets
    /// the `.sneakers` default fire instead of trusting the stale
    /// prediction.
    @Test func shoeRescueFiresForBootEvenWhenPredictedSubcategoryDisagrees() async {
        let flag = await enableAttributeDetection()
        defer { flag.finalize() }

        let vm = AddItemViewModel()
        let proposal = MaskProposalFixture.make(
            predictedCategory: .shoe,
            predictedCategoryConfidence: 0.95,
            predictedSubcategory: .sneakers,  // stale — model said sneakers but raw said boot
            modelClassRaw: "boot"
        )
        vm.proposals = [proposal]
        vm.selectedProposalIDs = [proposal.id]

        await vm.onMultiPickConfirmed()

        #expect(vm.subcategory == .boots,
                "raw 'boot' must override stale predictedSubcategory: .sneakers")
        #expect(vm.detectedAttributes["subcategory"] == ClothingSubcategory.boots.rawValue)
    }

    @Test func shoeRescueFiresForSandalEvenWhenPredictedSubcategoryIsBoots() async {
        let flag = await enableAttributeDetection()
        defer { flag.finalize() }

        let vm = AddItemViewModel()
        let proposal = MaskProposalFixture.make(
            predictedCategory: .shoe,
            predictedCategoryConfidence: 0.95,
            predictedSubcategory: .boots,
            modelClassRaw: "sandal"
        )
        vm.proposals = [proposal]
        vm.selectedProposalIDs = [proposal.id]

        await vm.onMultiPickConfirmed()

        #expect(vm.subcategory == .sandals,
                "raw 'sandal' must override stale predictedSubcategory: .boots")
        #expect(vm.detectedAttributes["subcategory"] == ClothingSubcategory.sandals.rawValue)
    }

    /// Generic `shoe` — Fashionpedia can't tell sneakers/loafers/heels
    /// apart at the category level. Rescue returns nil for this raw,
    /// and we want `.sneakers` (default) to land on the picker rather
    /// than a stale prediction.
    @Test func shoeRescueLetsDefaultFireForGenericShoe() async {
        let flag = await enableAttributeDetection()
        defer { flag.finalize() }

        let vm = AddItemViewModel()
        let proposal = MaskProposalFixture.make(
            predictedCategory: .shoe,
            predictedCategoryConfidence: 0.95,
            predictedSubcategory: nil,
            modelClassRaw: "shoe"
        )
        vm.proposals = [proposal]
        vm.selectedProposalIDs = [proposal.id]

        await vm.onMultiPickConfirmed()

        #expect(vm.subcategory == .sneakers,
                "raw 'shoe' is too generic — fall through to .sneakers default")
        #expect(vm.detectedAttributes["subcategory"] == nil,
                "rescue-nil + default landings are not recorded as ML-driven")
    }

    /// Rescue + predictedSubcategory both nil for an unrecognised raw
    /// class → category default (`.sneakers`). Pins the third branch.
    @Test func shoeRescueFallsThroughToDefaultForUnknownRawClass() async {
        let flag = await enableAttributeDetection()
        defer { flag.finalize() }

        let vm = AddItemViewModel()
        let proposal = MaskProposalFixture.make(
            predictedCategory: .shoe,
            predictedCategoryConfidence: 0.95,
            predictedSubcategory: nil,
            modelClassRaw: "futureFootwear"
        )
        vm.proposals = [proposal]
        vm.selectedProposalIDs = [proposal.id]

        await vm.onMultiPickConfirmed()

        #expect(vm.subcategory == .sneakers)
        #expect(vm.detectedAttributes["subcategory"] == nil)
    }

    // MARK: - Non-accessory / non-shoe regression

    /// Regression check: the inverted rescue branch must not fire for
    /// `.top`. The standard predictedSubcategory path keeps working
    /// for tops, bottoms, dresses, outerwear.
    @Test func topCategoryUnchangedByRescueLogic() async {
        let flag = await enableAttributeDetection()
        defer { flag.finalize() }

        let vm = AddItemViewModel()
        let proposal = MaskProposalFixture.make(
            predictedCategory: .top,
            predictedCategoryConfidence: 0.95,
            predictedSubcategory: .tshirt,
            modelClassRaw: "top_t-shirt_sweatshirt"
        )
        vm.proposals = [proposal]
        vm.selectedProposalIDs = [proposal.id]

        await vm.onMultiPickConfirmed()

        #expect(vm.category == .top)
        #expect(vm.subcategory == .tshirt,
                "predictedSubcategory branch must remain authoritative for non-rescue categories")
        #expect(vm.detectedAttributes["subcategory"] == ClothingSubcategory.tshirt.rawValue)
    }

    @Test func outerwearCategoryUnchangedByRescueLogic() async {
        let flag = await enableAttributeDetection()
        defer { flag.finalize() }

        let vm = AddItemViewModel()
        let proposal = MaskProposalFixture.make(
            predictedCategory: .outerwear,
            predictedCategoryConfidence: 0.95,
            predictedSubcategory: .leatherJacket,
            modelClassRaw: "jacket"
        )
        vm.proposals = [proposal]
        vm.selectedProposalIDs = [proposal.id]

        await vm.onMultiPickConfirmed()

        #expect(vm.category == .outerwear)
        #expect(vm.subcategory == .leatherJacket,
                "outerwear retains the original predictedSubcategory-first ordering")
    }
}
