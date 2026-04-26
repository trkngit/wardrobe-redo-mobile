import Foundation
import Testing
@testable import WardrobeReDo

/// Exhaustive tests for the Fashionpedia → `ClothingCategory` mapping.
/// The mapping handles **only** the 33 strings the trained
/// `RFDETRSegFashion.mlmodelc` model actually emits (per
/// `MultiGarmentProposalService.fashionpediaLabels`). Singular/legacy
/// aliases like `"sunglasses"`, `"trousers"`, `"jeans"`, `"bag"`,
/// `"gown"`, `"sneaker"`, `"loafer"` are NOT in the switch — those
/// labels never come out of the model and routing them through here
/// would have masked real drift.
///
/// The drift-guard test at the bottom asserts every label in
/// `fashionpediaLabels` either maps to a category or appears in
/// `fashionpediaExcludedLabels`, so adding a new model class without
/// updating this enum is a compile-or-test failure, never a silent
/// drop.
struct ClothingCategoryFashionpediaTests {

    // MARK: - Tops (5 model classes)

    @Test func mapsShirtBlouseToTop() {
        #expect(ClothingCategory.fromFashionpediaClass("shirt_blouse") == .top)
    }

    @Test func mapsTopTshirtSweatshirtToTop() {
        #expect(ClothingCategory.fromFashionpediaClass("top_t-shirt_sweatshirt") == .top)
    }

    @Test func mapsSweaterCardiganVestToTop() {
        #expect(ClothingCategory.fromFashionpediaClass("sweater") == .top)
        #expect(ClothingCategory.fromFashionpediaClass("cardigan") == .top)
        #expect(ClothingCategory.fromFashionpediaClass("vest") == .top)
    }

    // MARK: - Bottoms (4 model classes)

    @Test func mapsPantsShortsTightsSkirtToBottom() {
        #expect(ClothingCategory.fromFashionpediaClass("pants") == .bottom)
        #expect(ClothingCategory.fromFashionpediaClass("shorts") == .bottom)
        #expect(ClothingCategory.fromFashionpediaClass("tights_stockings") == .bottom)
        #expect(ClothingCategory.fromFashionpediaClass("skirt") == .bottom)
    }

    // MARK: - Dresses (2 model classes)

    @Test func mapsDressAndJumpsuitToDress() {
        #expect(ClothingCategory.fromFashionpediaClass("dress") == .dress)
        #expect(ClothingCategory.fromFashionpediaClass("jumpsuit") == .dress)
    }

    // MARK: - Outerwear (3 model classes)

    @Test func mapsCoatJacketCapeToOuterwear() {
        #expect(ClothingCategory.fromFashionpediaClass("coat") == .outerwear)
        #expect(ClothingCategory.fromFashionpediaClass("jacket") == .outerwear)
        #expect(ClothingCategory.fromFashionpediaClass("cape") == .outerwear)
    }

    // MARK: - Shoes (3 model classes)

    @Test func mapsShoeBootSandalToShoe() {
        #expect(ClothingCategory.fromFashionpediaClass("shoe") == .shoe)
        #expect(ClothingCategory.fromFashionpediaClass("boot") == .shoe)
        #expect(ClothingCategory.fromFashionpediaClass("sandal") == .shoe)
    }

    // MARK: - Accessories (13 model classes — all collapse to one v1 enum)

    @Test func mapsGlassesToAccessory() {
        #expect(ClothingCategory.fromFashionpediaClass("glasses") == .accessory)
    }

    @Test func mapsHeadwearToAccessory() {
        #expect(ClothingCategory.fromFashionpediaClass("hat") == .accessory)
        #expect(ClothingCategory.fromFashionpediaClass("headband") == .accessory)
    }

    @Test func mapsScarfAndTieToAccessory() {
        #expect(ClothingCategory.fromFashionpediaClass("scarf") == .accessory)
        #expect(ClothingCategory.fromFashionpediaClass("tie") == .accessory)
    }

    @Test func mapsBagAndBeltAndGloveToAccessory() {
        #expect(ClothingCategory.fromFashionpediaClass("bag_wallet") == .accessory)
        #expect(ClothingCategory.fromFashionpediaClass("belt") == .accessory)
        #expect(ClothingCategory.fromFashionpediaClass("glove") == .accessory)
    }

