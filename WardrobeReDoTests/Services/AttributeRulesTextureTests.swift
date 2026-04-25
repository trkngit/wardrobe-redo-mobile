import Foundation
import Testing
@testable import WardrobeReDo

/// Tests for the rules-derived texture pre-fill — the v1 stop-gap that
/// fills in `MaskProposal.predictedTexture` from the subcategory alone
/// while the v1.1 attribute classifier's texture head is still in
/// training.
///
/// Two layers under test:
///   1. `RulesTable.texture(for:)` — pure subcategory → texture lookup.
///      Conservative: unambiguous subcategories return a concrete
///      texture, generic subcategories return nil.
///   2. `AttributeRulesEngine.deriveTexture(category:subcategory:)` —
///      passes through to the rules table today, but the parameter
///      shape leaves room for category-conditional rules later.
@Suite("AttributeRulesTexture") struct AttributeRulesTextureTests {

    // MARK: - High-confidence rules

    @Test func jeansResolveToDenim() {
        #expect(RulesTable.texture(for: .jeans) == .denim)
    }

    @Test func denimJacketResolvesToDenim() {
        #expect(RulesTable.texture(for: .denimJacket) == .denim)
    }

    @Test func leatherJacketResolvesToLeather() {
        #expect(RulesTable.texture(for: .leatherJacket) == .leather)
    }

    @Test func sweaterAndCardiganResolveToKnit() {
        #expect(RulesTable.texture(for: .sweater) == .knit)
        #expect(RulesTable.texture(for: .knitSweater) == .knit)
        #expect(RulesTable.texture(for: .cardigan) == .knit)
        #expect(RulesTable.texture(for: .turtleneck) == .knit)
    }

    @Test func sweatshirtAndHoodieResolveToKnit() {
        // No `.fleece` slot in `TextureType` today — sweatshirts and
        // hoodies share the `.knit` bucket with sweaters. Tracked as
        // a future enum-split if it surfaces in dogfood feedback.
        #expect(RulesTable.texture(for: .sweatshirt) == .knit)
        #expect(RulesTable.texture(for: .hoodie) == .knit)
    }

    // MARK: - Conservative defaults

    @Test func ambiguousSubcategoriesReturnNil() {
        // Picker stays empty for these — a low-confidence guess is more
        // annoying than no guess. Keep the list tight; everything in
        // it should be a subcategory whose name does NOT commit to a
        // fabric.
        for sub: ClothingSubcategory in [
            .tshirt, .buttonDown, .polo, .blazer, .dressShirt,
            .tankTop, .tank, .camisole, .cropTop, .henley,
            .chinos, .shorts, .cargo, .joggers,
            .sneakers, .sandals, .heels, .loafers,
            .casualDress, .cocktailDress, .maxiDress,
            .windbreaker, .bomber, .puffer, .trench,
            .hat, .belt, .watch, .scarf,
        ] {
            #expect(
                RulesTable.texture(for: sub) == nil,
                "expected nil texture for ambiguous subcategory .\(sub)"
            )
        }
    }

    // MARK: - AttributeRulesEngine wrapper

    @Test func deriveTextureMatchesRulesTable() {
        // The engine wrapper should pass through rules-table results
        // unchanged today. Check a representative cross-section.
        for (sub, expected): (ClothingSubcategory, TextureType?) in [
            (.jeans, .denim),
            (.leatherJacket, .leather),
            (.sweater, .knit),
            (.tshirt, nil),
            (.cargo, nil),
        ] {
            let category = sub.category
            #expect(
                AttributeRulesEngine.deriveTexture(category: category, subcategory: sub) == expected,
                "engine drift for .\(sub): expected \(String(describing: expected))"
            )
        }
    }

    @Test func deriveTextureIgnoresCategoryParameter() {
        // The current rules don't condition on category. Make that
        // contract explicit so a future category-conditional rule
        // doesn't silently regress these checks.
        // Pass an *intentionally wrong* category and assert the same
        // texture comes back — the rule keys on subcategory alone.
        #expect(
            AttributeRulesEngine.deriveTexture(category: .accessory, subcategory: .jeans) == .denim
        )
    }

    // MARK: - Confidence sentinel

    @Test func rulesTextureConfidenceIsAbovePrefillGate() {
        #expect(AttributeRulesEngine.rulesTextureConfidence > AttributePrefill.minConfidence)
    }
}
