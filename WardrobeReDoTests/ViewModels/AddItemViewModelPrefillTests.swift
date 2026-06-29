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
/// `@Suite(.serialized)` because every test flips
/// `FeatureFlags.isAttributeDetectionEnabled` to on (Phase 8 gate).
/// Cross-suite isolation is enforced via `FeatureFlagTestIsolation` —
/// without it, other suites mutating the same flag could race our
/// setup.
///
/// See [docs/plans/2026-04-19-auto-attribute-detection.md](../../docs/plans/2026-04-19-auto-attribute-detection.md)
/// Phase 0 + Phase 8 for the full spec.
@MainActor
@Suite(.serialized)
struct AddItemViewModelPrefillTests {

    // MARK: - Setup helper
    //
    // Every test needs the feature flag ON (Phase 8 gates pre-fill on it).
    // Wrapping the acquire/reset/set/flag-release in a helper keeps each
    // test readable. Returns a token whose `defer { finalize() }` closure
    // unwinds the setup in reverse order.

    private struct FlagContext {
        let finalize: () -> Void
    }

    private func enableAttributeDetection() async -> FlagContext {
        await FeatureFlagTestIsolation.shared.acquire()
        FeatureFlags.resetAll()
        FeatureFlags.isAttributeDetectionEnabled = true
        // Build 52 — this suite validates the TF47 strict, confidence-gated
        // prefill path. Fast Add (default on) best-guesses regardless of
        // confidence and is covered by its own tests; pin it OFF here so
        // these threshold assertions keep testing what they're named for.
        FeatureFlags.isFastAddEnabled = false
        return FlagContext {
            FeatureFlags.resetAll()
            Task { await FeatureFlagTestIsolation.shared.release() }
        }
    }

    // MARK: - Category threshold

    @Test func addItemPrefillsCategoryWhenConfidenceAboveThreshold() async {
        let flag = await enableAttributeDetection()
        defer { flag.finalize() }

        let vm = AddItemViewModel()
        let proposal = MaskProposalFixture.make(
            predictedCategory: .outerwear,
            predictedCategoryConfidence: 0.95
        )
        vm.proposals = [proposal]
        vm.selectedProposalIDs = [proposal.id]

        await vm.onMultiPickConfirmed()

        #expect(vm.category == .outerwear)
        #expect(vm.detectedAttributes["category"] == ClothingCategory.outerwear.rawValue)
    }

    @Test func addItemSkipsCategoryPrefillWhenBelowThreshold() async {
        let flag = await enableAttributeDetection()
        defer { flag.finalize() }

        let vm = AddItemViewModel()
        let proposal = MaskProposalFixture.make(
            predictedCategory: .outerwear,
            predictedCategoryConfidence: 0.50
        )
        vm.proposals = [proposal]
        vm.selectedProposalIDs = [proposal.id]

        await vm.onMultiPickConfirmed()

        #expect(vm.category == .top, "sub-threshold prediction should fall back to the default .top")
        #expect(vm.detectedAttributes["category"] == nil, "snapshot should omit fields that weren't pre-filled")
    }

    @Test func addItemSkipsCategoryPrefillWhenPredictionMissing() async {
        let flag = await enableAttributeDetection()
        defer { flag.finalize() }

        let vm = AddItemViewModel()
        let proposal = MaskProposalFixture.make(
            predictedCategory: nil,
            predictedCategoryConfidence: 0.0
        )
        vm.proposals = [proposal]
        vm.selectedProposalIDs = [proposal.id]

        await vm.onMultiPickConfirmed()

        #expect(vm.category == .top)
        #expect(vm.detectedAttributes["category"] == nil)
    }

    // MARK: - Subcategory

    @Test func addItemUsesPredictedSubcategoryWhenCategoryMatches() async {
        let flag = await enableAttributeDetection()
        defer { flag.finalize() }

        let vm = AddItemViewModel()
        let proposal = MaskProposalFixture.make(
            predictedCategory: .top,
            predictedCategoryConfidence: 0.95,
            predictedSubcategory: .buttonDown
        )
        vm.proposals = [proposal]
        vm.selectedProposalIDs = [proposal.id]

        await vm.onMultiPickConfirmed()

        #expect(vm.subcategory == .buttonDown)
        #expect(vm.detectedAttributes["subcategory"] == ClothingSubcategory.buttonDown.rawValue)
    }

