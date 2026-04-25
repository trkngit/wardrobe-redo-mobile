import Foundation
import Testing
@testable import WardrobeReDo

/// Integration tests for the rules-derived texture path inside
/// `MultiGarmentProposalService.applyAttributesAndRules`. Three
/// invariants:
///
///   1. **ML wins when present.** A non-nil `prediction.texture` should
///      pass through verbatim, even when a rules-derived texture exists.
///   2. **Rules fill the gap.** When ML returns no texture, the rules
///      table populates the proposal with the deterministic mapping
///      (jeans → denim, sweater → knit, …) and stamps the 0.85
///      confidence sentinel.
///   3. **Rules respect ambiguity.** Generic subcategories with no
///      rule (t-shirt, chinos, …) keep the proposal's texture nil —
///      the picker stays empty rather than show a low-confidence guess.
@Suite("MultiGarmentProposalService.textureRules") struct MultiGarmentTextureRulesTests {

    // MARK: - ML-wins path

    @Test func mlPredictionTakesPrecedenceOverRules() {
        // Jeans subcategory would route to .denim via rules, but the
        // ML pipeline confidently said .leather (e.g. raw-leather skinny
        // jeans). The ML answer must win — rules are a fallback, not a
        // gate.
        let base = MaskProposalFixture.make(
            predictedCategory: .bottom,
            predictedSubcategory: .jeans
        )
        let mlPrediction = AttributePrediction(
            texture: .leather,
            textureConfidence: 0.92,
            fit: nil,
            fitConfidence: 0.0
        )

        let enriched = MultiGarmentProposalService.applyAttributesAndRules(
            to: base,
            prediction: mlPrediction
        )

        #expect(enriched.predictedTexture == .leather)
        #expect(enriched.predictedTextureConfidence == 0.92)
    }

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

            vm.onMultiPickConfirmed()

            #expect(vm.texture == .denim)
            #expect(vm.detectedAttributes["texture"] == TextureType.denim.rawValue)
            #expect(vm.detectedAttributes["texture_source"] == "rules")
        }
    }

    @Test func recordsMLSourceWhenConfidenceDiffersFromSentinel() async {
        // 0.93 is well above the prefill gate but doesn't equal the
        // rules sentinel — recorded as "ml".
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

            vm.onMultiPickConfirmed()

            #expect(vm.texture == .denim)
            #expect(vm.detectedAttributes["texture"] == TextureType.denim.rawValue)
            #expect(vm.detectedAttributes["texture_source"] == "ml")
        }
    }
}
