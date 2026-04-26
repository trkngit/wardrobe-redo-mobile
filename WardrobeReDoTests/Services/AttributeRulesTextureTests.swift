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
        // unchanged for subcategories that commit to a fabric, and
        // tops without a rule (no category default for `.top`) keep
        // returning nil. `.cargo` and other bottoms now route through
        // the build-5 category default to `.denim` — see
        // `categoryDefaultRescuesBottomsWithoutSubcategoryRule` below.
        for (sub, expected): (ClothingSubcategory, TextureType?) in [
            (.jeans, .denim),
            (.leatherJacket, .leather),
            (.sweater, .knit),
            (.tshirt, nil),
        ] {
            let category = sub.category
            #expect(
                AttributeRulesEngine.deriveTexture(category: category, subcategory: sub) == expected,
                "engine drift for .\(sub): expected \(String(describing: expected))"
            )
        }
    }

    @Test func deriveTextureRespectsSubcategoryFirstThenCategoryDefault() {
        // PR #25 (build-5 dogfood): the engine consults the
        // subcategory-keyed rule first, then falls back to a
        // category-level default. The current rules don't condition on
        // category for the subcategory tier — `.jeans` always returns
        // `.denim` regardless of category. The category-default tier
        // rescues bottoms without a subcategory rule (e.g. `.shorts`
        // when the model misclassifies long jeans).
        //
        // Pass an *intentionally wrong* category for `.jeans` to confirm
        // the subcategory rule wins.
        #expect(
            AttributeRulesEngine.deriveTexture(category: .accessory, subcategory: .jeans) == .denim
        )
    }

    // MARK: - Build-5 category default (PR #25)

    @Test func categoryDefaultRescuesBottomsWithoutSubcategoryRule() {
        // The build-4 dogfood failure: a full-length jeans is
        // misclassified by the model as `.shorts`. `.shorts` has no
        // subcategory rule in `RulesTable.texture(for:)`, so without
        // the category default the picker stays nil and the user has
        // to manually pick `.denim` on every save. With the category
        // default in place, the rules engine routes `.bottom + .shorts`
        // → `.denim` (the dominant fabric for bottoms).
        //
        // Tested against every `.bottom` subcategory whose
        // `RulesTable.texture(for:)` lookup misses today. If a future
        // change adds a subcategory rule (e.g. `.chinos → .cotton`),
        // remove that subcategory from this list — it will route
        // through the more-specific subcategory rule instead.
        for sub: ClothingSubcategory in [
            .shorts, .chinos, .cargo, .joggers, .leggings,
            .skirt, .miniSkirt, .midiSkirt, .pencilSkirt,
            .wideLeg, .straightLeg, .slimFit, .dressPants,
        ] {
            #expect(
                AttributeRulesEngine.deriveTexture(category: .bottom, subcategory: sub) == .denim,
                "expected category-default .denim for .bottom + .\(sub)"
            )
        }
    }

    @Test func categoryDefaultDoesNotApplyToOtherCategories() {
        // The category default is intentionally limited to `.bottom`
        // because non-bottom categories span too many fabrics for a
        // default to be useful. Tops, shoes, accessories, etc. should
        // continue to return nil from the engine when no subcategory
        // rule fires — the picker stays empty.
        for (cat, sub): (ClothingCategory, ClothingSubcategory) in [
            (.top, .tshirt),
            (.top, .buttonDown),
            (.shoe, .sneakers),
            (.shoe, .sandals),
            (.accessory, .hat),
            (.accessory, .belt),
            (.dress, .casualDress),
            (.outerwear, .windbreaker),
        ] {
            #expect(
                AttributeRulesEngine.deriveTexture(category: cat, subcategory: sub) == nil,
                "expected nil texture for .\(cat) + .\(sub) (no category default)"
            )
        }
    }

    // MARK: - Confidence sentinel

    @Test func rulesTextureConfidenceIsAbovePrefillGate() {
        #expect(AttributeRulesEngine.rulesTextureConfidence > AttributePrefill.minConfidence)
    }
}