    @Test func addItemDropsSubcategoryWhenCategoryMismatch() async {
        // Predicted subcategory .sneakers belongs to .shoe, but the category
        // prediction falls below the threshold so the final category stays
        // .top. The subcategory can't dangle on .top's picker, so the guard
        // should drop the prediction and fall back to the .top default.
        let flag = await enableAttributeDetection()
        defer { flag.finalize() }

        let vm = AddItemViewModel()
        let proposal = MaskProposalFixture.make(
            predictedCategory: .shoe,
            predictedCategoryConfidence: 0.50, // below threshold, category stays .top
            predictedSubcategory: .sneakers
        )
        vm.proposals = [proposal]
        vm.selectedProposalIDs = [proposal.id]

        await vm.onMultiPickConfirmed()

        #expect(vm.category == .top)
        #expect(vm.subcategory == .tshirt, "mismatched subcategory should fall back to category default")
        #expect(vm.detectedAttributes["subcategory"] == nil)
    }

    // MARK: - Accessory raw-class rescue (A3)
    //
    // When a proposal lands as `.accessory` but the standard
    // `predictedSubcategory` path returns nil, the rescue mapping
    // (`ClothingSubcategory.accessorySubcategoryFromRawClass`) should
    // pick the right subcategory from the raw Fashionpedia label
    // instead of silently defaulting to `.hat`.

