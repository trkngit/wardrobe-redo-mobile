import Foundation
import Testing
@testable import WardrobeReDo

/// End-to-end integration tests covering the full
/// `MultiGarmentProposalService.applyAttributesAndRules` enrichment path
/// for textures, with focus on the build-4 dogfood failure modes.
///
/// **Build-4 dogfood findings** (`.build5-research/supabase/production-state.md`):
/// every multi-pick item shipped with `texture: null` in the database —
/// even denim jeans. Root cause (Hypothesis 4 of PR #25's investigation):
/// the upstream RFDETR detection head misclassified full-length jeans as
/// `predictedSubcategory: .shorts`. The texture rules engine ran, but
/// `RulesTable.texture(for: .shorts)` returns nil (correctly — shorts can
/// be cotton, linen, denim) and the rules-only fallback (with no ML
/// prediction) thus produced a nil texture. Result: the form's Texture
/// chip stayed empty, the user clicked Save without correcting, and the
/// item landed with no texture.
///
/// PR #25 adds a category-level fallback: when the subcategory rule
/// misses, consult `RulesTable.categoryDefaultTexture(for:)`. Bottoms
/// default to `.denim` (the dominant fabric in our user base); other
/// categories return nil so the picker stays empty.
///
/// Tests in this file walk a `MaskProposal` through the same
/// `applyAttributesAndRules` path the multi-pick form's
/// `onMultiPickConfirmed` → `startNextProposal` → `applyPrefill` chain
/// hits in production.
@Suite("MultiGarmentTextureRulesIntegration") struct MultiGarmentTextureRulesIntegrationTests {

    // MARK: - Build-4 regression: jeans-misclassified-as-shorts

    @Test func multiPickJeansWithShortsModelOutputStillGetsDenim() {
        // The exact build-4 failure: RFDETR emitted "shorts" for a
        // full-length jeans, mapped to `predictedSubcategory: .shorts`.
        // The bbox is the real production geometry from
        // `source_photo_id = e711569e-6a5d-4851-a7ef-23405f716c65`.
        //
        // Without the category-default fallback (PR #25), this would
        // shake out as `texture == nil` because `.shorts` has no
        // subcategory texture rule. With the fix, the rules engine
        // routes `.bottom` → `.denim` via the category default.
        let proposal = MaskProposalFixture.make(
            predictedCategory: .bottom,
            predictedCategoryConfidence: 0.95,
            predictedSubcategory: .shorts,
            boundingBox: CGRect(x: 0.30, y: 0.52, width: 0.24, height: 0.30),
            modelClassRaw: "shorts"
        )

        let enriched = MultiGarmentProposalService.applyAttributesAndRules(
            to: proposal,
            prediction: .empty
        )

        #expect(enriched.predictedTexture == .denim)
        #expect(enriched.predictedTextureConfidence == AttributeRulesEngine.rulesTextureConfidence)
        // Subcategory itself stays as the model's `.shorts` — fixing
        // the misclassification is PR #24's job (length classifier).
        // PR #25's contract is: even when subcategory is wrong, the
        // texture rules still fire.
        #expect(enriched.predictedSubcategory == .shorts)
    }

    // MARK: - Nil subcategory (Fashionpedia "pants" case)

    @Test func multiPickWithNilSubcategoryFallsBackToCategoryDefault() {
        // The other build-4 path: RFDETR emits raw class `"pants"` (a
        // generic, ambiguous Fashionpedia label). `fromFashionpediaClass`
        // returns nil — too ambiguous to commit jeans vs chinos vs
        // dress pants. `applyAttributesAndRules` resolves
        // `predictedCategory: .bottom`, `predictedSubcategory: nil`,
        // and falls back to `.jeans` (the first `.bottom` subcategory
        // in declaration order). `.jeans` then routes through the
        // subcategory rule to `.denim` — the category-default fallback
        // exists to handle the OTHER case: predictedSubcategory set but
        // wrong (.shorts for jeans), tested above.
        let proposal = MaskProposalFixture.make(
            predictedCategory: .bottom,
            predictedCategoryConfidence: 0.92,
            predictedSubcategory: nil,
            modelClassRaw: "pants"
        )

        let enriched = MultiGarmentProposalService.applyAttributesAndRules(
            to: proposal,
            prediction: .empty
        )

        #expect(enriched.predictedTexture == .denim)
        #expect(enriched.predictedTextureConfidence == AttributeRulesEngine.rulesTextureConfidence)
    }

    // MARK: - Sanity: known subcategory rules still fire

    @Test func multiPickProvidesTextureForKnownSubcategories() {
        // Existing subcategory rules — make sure the category-default
        // fallback didn't shadow them. The subcategory rule must win
        // when present (jeans → .denim, sweater → .knit,
        // leatherJacket → .leather).
        for (category, subcategory, expectedTexture): (ClothingCategory, ClothingSubcategory, TextureType) in [
            (.bottom, .jeans, .denim),
            (.top, .sweater, .knit),
            (.top, .hoodie, .knit),
            (.outerwear, .leatherJacket, .leather),
            (.outerwear, .denimJacket, .denim),
            (.outerwear, .cardigan, .knit),
        ] {
            let proposal = MaskProposalFixture.make(
                predictedCategory: category,
                predictedSubcategory: subcategory,
                modelClassRaw: subcategory.rawValue
            )

            let enriched = MultiGarmentProposalService.applyAttributesAndRules(
                to: proposal,
                prediction: .empty
            )

            #expect(
                enriched.predictedTexture == expectedTexture,
                "expected \(expectedTexture) for .\(category) + .\(subcategory), got \(String(describing: enriched.predictedTexture))"
            )
            #expect(enriched.predictedTextureConfidence == AttributeRulesEngine.rulesTextureConfidence)
        }
    }

    // MARK: - Non-bottom categories stay nil when subcategory rule misses

    @Test func multiPickKeepsNilTextureForAmbiguousNonBottomSubcategories() {
        // The category default is `.bottom` only — t-shirts,
        // sneakers, hats, etc. should still produce nil texture so
        // the picker stays empty rather than show a wrong default.
        for (category, subcategory): (ClothingCategory, ClothingSubcategory) in [
            (.top, .tshirt),
            (.top, .buttonDown),
            (.shoe, .sneakers),
            (.shoe, .boots),
            (.accessory, .hat),
            (.accessory, .belt),
            (.accessory, .sunglasses),
        ] {
            let proposal = MaskProposalFixture.make(
                predictedCategory: category,
                predictedSubcategory: subcategory,
                modelClassRaw: subcategory.rawValue
            )

            let enriched = MultiGarmentProposalService.applyAttributesAndRules(
                to: proposal,
                prediction: .empty
            )

            #expect(
                enriched.predictedTexture == nil,
                "expected nil texture for .\(category) + .\(subcategory) (no category default), got \(String(describing: enriched.predictedTexture))"
            )
            #expect(enriched.predictedTextureConfidence == 0.0)
        }
    }

    // Build 6 removed `mlPredictionStillWinsOverCategoryDefault` —
    // ML inference for texture was retired, so the precedence
    // ordering it pinned (ML > rules) is no longer reachable. The
    // remaining tests above continue to verify the rules path
    // including the new category-default fallback.
}