    @Test func mapsJewelryToAccessory() {
        #expect(ClothingCategory.fromFashionpediaClass("watch") == .accessory)
        #expect(ClothingCategory.fromFashionpediaClass("ring") == .accessory)
        #expect(ClothingCategory.fromFashionpediaClass("bracelet") == .accessory)
        #expect(ClothingCategory.fromFashionpediaClass("earring") == .accessory)
        #expect(ClothingCategory.fromFashionpediaClass("necklace") == .accessory)
    }

    // MARK: - Excluded (3 model classes — surfaced as nil)

    @Test func doesNotSurfaceSocksOrLegwear() {
        #expect(ClothingCategory.fromFashionpediaClass("sock") == nil)
        #expect(ClothingCategory.fromFashionpediaClass("leg_warmer") == nil)
    }

    @Test func doesNotSurfaceUmbrella() {
        #expect(ClothingCategory.fromFashionpediaClass("umbrella") == nil)
    }

    // MARK: - Drift guard (parametric)

    /// Every label `fashionpediaLabels` declares must either map to a
    /// category or appear in `fashionpediaExcludedLabels`. A new entry
    /// in either array without updating `fromFashionpediaClass` would
    /// fail this test. Mirrors the structure of
    /// `ClothingSubcategoryFashionpediaMappingTests` so the drift
    /// guard is consistent across the two enums.
    @Test func everyFashionpediaLabelIsAccountedFor() {
        for label in MultiGarmentProposalService.fashionpediaLabels {
            let mapped = ClothingCategory.fromFashionpediaClass(label)
            let isExcluded = MultiGarmentProposalService.fashionpediaExcludedLabels.contains(label)
            // A label is "accounted for" when it either resolves to a
            // category OR is on the explicit exclusion list. Anything
            // else is a silent drop.
            #expect(
                mapped != nil || isExcluded,
                "Fashionpedia label `\(label)` is neither mapped to a category nor in the excluded set — silent drop in production."
            )
        }
    }

    /// `fashionpediaExcludedLabels` should map to nil. If a label moves
    /// in/out of the excluded set without updating the switch, this
    /// test catches it.
    @Test func excludedLabelsResolveToNil() {
        for label in MultiGarmentProposalService.fashionpediaExcludedLabels {
            #expect(
                ClothingCategory.fromFashionpediaClass(label) == nil,
                "Excluded label `\(label)` resolved to a category — drift between exclusion set and mapping."
            )
        }
    }

    // MARK: - Dead aliases stay nil

    /// Strings the model never emits should resolve to nil. Pre-build-5
    /// the switch covered these as if they were real labels; they're
    /// dead code now. This test pins that they stay nil so a future
    /// well-meaning change doesn't accidentally re-add them.
    @Test(arguments: [
        // Singular aliases the model replaced with combo classes
        "shirt", "blouse", "top", "t-shirt", "sweatshirt",
        "tights", "stockings",
        "bag", "wallet", "purse",
        "earrings",
        // Common-language aliases not in Fashionpedia
        "sunglasses", "trousers", "jeans", "cap", "baseballcap",
        "gown", "romper", "blazer",
        // Subcategory-level (Fashionpedia treats these as attributes)
        "sneaker", "sneakers", "loafer", "loafers", "oxford", "oxfords",
        "heel", "heels", "flat", "flats",
        // Garment parts (in 46-class Fashionpedia, NOT in 33-class trained subset)
        "hood", "head_covering", "hood_head_covering",
        "bow_tie",
    ])
    func deadAliasesReturnNil(raw: String) {
        #expect(ClothingCategory.fromFashionpediaClass(raw) == nil)
    }

    // MARK: - Unknown classes

    @Test func unknownClassesReturnNil() {
        #expect(ClothingCategory.fromFashionpediaClass("") == nil)
        #expect(ClothingCategory.fromFashionpediaClass("definitely_not_a_real_class") == nil)
        #expect(ClothingCategory.fromFashionpediaClass("class_42") == nil)
    }

    // MARK: - Case-insensitivity

    @Test func mappingIsCaseInsensitive() {
        #expect(ClothingCategory.fromFashionpediaClass("SHIRT_BLOUSE") == .top)
        #expect(ClothingCategory.fromFashionpediaClass("Jacket") == .outerwear)
        #expect(ClothingCategory.fromFashionpediaClass("SANDAL") == .shoe)
        #expect(ClothingCategory.fromFashionpediaClass("Bag_Wallet") == .accessory)
    }
}
