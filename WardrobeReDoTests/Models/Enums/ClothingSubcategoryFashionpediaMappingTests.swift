import Testing
@testable import WardrobeReDo

/// Pin-down tests for `ClothingSubcategory.fromFashionpediaClass` against
/// the actual 33-class label vocabulary the bundled
/// `RFDETRSegFashion.mlmodelc` emits. Each parameter row corresponds to a
/// model id in `MultiGarmentProposalService.fashionpediaLabels`. If the
/// model's class list ever changes (retraining, schema update), these
/// tests catch a drifted mapping at compile / test time rather than at
/// runtime in the multi-pick UI.
///
/// **Authoritative source.** The class table comes from
/// `.build5-research/web-research/J-rfdetr-fashionpedia-classes.md` and
/// has been cross-checked against the canonical Fashionpedia annotation
/// JSON. Half the cases removed in Build 5 (e.g. `"sunglasses"`,
/// `"t-shirt"`, `"sweatshirt"`, `"trousers"`, `"gown"`, `"sneaker"`,
/// `"loafer"`) were dead aliases that the model never emitted —
/// asserting the *current* vocabulary keeps the switch honest.
struct ClothingSubcategoryFashionpediaMappingTests {

    // MARK: - Classes the model emits AND the switch claims a subcategory for

    @Test(arguments: [
        // Tops (Fashionpedia ids 0, 1, 2, 3)
        ("shirt_blouse", ClothingSubcategory.buttonDown),
        ("top_t-shirt_sweatshirt", .tshirt),
        ("sweater", .sweater),
        ("cardigan", .cardigan),
        // Bottoms (ids 9, 10)
        ("shorts", .shorts),
        ("skirt", .skirt),
        // Footwear (ids 15, 16)
        ("boot", .boots),
        ("sandal", .sandals),
        // Accessories (ids 19, 20, 22, 24, 25, 27, 29, 30, 31)
        ("glasses", .sunglasses),
        ("hat", .hat),
        ("scarf", .scarf),
        ("bag_wallet", .bag),
        ("belt", .belt),
        ("watch", .watch),
        ("bracelet", .bracelet),
        ("earring", .earrings),
        ("necklace", .necklace),
    ])
    func fromFashionpediaClassMapsKnownClasses(raw: String, expected: ClothingSubcategory) {
        #expect(ClothingSubcategory.fromFashionpediaClass(raw) == expected,
                "raw '\(raw)' expected to map to \(expected)")
    }

    // MARK: - Casing

    @Test func fromFashionpediaClassIsCaseInsensitive() {
        // The function lowercases its input. Capture this contract so a
        // refactor that drops the normalize step doesn't silently break
        // pipelines that pass mixed-case labels.
        #expect(ClothingSubcategory.fromFashionpediaClass("BOOT") == .boots)
        #expect(ClothingSubcategory.fromFashionpediaClass("Bag_Wallet") == .bag)
    }

    // MARK: - Classes the model emits but the switch deliberately doesn't map

    @Test(arguments: [
        // Ambiguous main classes — too many enum candidates per label
        "jacket", "coat", "pants", "shoe", "dress",
        // No matching enum case (excluded from v1 wardrobe vocabulary)
        "vest", "cape", "jumpsuit", "tie", "glove", "ring", "headband",
        // Excluded entirely from v1 product
        "sock", "leg_warmer", "umbrella", "tights_stockings",
    ])
    func fromFashionpediaClassReturnsNilForAmbiguousOrUnmappedClasses(raw: String) {
        #expect(ClothingSubcategory.fromFashionpediaClass(raw) == nil,
                "raw '\(raw)' should not commit to a subcategory")
    }

    // MARK: - Pre-Build-5 dead aliases must keep returning nil

    /// These tokens used to populate the switch but the model never
    /// actually emits them — they're either Fashionpedia attributes
    /// (sneaker, loafer, oxford), legacy tokens from a different
    /// vocabulary (sunglasses, trousers, gown), or singular variants of
    /// combo classes (t-shirt, top, shirt, sweatshirt, bag, wallet,
    /// purse). Asserting they return nil prevents an accidental revival
    /// that would silently shadow the real combo-class mapping.
    @Test(arguments: [
        "sunglasses", "trousers", "jeans", "cap", "baseballcap", "gown",
        "bag", "wallet", "purse", "sweatshirt", "top", "shirt", "t-shirt",
        "sneaker", "sneakers", "loafer", "loafers", "oxford", "oxfords",
        "heel", "heels", "flat", "flats",
    ])
    func fromFashionpediaClassReturnsNilForDeadAliases(raw: String) {
        #expect(ClothingSubcategory.fromFashionpediaClass(raw) == nil,
                "alias '\(raw)' is not in the trained vocabulary; the switch must not claim it")
    }

    // MARK: - Accessory rescue contract

    @Test(arguments: [
        ("glasses", ClothingSubcategory.sunglasses),
        ("belt", .belt),
        ("watch", .watch),
        ("scarf", .scarf),
        ("necklace", .necklace),
        ("bracelet", .bracelet),
        ("earring", .earrings),
        ("bag_wallet", .bag),
        ("hat", .hat),
    ])
    func accessorySubcategoryFromRawClassMapsKnownAccessories(raw: String, expected: ClothingSubcategory) {
        #expect(ClothingSubcategory.accessorySubcategoryFromRawClass(raw) == expected)
    }

    @Test(arguments: [
        // Non-accessory classes — rescue must not claim them
        "shirt_blouse", "boot", "shoe",
        // Dead aliases pruned in Build 5
        "sunglasses", "baseballcap", "cap",
        // Genuinely unmapped accessories (no enum case)
        "tie", "glove", "ring", "headband", "umbrella",
    ])
    func accessorySubcategoryFromRawClassReturnsNilOutsideVocabulary(raw: String) {
        #expect(ClothingSubcategory.accessorySubcategoryFromRawClass(raw) == nil)
    }

    // MARK: - Shoe rescue contract (new in Build 5)

    @Test func shoeSubcategoryRescueMapsBoot() {
        #expect(ClothingSubcategory.shoeSubcategoryFromRawClass("boot") == .boots)
    }

    @Test func shoeSubcategoryRescueMapsSandal() {
        #expect(ClothingSubcategory.shoeSubcategoryFromRawClass("sandal") == .sandals)
    }

    @Test func shoeSubcategoryRescueReturnsNilForGenericShoe() {
        // `shoe` (id 14) is too generic — sneaker/loafer/heel are
        // attributes, not categories. Returning nil lets `applyPrefill`
        // fall through to the `.sneakers` category default, which is
        // the right product call for the most common shoe type.
        #expect(ClothingSubcategory.shoeSubcategoryFromRawClass("shoe") == nil)
    }

    @Test func shoeSubcategoryRescueIsCaseInsensitive() {
        #expect(ClothingSubcategory.shoeSubcategoryFromRawClass("BOOT") == .boots)
        #expect(ClothingSubcategory.shoeSubcategoryFromRawClass("Sandal") == .sandals)
    }

    @Test(arguments: [
        // Non-shoe classes — rescue must not claim them
        "shirt_blouse", "glasses", "belt", "hat",
        // Dead pre-Build-5 aliases that never came from the model
        "sneaker", "sneakers", "loafer", "oxford", "heel",
    ])
    func shoeSubcategoryRescueReturnsNilOutsideVocabulary(raw: String) {
        #expect(ClothingSubcategory.shoeSubcategoryFromRawClass(raw) == nil)
    }
}
