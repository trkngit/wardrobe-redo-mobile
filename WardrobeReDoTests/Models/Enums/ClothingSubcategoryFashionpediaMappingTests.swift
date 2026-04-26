import CoreGraphics
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

    // MARK: - Shoe rescue contract (Build 6 user-favoring update)

    /// Build-5 mapped `boot` → `.boots` to honor the model's class. But
    /// dogfood revealed the `boot` head fires on actual sneakers more
    /// often than actual boots, so trusting it was net-negative for
    /// users. Build 6 returns nil so the `.sneakers` default fires.
    /// Same trade-off as PR #25's `.bottom → .denim` — defaulting to
    /// the most common case beats trusting an unreliable signal.
    @Test func shoeSubcategoryRescueLetsBootDefaultToSneakers() {
        #expect(ClothingSubcategory.shoeSubcategoryFromRawClass("boot") == nil)
    }

    @Test func shoeSubcategoryRescueMapsSandal() {
        // Sandal head is empirically reliable, unlike boot.
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
        #expect(ClothingSubcategory.shoeSubcategoryFromRawClass("Sandal") == .sandals)
        // BOOT now also returns nil under Build 6.
        #expect(ClothingSubcategory.shoeSubcategoryFromRawClass("BOOT") == nil)
    }

    @Test(arguments: [
        // Non-shoe classes — rescue must not claim them
        "shirt_blouse", "glasses", "belt", "hat",
        // Dead pre-Build-5 aliases that never came from the model
        "sneaker", "sneakers", "loafer", "oxford", "heel",
        // Build 6: `boot` now returns nil too (user-favoring)
        "boot",
    ])
    func shoeSubcategoryRescueReturnsNilOutsideVocabulary(raw: String) {
        #expect(ClothingSubcategory.shoeSubcategoryFromRawClass(raw) == nil)
    }

    // MARK: - Bbox heuristic for unmapped accessory classes (Build 6)

    /// Build-5 dogfood found the model emits unmapped accessory classes
    /// (`headband`, `tie`, `glove`, `ring`) for items that are visually
    /// sunglasses or belts. The bbox-position heuristic infers the
    /// likely subcategory from where the item lives in the frame.
    ///
    /// Pure-function tests here pin the geometric contract; integration
    /// tests in `AddItemViewModelAccessoryRescueTests` exercise the
    /// heuristic's wiring inside `applyPrefill`.

    @Test func bboxHeuristicSunglassesFromFaceArea() {
        // y-mid 0.30 < 0.40, height 0.06 < 0.10 → face-area thin strip
        let bbox = CGRect(x: 0.30, y: 0.27, width: 0.40, height: 0.06)
        #expect(ClothingSubcategory.accessorySubcategoryFromBboxHeuristic(bbox) == .sunglasses)
    }

    @Test func bboxHeuristicBeltFromWaistArea() {
        // y-mid 0.53 ∈ [0.42, 0.62], height 0.04 < 0.10 → waist thin strip
        let bbox = CGRect(x: 0.30, y: 0.51, width: 0.40, height: 0.04)
        #expect(ClothingSubcategory.accessorySubcategoryFromBboxHeuristic(bbox) == .belt)
    }

    @Test func bboxHeuristicHatForLargeBboxes() {
        // height 0.5 >= 0.10 → not thin → falls back to .hat
        let bbox = CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5)
        #expect(ClothingSubcategory.accessorySubcategoryFromBboxHeuristic(bbox) == .hat)
    }

    @Test func bboxHeuristicHatForLowAreaThinBbox() {
        // y-mid 0.85 outside both face (<0.40) and waist ([0.42, 0.62])
        // ranges, even with thin height. Falls back to .hat — not
        // ideal for a sock-or-something accessory at the foot, but the
        // heuristic intentionally only carves out the high-confidence
        // sunglasses/belt cases.
        let bbox = CGRect(x: 0.30, y: 0.83, width: 0.40, height: 0.04)
        #expect(ClothingSubcategory.accessorySubcategoryFromBboxHeuristic(bbox) == .hat)
    }

    @Test func bboxHeuristicHatForMidAreaTallBbox() {
        // y-mid 0.50 ∈ [0.42, 0.62] but height 0.30 NOT thin.
        // Mid-frame tall bbox is more likely a top/jacket misclassified
        // as accessory than a belt — fall back to .hat.
        let bbox = CGRect(x: 0.20, y: 0.35, width: 0.60, height: 0.30)
        #expect(ClothingSubcategory.accessorySubcategoryFromBboxHeuristic(bbox) == .hat)
    }
}
