import Foundation
import Testing
@testable import WardrobeReDo

/// Exhaustive tests for the Fashionpedia → `ClothingCategory` mapping.
/// This mapping is the single source of truth, so every known
/// Fashionpedia main class is explicitly asserted. Silent drops — a new
/// class getting added to the model without a case here — would be
/// caught by the "unknown classes map to nil" test + the per-class
/// assertions below.
struct ClothingCategoryFashionpediaTests {

    // MARK: - Tops

    @Test func mapsShirtBlouseToTop() {
        #expect(ClothingCategory.fromFashionpediaClass("shirt_blouse") == .top)
        #expect(ClothingCategory.fromFashionpediaClass("shirt") == .top)
        #expect(ClothingCategory.fromFashionpediaClass("blouse") == .top)
    }

    @Test func mapsTopTshirtSweatshirtToTop() {
        #expect(ClothingCategory.fromFashionpediaClass("top_t-shirt_sweatshirt") == .top)
        #expect(ClothingCategory.fromFashionpediaClass("t-shirt") == .top)
        #expect(ClothingCategory.fromFashionpediaClass("sweatshirt") == .top)
        #expect(ClothingCategory.fromFashionpediaClass("top") == .top)
    }

    @Test func mapsSweaterCardiganVestToTop() {
        #expect(ClothingCategory.fromFashionpediaClass("sweater") == .top)
        #expect(ClothingCategory.fromFashionpediaClass("cardigan") == .top)
        #expect(ClothingCategory.fromFashionpediaClass("vest") == .top)
    }

    // MARK: - Bottoms

    @Test func mapsPantsShortsTightsSkirtToBottom() {
        #expect(ClothingCategory.fromFashionpediaClass("pants") == .bottom)
        #expect(ClothingCategory.fromFashionpediaClass("shorts") == .bottom)
        #expect(ClothingCategory.fromFashionpediaClass("tights_stockings") == .bottom)
        #expect(ClothingCategory.fromFashionpediaClass("skirt") == .bottom)
    }

    // MARK: - Dresses

    @Test func mapsDressAndJumpsuitToDress() {
        #expect(ClothingCategory.fromFashionpediaClass("dress") == .dress)
        #expect(ClothingCategory.fromFashionpediaClass("jumpsuit") == .dress)
    }

    // MARK: - Outerwear

    @Test func mapsCoatJacketCapeToOuterwear() {
        #expect(ClothingCategory.fromFashionpediaClass("coat") == .outerwear)
        #expect(ClothingCategory.fromFashionpediaClass("jacket") == .outerwear)
        #expect(ClothingCategory.fromFashionpediaClass("cape") == .outerwear)
        #expect(ClothingCategory.fromFashionpediaClass("blazer") == .outerwear)
    }

    // MARK: - Shoes

    @Test func mapsShoeBootSandalToShoe() {
        #expect(ClothingCategory.fromFashionpediaClass("shoe") == .shoe)
        #expect(ClothingCategory.fromFashionpediaClass("boot") == .shoe)
        #expect(ClothingCategory.fromFashionpediaClass("sandal") == .shoe)
    }

    // MARK: - Accessories (v1 compromise: everything collapses here)

    @Test func mapsGlassesAndSunglassesToAccessory() {
        #expect(ClothingCategory.fromFashionpediaClass("glasses") == .accessory)
        #expect(ClothingCategory.fromFashionpediaClass("sunglasses") == .accessory)
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

    // MARK: - Not surfaced in v1

    @Test func doesNotSurfaceSocksOrLegwear() {
        #expect(ClothingCategory.fromFashionpediaClass("sock") == nil)
        #expect(ClothingCategory.fromFashionpediaClass("leg_warmer") == nil)
    }

    @Test func doesNotSurfaceUmbrella() {
        #expect(ClothingCategory.fromFashionpediaClass("umbrella") == nil)
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
    }
}
