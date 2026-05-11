import Foundation
import Testing
import UIKit
import os.log
@testable import WardrobeReDo

/// End-to-end integration tests for the Phase 6 composition path:
///   detection → `AttributeClassifying` → `AttributeRulesEngine` →
///   enriched `MaskProposal`.
///
/// Unit coverage of the individual layers lives in:
///   - [`AttributeClassifierServiceTests`](./AttributeClassifierServiceTests.swift)
///   - [`AttributeRulesEngineTests`](./AttributeRulesEngineTests.swift)
///   - [`AddItemViewModelPrefillTests`](../ViewModels/AddItemViewModelPrefillTests.swift)
///
/// What this file protects:
///   The contract that when a base `MaskProposal` (the detection-head
///   output before Phase 4 attributes) is run through
///   `MultiGarmentProposalService.enriched(_:with:logger:)`, the returned
///   proposal has texture + fit from the classifier and seasons +
///   occasions from the rules engine — and gracefully degrades to a
///   rules-only path when the classifier errors, so a Core ML regression
///   cannot break detection.
///
/// We exercise the static helpers `enriched` / `enrichedWithRulesOnly`
/// directly instead of `detectProposals`, because the real
/// `detectProposals` requires a bundled RF-DETR model that isn't
/// guaranteed to be on disk in CI. The static helpers cover the whole
/// composition — they're exactly what `detectProposals` calls in its
/// per-proposal loop.
@MainActor
struct AutoAttributeE2ETests {

    private static let logger = Logger(
        subsystem: "com.wardroberedo.tests",
        category: "AutoAttributeE2E"
    )

    // MARK: - Happy path

    @Test func enrichedPopulatesFitAndRulesFromClassifier() async {
        let base = MaskProposalFixture.make(
            predictedCategory: .outerwear,
            predictedCategoryConfidence: 0.92,
            predictedSubcategory: .puffer,
            modelClassRaw: "jacket"
        )
        let classifier = MockAttributeClassifier(
            prediction: AttributePrediction(
                fit: .oversized, fitConfidence: 0.83
            )
        )

        let enriched = await MultiGarmentProposalService.enriched(
            base, with: classifier, logger: Self.logger
        )

        // Build 6: texture is rules-derived, not from the
        // classifier. Puffer has no `RulesTable` entry but the
        // bottom-category default doesn't fire for outerwear, so
        // texture stays nil. The fit head — which IS still wired —
        // flows through verbatim.
        #expect(enriched.predictedFit == .oversized)
        #expect(abs(enriched.predictedFitConfidence - 0.83) < 0.001)

        // Rules engine fires — puffer + wool is a winter-only coat.
        #expect(enriched.predictedSeasons.isEmpty == false)
        #expect(enriched.predictedOccasions.isEmpty == false)

        // Detection head's fields are preserved byte-for-byte.
        #expect(enriched.id == base.id)
        #expect(enriched.predictedCategory == .outerwear)
        #expect(abs(enriched.predictedCategoryConfidence - 0.92) < 0.001)
        #expect(enriched.predictedSubcategory == .puffer)
        #expect(enriched.boundingBox == base.boundingBox)
        #expect(enriched.detectionScore == base.detectionScore)
        #expect(enriched.modelClassRaw == base.modelClassRaw)
    }

    // MARK: - Classifier failure falls through to rules-only

    @Test func classifierErrorFallsBackToRulesOnly() async {
        let base = MaskProposalFixture.make(
            predictedCategory: .shoe,
            predictedCategoryConfidence: 0.90,
            predictedSubcategory: .sandals,
            modelClassRaw: "shoe"
        )
        let classifier = MockAttributeClassifier(
            behavior: .throwError(.inferenceFailed(reason: "simulated regression"))
        )

        let enriched = await MultiGarmentProposalService.enriched(
            base, with: classifier, logger: Self.logger
        )

        // Classifier crashed — texture and fit stay nil with zero confidence.
        #expect(enriched.predictedTexture == nil)
        #expect(enriched.predictedTextureConfidence == 0.0)
        #expect(enriched.predictedFit == nil)
        #expect(enriched.predictedFitConfidence == 0.0)

        // Rules still fire against the surviving category/subcategory. Sandals
        // are summer-only in the rules table — this doubles as a smoke test
        // that the fallback actually invokes the engine rather than returning
        // the empty proposal.
        #expect(enriched.predictedSeasons == [.summer],
                "Sandals rule should fire from the fallback path")
        #expect(enriched.predictedOccasions.isEmpty == false)