    @Test func addItemRescuesAccessorySubcategoryFromRawBelt() async {
        let flag = await enableAttributeDetection()
        defer { flag.finalize() }

        let vm = AddItemViewModel()
        let proposal = MaskProposalFixture.make(
            predictedCategory: .accessory,
            predictedCategoryConfidence: 0.95,
            predictedSubcategory: nil,
            modelClassRaw: "belt"
        )
        vm.proposals = [proposal]
        vm.selectedProposalIDs = [proposal.id]

        await vm.onMultiPickConfirmed()

        #expect(vm.subcategory == .belt,
               "raw 'belt' must rescue to .belt rather than fall to .hat")
        #expect(vm.detectedAttributes["subcategory"] == ClothingSubcategory.belt.rawValue)
    }

    @Test func addItemRescuesAccessorySubcategoryFromRawGlasses() async {
        let flag = await enableAttributeDetection()
        defer { flag.finalize() }

        let vm = AddItemViewModel()
        let proposal = MaskProposalFixture.make(
            predictedCategory: .accessory,
            predictedCategoryConfidence: 0.95,
            predictedSubcategory: nil,
            modelClassRaw: "glasses"
        )
        vm.proposals = [proposal]
        vm.selectedProposalIDs = [proposal.id]

        await vm.onMultiPickConfirmed()

        #expect(vm.subcategory == .sunglasses,
               "raw 'glasses' must rescue to .sunglasses rather than fall to .hat")
        #expect(vm.detectedAttributes["subcategory"] == ClothingSubcategory.sunglasses.rawValue)
    }

    @Test func addItemRescuesAccessorySubcategoryFromRawWatch() async {
        let flag = await enableAttributeDetection()
        defer { flag.finalize() }

        let vm = AddItemViewModel()
        let proposal = MaskProposalFixture.make(
            predictedCategory: .accessory,
            predictedCategoryConfidence: 0.95,
            predictedSubcategory: nil,
            modelClassRaw: "watch"
        )
        vm.proposals = [proposal]
        vm.selectedProposalIDs = [proposal.id]

        await vm.onMultiPickConfirmed()

        #expect(vm.subcategory == .watch,
               "raw 'watch' must rescue to .watch rather than fall to .hat")
        #expect(vm.detectedAttributes["subcategory"] == ClothingSubcategory.watch.rawValue)
    }

    @Test func addItemAccessoryFallsBackToDefaultWhenRawUnknown() async {
        // Raw class outside the rescue map → fall through to the
        // category default (.hat for .accessory). The rescue path is
        // strictly additive — it doesn't change behavior when no
        // mapping is available.
        let flag = await enableAttributeDetection()
        defer { flag.finalize() }

        let vm = AddItemViewModel()
        let proposal = MaskProposalFixture.make(
            predictedCategory: .accessory,
            predictedCategoryConfidence: 0.95,
            predictedSubcategory: nil,
            modelClassRaw: "unknownThing"
        )
        vm.proposals = [proposal]
        vm.selectedProposalIDs = [proposal.id]

        await vm.onMultiPickConfirmed()

        #expect(vm.subcategory == .hat,
               "unknown raw classes still fall to the .accessory default — no regression")
        #expect(vm.detectedAttributes["subcategory"] == nil,
               "rescue miss must not record a snapshot entry")
    }

    @Test func addItemPrefillRespectsExistingSubcategoryPath() async {
        // Regression check: when `predictedSubcategory` IS populated
        // and matches the category, the standard path wins — the
        // accessory rescue never runs for non-accessory categories.
        // Mirrors the typical happy-path flow for .top + shirt_blouse.
        let flag = await enableAttributeDetection()
        defer { flag.finalize() }

        let vm = AddItemViewModel()
        let proposal = MaskProposalFixture.make(
            predictedCategory: .top,
            predictedCategoryConfidence: 0.95,
            predictedSubcategory: .buttonDown,
            modelClassRaw: "shirt_blouse"
        )
        vm.proposals = [proposal]
        vm.selectedProposalIDs = [proposal.id]

        await vm.onMultiPickConfirmed()

        #expect(vm.category == .top)
        #expect(vm.subcategory == .buttonDown,
               "existing predictedSubcategory path must continue to win")
        #expect(vm.detectedAttributes["subcategory"] == ClothingSubcategory.buttonDown.rawValue)
    }

    // MARK: - Texture threshold

    @Test func addItemPrefillsTextureWhenConfidenceAboveThreshold() async {
        let flag = await enableAttributeDetection()
        defer { flag.finalize() }

        let vm = AddItemViewModel()
        let proposal = MaskProposalFixture.make(
            predictedTexture: .leather,
            // Build 47 — bar raised to 0.90; "above threshold" fixture
            // bumped to 0.95 to stay above it.
            predictedTextureConfidence: 0.95
        )
        vm.proposals = [proposal]
        vm.selectedProposalIDs = [proposal.id]

        await vm.onMultiPickConfirmed()

        #expect(vm.texture == .leather)
        #expect(vm.detectedAttributes["texture"] == TextureType.leather.rawValue)
    }

    @Test func addItemSkipsTexturePrefillWhenBelowThreshold() async {
        let flag = await enableAttributeDetection()
        defer { flag.finalize() }

        let vm = AddItemViewModel()
        let proposal = MaskProposalFixture.make(
            predictedTexture: .silk,
            predictedTextureConfidence: 0.70
        )
        vm.proposals = [proposal]
        vm.selectedProposalIDs = [proposal.id]

        await vm.onMultiPickConfirmed()

        #expect(vm.texture == nil)
        #expect(vm.detectedAttributes["texture"] == nil)
    }

    // MARK: - Fit threshold

    @Test func addItemPrefillsFitWhenConfidenceAboveThreshold() async {
        let flag = await enableAttributeDetection()
        defer { flag.finalize() }

        let vm = AddItemViewModel()
        let proposal = MaskProposalFixture.make(
            predictedFit: .oversized,
            predictedFitConfidence: 0.90
        )
        vm.proposals = [proposal]
        vm.selectedProposalIDs = [proposal.id]

        await vm.onMultiPickConfirmed()

        #expect(vm.fitAttribute == .oversized)
        #expect(vm.detectedAttributes["fit"] == FitAttribute.oversized.rawValue)
    }

    // MARK: - Seasons fallback

    @Test func addItemFallsBackToAllSeasonsWhenPredictedSeasonsEmpty() async {
        let flag = await enableAttributeDetection()
        defer { flag.finalize() }

        let vm = AddItemViewModel()
        let proposal = MaskProposalFixture.make(
            predictedSeasons: []
        )
        vm.proposals = [proposal]
        vm.selectedProposalIDs = [proposal.id]

        await vm.onMultiPickConfirmed()

        #expect(vm.selectedSeasons == Set(Season.allCases),
               "empty predictions must fall back to all-seasons, never leave the picker empty")
        #expect(vm.detectedAttributes["seasons"] == nil, "fallback values aren't recorded as ML-driven")
    }

    @Test func addItemUsesPredictedSeasonsWhenProvided() async {
        let flag = await enableAttributeDetection()
        defer { flag.finalize() }

        let vm = AddItemViewModel()
        let proposal = MaskProposalFixture.make(
            predictedSeasons: [.fall, .winter]
        )
        vm.proposals = [proposal]
        vm.selectedProposalIDs = [proposal.id]

        await vm.onMultiPickConfirmed()

        #expect(vm.selectedSeasons == Set([Season.fall, Season.winter]))
        #expect(vm.detectedAttributes["seasons"] == "fall,winter",
               "snapshot joins season rawValues in sorted order")
    }

    // MARK: - Occasions fallback

    @Test func addItemFallsBackToCasualWhenPredictedOccasionsEmpty() async {
        let flag = await enableAttributeDetection()
        defer { flag.finalize() }

        let vm = AddItemViewModel()
        let proposal = MaskProposalFixture.make(
            predictedOccasions: []
        )
        vm.proposals = [proposal]
        vm.selectedProposalIDs = [proposal.id]

        await vm.onMultiPickConfirmed()

        #expect(vm.selectedOccasions == [.casual],
               "empty predictions must fall back to [.casual], never leave the picker empty")
        #expect(vm.detectedAttributes["occasions"] == nil)
    }

    @Test func addItemUsesPredictedOccasionsWhenProvided() async {
        let flag = await enableAttributeDetection()
        defer { flag.finalize() }

        let vm = AddItemViewModel()
        let proposal = MaskProposalFixture.make(
            predictedOccasions: [.work, .formal]
        )
        vm.proposals = [proposal]
        vm.selectedProposalIDs = [proposal.id]

        await vm.onMultiPickConfirmed()

        #expect(vm.selectedOccasions == Set([Occasion.work, Occasion.formal]))
        #expect(vm.detectedAttributes["occasions"] == "formal,work",
               "snapshot joins occasion rawValues in sorted order")
    }

    // MARK: - Snapshot lifecycle

    @Test func addItemRecordsFullDetectedAttributesSnapshot() async {
        let flag = await enableAttributeDetection()
        defer { flag.finalize() }

        let vm = AddItemViewModel()
        let proposal = MaskProposalFixture.make(
            predictedCategory: .outerwear,
            predictedCategoryConfidence: 0.95,
            predictedSubcategory: .leatherJacket,
            predictedTexture: .leather,
            predictedTextureConfidence: 0.90,
            predictedFit: .oversized,
            // Build 47 — bar raised to 0.90; full-snapshot fixture bumped
            // so the fit field clears it (test asserts fit is recorded).
            predictedFitConfidence: 0.95,
            predictedSeasons: [.fall, .winter],
            predictedOccasions: [.casual, .date]
        )
        vm.proposals = [proposal]
        vm.selectedProposalIDs = [proposal.id]

        await vm.onMultiPickConfirmed()

        #expect(vm.detectedAttributes["category"] == "outerwear")
        #expect(vm.detectedAttributes["subcategory"] == "leatherJacket")
        #expect(vm.detectedAttributes["texture"] == "leather")
        #expect(vm.detectedAttributes["fit"] == "oversized")
        #expect(vm.detectedAttributes["seasons"] == "fall,winter")
        #expect(vm.detectedAttributes["occasions"] == "casual,date")
    }

    @Test func addItemResetClearsDetectedAttributes() {
        let vm = AddItemViewModel()
        vm.detectedAttributes = ["category": "outerwear", "texture": "leather"]

        vm.reset()

        #expect(vm.detectedAttributes.isEmpty)
    }

    // MARK: - Phase 8: feature-flag gate

    @Test func addItemSkipsPrefillWhenFeatureFlagDisabled() async {
        // Flag OFF should bypass every ML prediction and fall back to
        // the legacy hard-reset pickers, even when the proposal carries
        // confidence-cleared predictions.
        await FeatureFlagTestIsolation.shared.acquire()
        defer { Task { await FeatureFlagTestIsolation.shared.release() } }
        FeatureFlags.resetAll()
        FeatureFlags.isAttributeDetectionEnabled = false
        defer { FeatureFlags.resetAll() }

        let vm = AddItemViewModel()
        let proposal = MaskProposalFixture.make(
            predictedCategory: .outerwear,
            predictedCategoryConfidence: 0.95,
            predictedTexture: .leather,
            predictedTextureConfidence: 0.95,
            predictedFit: .oversized,
            predictedFitConfidence: 0.95,
            predictedSeasons: [.fall, .winter],
            predictedOccasions: [.work]
        )
        vm.proposals = [proposal]
        vm.selectedProposalIDs = [proposal.id]

        await vm.onMultiPickConfirmed()

        #expect(vm.category == .top, "flag off → legacy hard-reset category")
        #expect(vm.subcategory == .tshirt)
        #expect(vm.texture == nil)
        #expect(vm.fitAttribute == nil)
        #expect(vm.selectedSeasons == Set(Season.allCases))
        #expect(vm.selectedOccasions == [.casual])
        #expect(vm.detectedAttributes.isEmpty,
               "no snapshot recorded when the flag short-circuits pre-fill")
    }
}
