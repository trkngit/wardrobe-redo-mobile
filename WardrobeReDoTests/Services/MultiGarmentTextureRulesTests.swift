import Foundation
import Testing
@testable import WardrobeReDo

/// Integration tests for the rules-derived texture path inside
/// `MultiGarmentProposalService.applyAttributesAndRules`. Two invariants
/// remain after build 6 (ML texture inference was retired — see
/// `AttributeClassifierService` docstring):
///
///   1. **Rules fill the gap.** The deterministic subcategory→texture
///      mapping (jeans → denim, sweater → knit, …) populates the
///      proposal and stamps the 0.85 confidence sentinel.
///   2. **Rules respect ambiguity.** Generic subcategories with no
///      rule (t-shirt, chinos, …) keep the proposal's texture nil —
///      the picker stays empty rather than show a low-confidence guess.
@Suite("MultiGarmentProposalService.textureRules") struct MultiGarmentTextureRulesTests {

    // MARK: - Rules fill the gap

    @Test func rulesFillTextureWhenMLReturnsNil() {
        // Jeans + no ML prediction → rules engine fills .denim with
        // the 0.85 sentinel.
        let base = MaskProposalFixture.make(
            predictedCategory: .bottom,
            predictedSubcategory: .jeans
        )

        let enriched = MultiGarmentProposalService.applyAttributesAndRules(
            to: base,
            prediction: .empty
        )

        #expect(enriched.predictedTexture == .denim)
        #expect(enriched.predictedTextureConfidence == AttributeRulesEngine.rulesTextureConfidence)
    }

    @Test func rulesFillSweaterAsKnit() {
        let base = MaskProposalFixture.make(
            predictedCategory: .top,
            predictedSubcategory: .sweater,
            modelClassRaw: "sweater"
        )

        let enriched = MultiGarmentProposalService.applyAttributesAndRules(
            to: base,
            prediction: .empty
        )

        #expect(enriched.predictedTexture == .knit)
        #expect(enriched.predictedTextureConfidence == AttributeRulesEngine.rulesTextureConfidence)
    }

    @Test func rulesFillLeatherJacketAsLeather() {
        let base = MaskProposalFixture.make(
            predictedCategory: .outerwear,
            predictedSubcategory: .leatherJacket,
            modelClassRaw: "jacket"
        )

        let enriched = MultiGarmentProposalService.applyAttributesAndRules(
            to: base,
            prediction: .empty
        )

        #expect(enriched.predictedTexture == .leather)
    }

    // MARK: - Rules respect ambiguity

    @Test func ambiguousSubcategoryKeepsTextureNil() {
        // T-shirt is intentionally ambiguous — could be cotton, linen,
        // synthetic. Without an ML prediction the picker stays empty.
        let base = MaskProposalFixture.make(
            predictedCategory: .top,
            predictedSubcategory: .tshirt
        )

        let enriched = MultiGarmentProposalService.applyAttributesAndRules(
            to: base,
            prediction: .empty
        )

        #expect(enriched.predictedTexture == nil)
        #expect(enriched.predictedTextureConfidence == 0.0)
    }

}

// MARK: - Snapshot tag (texture_source) — driven through the
// AddItemViewModel multi-pick entry point used by the rest of the
// prefill suite. `.serialized` because the underlying flag is global.

@MainActor
@Suite("AddItemViewModel.textureSource", .serialized)
struct AddItemViewModelTextureSourceTests {

    private func withAttributeDetectionEnabled(_ block: () async -> Void) async {
        await FeatureFlagTestIsolation.shared.acquire()
        FeatureFlags.resetAll()
        FeatureFlags.isAttributeDetectionEnabled = true
        await block()
        FeatureFlags.resetAll()
        await FeatureFlagTestIsolation.shared.release()
    }

    @Test func recordsRulesSourceWhenConfidenceMatchesSentinel() async {
        // When the proposal's textureConfidence equals the
        // AttributeRulesEngine.rulesTextureConfidence sentinel, the
        // snapshot tags the source as "rules" — these stats fuel the
        // dogfood telemetry split between ML and rules predictions.
        await withAttributeDetectionEnabled {
            let vm = AddItemViewModel()
            let proposal = MaskProposalFixture.make(
                predictedCategory: .bottom,
                predictedCategoryConfidence: 0.95,
                predictedSubcategory: .jeans,
                predictedTexture: .denim,
                predictedTextureConfidence: AttributeRulesEngine.rulesTextureConfidence
            )
            vm.proposals = [proposal]
            vm.selectedProposalIDs = [proposal.id]

            await vm.onMultiPickConfirmed()

            #expect(vm.texture == .denim)
            #expect(vm.detectedAttributes["texture"] == TextureType.denim.rawValue)
            #expect(vm.detectedAttributes["texture_source"] == "rules")
        }
    }

    @Test func textureSourceAlwaysRulesAfterBuild6() async {
        // Build 6 retired the ML texture path. Every prefilled
        // texture is now rules-derived — even when the proposal's
        // textureConfidence doesn't match the sentinel exactly (e.g.
        // a historical row from a previous build that stamped a real
        // softmax score). The snapshot tag must always read "rules"
        // so downstream telemetry stops branching on the source.
        await withAttributeDetectionEnabled {
            let vm = AddItemViewModel()
            let proposal = MaskProposalFixture.make(
                predictedCategory: .bottom,
                predictedCategoryConfidence: 0.95,
                predictedSubcategory: .jeans,
                predictedTexture: .denim,
                predictedTextureConfidence: 0.93
            )
            vm.proposals = [proposal]
            vm.selectedProposalIDs = [proposal.id]

            await vm.onMultiPickConfirmed()

            #expect(vm.texture == .denim)
            #expect(vm.detectedAttributes["texture"] == TextureType.denim.rawValue)
            #expect(vm.detectedAttributes["texture_source"] == "rules")
        }
    }
}
