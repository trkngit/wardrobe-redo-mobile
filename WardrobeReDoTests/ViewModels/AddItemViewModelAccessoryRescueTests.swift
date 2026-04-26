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
    /// the bbox heuristic kicks in (Build 6). Default fixture bbox is
    /// large (height 0.5), so isThin=false, heuristic falls through
    /// to `.hat` — same observable result as the legacy default.
    @Test func accessoryRescueFallsThroughToBboxHeuristicWhenAllElseFails() async {
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

        #expect(vm.subcategory == .hat, "rescue + predicted both nil + non-thin bbox → .hat default")
        #expect(vm.detectedAttributes["subcategory"] == nil,
                "heuristic-derived subcategories are not recorded as ML-driven")
    }

    // MARK: - Bbox heuristic for unmapped accessory classes (Build 6)

    /// Build-5 dogfood: the model emits `headband` for actual
    /// sunglasses. Both rescue and `predictedSubcategory` punt to nil,
    /// so the form pre-filled `.hat` (the legacy default). Build 6's
    /// heuristic uses the bbox position — face-area + thin → infer
    /// `.sunglasses`.
    @Test func accessoryBboxHeuristicInfersSunglassesFromFaceBbox() async {
        let flag = await enableAttributeDetection()
        defer { flag.finalize() }

        let vm = AddItemViewModel()
        let proposal = MaskProposalFixture.make(
            predictedCategory: .accessory,
            predictedCategoryConfidence: 0.95,
            predictedSubcategory: nil,
            // Realistic sunglasses bbox: across the face, thin strip.
            // y-mid 0.30 < 0.40, height 0.06 < 0.10.
            boundingBox: CGRect(x: 0.30, y: 0.27, width: 0.40, height: 0.06),
            modelClassRaw: "headband"  // model misclassification
        )
        vm.proposals = [proposal]
        vm.selectedProposalIDs = [proposal.id]

        await vm.onMultiPickConfirmed()

        #expect(vm.subcategory == .sunglasses,
                "face-area + thin bbox → sunglasses (overrides .hat default)")
    }

    /// Build-5 dogfood: model emits `headband` (or another unmapped
    /// accessory class) for an actual belt. Bbox is at the waist with
    /// a thin horizontal stripe → infer `.belt`.
    @Test func accessoryBboxHeuristicInfersBeltFromWaistBbox() async {
        let flag = await enableAttributeDetection()
        defer { flag.finalize() }

        let vm = AddItemViewModel()
        let proposal = MaskProposalFixture.make(
            predictedCategory: .accessory,
            predictedCategoryConfidence: 0.95,
            predictedSubcategory: nil,
            // Realistic belt bbox: across the waistband, thin stripe.
            // y-mid ≈ 0.53 in [0.42, 0.62], height 0.04 < 0.10.
            boundingBox: CGRect(x: 0.30, y: 0.51, width: 0.40, height: 0.04),
            modelClassRaw: "tie"  // model misclassification
        )
        vm.proposals = [proposal]
        vm.selectedProposalIDs = [proposal.id]

        await vm.onMultiPickConfirmed()

        #expect(vm.subcategory == .belt,
                "waist-area + thin bbox → belt (overrides .hat default)")
    }

    /// Bbox heuristic falls through to `.hat` when neither face nor
    /// waist criteria match. Covers the original default behavior.
    @Test func accessoryBboxHeuristicFallsBackToHatForOtherPositions() async {
        let flag = await enableAttributeDetection()
        defer { flag.finalize() }

        let vm = AddItemViewModel()
        let proposal = MaskProposalFixture.make(
            predictedCategory: .accessory,
            predictedCategoryConfidence: 0.95,
            predictedSubcategory: nil,
            // Bbox spans most of the frame — neither face nor waist
            // criteria fire (height 0.5 > 0.10 makes isThin false).
            boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5),
            modelClassRaw: "ring"  // unmapped accessory
        )
        vm.proposals = [proposal]
        vm.selectedProposalIDs = [proposal.id]

        await vm.onMultiPickConfirmed()

        #expect(vm.subcategory == .hat, "non-thin bbox → .hat fallback")
    }

    /// Bbox heuristic also applied when bbox is thin but in the high
    /// region (above the face) — falls back to `.hat` (covers
    /// caps/headbands/etc.).
    @Test func accessoryBboxHeuristicHighThinBboxStillHat() async {
        let flag = await enableAttributeDetection()
        defer { flag.finalize() }

        let vm = AddItemViewModel()
        let proposal = MaskProposalFixture.make(
            predictedCategory: .accessory,
            predictedCategoryConfidence: 0.95,
            predictedSubcategory: nil,
            // Above eye level (y-mid 0.20). Thin (height 0.06).
            // y-mid 0.20 < 0.40 ✓ AND isThin ✓ → falls into sunglasses
            // branch by current spec. This test pins that behavior; if
            // future tuning carves out a "headwear above eyes" class
            // (cap/beanie), update this case.
            boundingBox: CGRect(x: 0.30, y: 0.17, width: 0.40, height: 0.06),
            modelClassRaw: "headband"
        )
        vm.proposals = [proposal]
        vm.selectedProposalIDs = [proposal.id]

        await vm.onMultiPickConfirmed()

        #expect(vm.subcategory == .sunglasses,
                "high + thin currently lumps with sunglasses; revisit if dogfood shows hat-confusion")
    }

    // MARK: - Shoe rescue contract

    /// **Build 6 user-favoring default.** Build-5 dogfood confirmed
    /// the model's `boot` class-id fires for actual sneakers more often
    /// than for actual boots, so trusting `boot` was net-negative for
    /// users. PR #31 flips `shoeSubcategoryFromRawClass("boot")` to
    /// return nil, letting the `.sneakers` default fire instead.
    /// Real boots get mistagged as sneakers — same trade-off PR #25
    /// made for texture (`.bottom → .denim`). The user can correct
    /// the rare boot case manually.
    @Test func shoeBootRawClassNowDefaultsToSneakersForUserFavoringFix() async {
        let flag = await enableAttributeDetection()
        defer { flag.finalize() }

        let vm = AddItemViewModel()
        let proposal = MaskProposalFixture.make(
            predictedCategory: .shoe,
            predictedCategoryConfidence: 0.95,
            predictedSubcategory: nil,  // model didn't pin a subcategory
            modelClassRaw: "boot"
        )
        vm.proposals = [proposal]
        vm.selectedProposalIDs = [proposal.id]

        await vm.onMultiPickConfirmed()

        #expect(vm.subcategory == .sneakers,
                "Build 6: raw 'boot' lets .sneakers default fire (user-favoring trade-off)")
        // Category-default landings are not recorded as ML-driven.
        #expect(vm.detectedAttributes["subcategory"] == nil)
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