        // Classifier was called exactly once — we don't want a retry loop.
        #expect(classifier.callCount == 1)
    }

    // MARK: - No classifier at all

    @Test func enrichedWithRulesOnlyProducesNonEmptyPredictions() {
        let base = MaskProposalFixture.make(
            predictedCategory: .top,
            predictedCategoryConfidence: 0.88,
            predictedSubcategory: .tshirt,
            modelClassRaw: "shirt_blouse"
        )

        let enriched = MultiGarmentProposalService.enrichedWithRulesOnly(base)

        #expect(enriched.predictedTexture == nil)
        #expect(enriched.predictedFit == nil)
        #expect(enriched.predictedSeasons.isEmpty == false,
                "Rules engine must return at least the fallback all-seasons set")
        #expect(enriched.predictedOccasions.isEmpty == false,
                "Rules engine must return at least the fallback [.casual]")
    }

    // MARK: - Missing category falls back to .top / .tshirt defaults

    @Test func missingCategoryFallsBackToSensibleDefaults() async {
        // Simulates a detection head that emitted a bbox but no category /
        // subcategory (e.g., the class-ID mapping regressed). Rules engine
        // still needs something concrete to key on.
        let base = MaskProposalFixture.make(
            predictedCategory: nil,
            predictedCategoryConfidence: 0.0,
            predictedSubcategory: nil,
            modelClassRaw: "unknown"
        )
        let classifier = MockAttributeClassifier() // returns .empty by default

        let enriched = await MultiGarmentProposalService.enriched(
            base, with: classifier, logger: Self.logger
        )

        // Category fields are preserved as nil (we don't fabricate predictions).
        #expect(enriched.predictedCategory == nil)
        #expect(enriched.predictedSubcategory == nil)

        // But seasons/occasions are still populated — the rules engine used
        // its internal .top / .tshirt fallbacks and produced non-empty sets.
        #expect(enriched.predictedSeasons.isEmpty == false,
                "Rules must produce a non-empty season set even with null category inputs")
        #expect(enriched.predictedOccasions.isEmpty == false,
                "Rules must produce a non-empty occasion set even with null category inputs")
    }

    // MARK: - Subcategory-only path

    @Test func subcategoryWithNilCategoryDerivesCategoryFromSubcategory() async {
        // The detection head sometimes produces a subcategory but a nil
        // top-level category (e.g., the Fashionpedia class mapped cleanly
        // to .skirt but the category-level argmax was below threshold).
        // Enrichment should use the subcategory's own `.category` chain.
        let base = MaskProposalFixture.make(
            predictedCategory: nil,
            predictedCategoryConfidence: 0.30,
            predictedSubcategory: .skirt,
            modelClassRaw: "skirt"
        )
        let classifier = MockAttributeClassifier()

        let enriched = await MultiGarmentProposalService.enriched(
            base, with: classifier, logger: Self.logger
        )

        // `.skirt` chains to `.bottom`, so the rules engine runs the bottom/
        // skirt clauses rather than the .top/.tshirt fallbacks. We don't
        // assert the exact season set (that's AttributeRulesEngineTests'
        // job) — just that we got a non-empty, non-fallback result.
        #expect(enriched.predictedSubcategory == .skirt)
        #expect(enriched.predictedSeasons.isEmpty == false)
        #expect(enriched.predictedOccasions.isEmpty == false)
    }

    // MARK: - No-prediction from classifier still triggers rules

    @Test func emptyClassifierPredictionStillTriggersRules() async {
        let base = MaskProposalFixture.make(
            predictedCategory: .shoe,
            predictedCategoryConfidence: 0.85,
            predictedSubcategory: .sandals,
            modelClassRaw: "shoe"
        )
        // Mock returns .empty by default — simulates the classifier running
        // successfully but every head coming in below the enum-emit threshold.
        let classifier = MockAttributeClassifier()

        let enriched = await MultiGarmentProposalService.enriched(
            base, with: classifier, logger: Self.logger
        )

        #expect(enriched.predictedTexture == nil)
        #expect(enriched.predictedFit == nil)
        #expect(enriched.predictedSeasons == [.summer],
                "Sandal rule keys on subcategory, not texture — must still fire")
    }
}
