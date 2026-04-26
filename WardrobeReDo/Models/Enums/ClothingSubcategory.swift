import Foundation

/// Subcategories users can pick when adding a wardrobe item.
///
/// Existing camelCase rawValues (`tshirt`, `buttonDown`, `sneakers`, …)
/// are kept verbatim — they're already persisted in Supabase rows for
/// existing users, so renaming would orphan their items.
///
/// Newer cases use explicit snake_case rawValues (`dressShirt =
/// "dress_shirt"`, `sneakerLow = "sneaker_low"`, …) that match the
/// fine-grained subcategory vocabulary used in the bundled `rules.json`.
/// These let users pick a precise subcategory at add-item time.
///
/// The `subcategory.rawValue` → rule-string bridging for older cases is
/// handled by `SubcategoryAliases.matches(itemSubcategory:requiredSubcategory:)`
/// — no rename required.
enum ClothingSubcategory: String, Codable, CaseIterable, Sendable {
    // MARK: - Tops
    case tshirt, buttonDown, polo, blazer, hoodie
    case sweater, tankTop, henley, cropTop, blouse
    case turtleneck, vneck, graphicTee
    // Snake-case extensions matching rules.json
    case dressShirt = "dress_shirt"
    case knitSweater = "knit_sweater"
    case sweatshirt
    case camisole
    case tank

    // MARK: - Bottoms
    case jeans, chinos, dressPants, shorts, cargo
    case joggers, skirt, miniSkirt, midiSkirt, wideLeg
    case straightLeg, slimFit
    case leggings
    case pencilSkirt = "pencil_skirt"

    // MARK: - Shoes
    case sneakers, dressShoes, boots, sandals
    case loafers, highTops, heels, flats
    case designerSneakers, chelseaBoots
    case sneakerLow = "sneaker_low"
    case sneakerHigh = "sneaker_high"
    case runningShoe = "running_shoe"
    case oxford
    case derby
    case balletFlat = "ballet_flat"

    // MARK: - Dresses
    case casualDress, cocktailDress, maxiDress
    case miniDress, shirtDress, wrapDress
    case midiDress = "midi_dress"
    case sundress
    case slipDress = "slip_dress"
    case sheathDress = "sheath_dress"

    // MARK: - Outerwear
    case winterCoat, leatherJacket, denimJacket
    case windbreaker, cardigan, varsityJacket
    case trench, parka, bomber, puffer
    case suitJacket = "suit_jacket"
    case overcoat
    case shirtJacket = "shirt_jacket"

    // MARK: - Accessories
    case baseballCap, beanie, scarf, belt
    case watch, sunglasses, necklace, bracelet
    case bag, backpack, fedoraHat, earrings
    case hat

    var displayName: String {
        switch self {
        // Tops
        case .tshirt: "T-Shirt"
        case .buttonDown: "Button-Down"
        case .polo: "Polo"
        case .blazer: "Blazer"
        case .hoodie: "Hoodie"
        case .sweater: "Sweater"
        case .tankTop: "Tank Top"
        case .henley: "Henley"
        case .cropTop: "Crop Top"
        case .blouse: "Blouse"
        case .turtleneck: "Turtleneck"
        case .vneck: "V-Neck"
        case .graphicTee: "Graphic Tee"
        case .dressShirt: "Dress Shirt"
        case .knitSweater: "Knit Sweater"
        case .sweatshirt: "Sweatshirt"
        case .camisole: "Camisole"
        case .tank: "Tank"
        // Bottoms
        case .jeans: "Jeans"
        case .chinos: "Chinos"
        case .dressPants: "Dress Pants"
        case .shorts: "Shorts"
        case .cargo: "Cargo"
        case .joggers: "Joggers"
        case .skirt: "Skirt"
        case .miniSkirt: "Mini Skirt"
        case .midiSkirt: "Midi Skirt"
        case .wideLeg: "Wide Leg"
        case .straightLeg: "Straight Leg"
        case .slimFit: "Slim Fit"
        case .leggings: "Leggings"
        case .pencilSkirt: "Pencil Skirt"
        // Shoes
        case .sneakers: "Sneakers"
        case .dressShoes: "Dress Shoes"
        case .boots: "Boots"
        case .sandals: "Sandals"
        case .loafers: "Loafers"
        case .highTops: "High Tops"
        case .heels: "Heels"
        case .flats: "Flats"
        case .designerSneakers: "Designer Sneakers"
        case .chelseaBoots: "Chelsea Boots"
        case .sneakerLow: "Low Sneaker"
        case .sneakerHigh: "High Sneaker"
        case .runningShoe: "Running Shoe"
        case .oxford: "Oxford"
        case .derby: "Derby"
        case .balletFlat: "Ballet Flat"
        // Dresses
        case .casualDress: "Casual Dress"
        case .cocktailDress: "Cocktail Dress"
        case .maxiDress: "Maxi Dress"
        case .miniDress: "Mini Dress"
        case .shirtDress: "Shirt Dress"
        case .wrapDress: "Wrap Dress"
        case .midiDress: "Midi Dress"
        case .sundress: "Sundress"
        case .slipDress: "Slip Dress"
        case .sheathDress: "Sheath Dress"
        // Outerwear
        case .winterCoat: "Winter Coat"
        case .leatherJacket: "Leather Jacket"
        case .denimJacket: "Denim Jacket"
        case .windbreaker: "Windbreaker"
        case .cardigan: "Cardigan"
        case .varsityJacket: "Varsity Jacket"
        case .trench: "Trench"
        case .parka: "Parka"
        case .bomber: "Bomber"
        case .puffer: "Puffer"
        case .suitJacket: "Suit Jacket"
        case .overcoat: "Overcoat"
        case .shirtJacket: "Shirt Jacket"
        // Accessories
        case .baseballCap: "Baseball Cap"
        case .beanie: "Beanie"
        case .scarf: "Scarf"
        case .belt: "Belt"
        case .watch: "Watch"
        case .sunglasses: "Sunglasses"
        case .necklace: "Necklace"
        case .bracelet: "Bracelet"
        case .bag: "Bag"
        case .backpack: "Backpack"
        case .fedoraHat: "Fedora Hat"
        case .earrings: "Earrings"
        case .hat: "Hat"
        }
    }

    var category: ClothingCategory {
        switch self {
        case .tshirt, .buttonDown, .polo, .blazer, .hoodie,
             .sweater, .tankTop, .henley, .cropTop, .blouse,
             .turtleneck, .vneck, .graphicTee,
             .dressShirt, .knitSweater, .sweatshirt, .camisole, .tank:
            .top
        case .jeans, .chinos, .dressPants, .shorts, .cargo,
             .joggers, .skirt, .miniSkirt, .midiSkirt, .wideLeg,
             .straightLeg, .slimFit,
             .leggings, .pencilSkirt:
            .bottom
        case .sneakers, .dressShoes, .boots, .sandals,
             .loafers, .highTops, .heels, .flats,
             .designerSneakers, .chelseaBoots,
             .sneakerLow, .sneakerHigh, .runningShoe,
             .oxford, .derby, .balletFlat:
            .shoe
        case .casualDress, .cocktailDress, .maxiDress,
             .miniDress, .shirtDress, .wrapDress,
             .midiDress, .sundress, .slipDress, .sheathDress:
            .dress
        case .winterCoat, .leatherJacket, .denimJacket,
             .windbreaker, .cardigan, .varsityJacket,
             .trench, .parka, .bomber, .puffer,
             .suitJacket, .overcoat, .shirtJacket:
            .outerwear
        case .baseballCap, .beanie, .scarf, .belt,
             .watch, .sunglasses, .necklace, .bracelet,
             .bag, .backpack, .fedoraHat, .earrings,
             .hat:
            .accessory
        }
    }

    static func subcategories(for category: ClothingCategory) -> [ClothingSubcategory] {
        allCases.filter { $0.category == category }
    }

    // MARK: - Fashionpedia mapping

    /// Map a Fashionpedia main-class string to a subcategory hint when
    /// the class commits to a specific subcategory. Returns `nil` for
    /// genuinely ambiguous classes (e.g. `"pants"` — jeans vs chinos vs
    /// dress pants can't be inferred from the label alone; `"jacket"` —
    /// bomber vs leather vs puffer, same problem).
    ///
    /// Companion to [`ClothingCategory.fromFashionpediaClass`](ClothingCategory.swift):
    /// category always resolves, subcategory only when the mapping is
    /// unambiguous. `MaskProposal.predictedSubcategory` consumers should
    /// fall back to the category's default subcategory when this returns
    /// nil.
    ///
    /// **Build 5 correctness pass.** The cases below are constrained to the
    /// 33-class label vocabulary the bundled `RFDETRSegFashion.mlmodelc`
    /// actually emits (see `MultiGarmentProposalService.fashionpediaLabels`
    /// and `.build5-research/web-research/J-rfdetr-fashionpedia-classes.md`).
    /// Anything outside that vocabulary used to be dead code — e.g. the
    /// model never emits `"sunglasses"`, `"t-shirt"`, `"sweatshirt"`,
    /// `"top"`, `"bag"`, `"wallet"`, `"purse"`, `"trousers"`, `"gown"`,
    /// `"sneaker"`, `"loafer"` — Fashionpedia uses combo classes
    /// (`shirt_blouse`, `top_t-shirt_sweatshirt`, `bag_wallet`) and the
    /// finer distinctions (sneaker/loafer/heel) live in the attribute
    /// head, not the segmentation classifier.
    static func fromFashionpediaClass(_ raw: String) -> ClothingSubcategory? {
        let normalized = raw.lowercased()
        switch normalized {
        // Tops — combo classes from Fashionpedia (model ids 0, 1)
        case "shirt_blouse":
            // Combo class covers both shirts and blouses; pick the
            // historically-common case (`.buttonDown`) so the picker
            // lands on a sensible default. Users override on the rare
            // blouse case.
            return .buttonDown
        case "top_t-shirt_sweatshirt":
            return .tshirt
        case "sweater":
            return .sweater
        case "cardigan":
            return .cardigan

        // Bottoms (model ids 9, 10)
        case "shorts":
            return .shorts
        case "skirt":
            return .skirt

        // Footwear (model ids 15, 16) — `shoe` (id 14) intentionally
        // returns nil; let `shoeSubcategoryFromRawClass` rescue + the
        // `.sneakers` default fire for that.
        case "boot":
            return .boots
        case "sandal":
            return .sandals

        // Accessories (model ids 19, 20, 22, 24, 25, 27, 29, 30, 31)
        case "glasses":
            return .sunglasses
        case "hat":
            return .hat
        case "scarf":
            return .scarf
        case "bag_wallet":
            return .bag
        case "belt":
            return .belt
        case "watch":
            return .watch
        case "bracelet":
            return .bracelet
        case "earring":
            return .earrings
        case "necklace":
            return .necklace

        // Explicitly nil for documentation. These ARE classes the model
        // emits but the mapping is ambiguous or no enum case exists:
        //   `jacket` (id 4)            — bomber/leather/puffer/...
        //   `vest` (id 5)              — no `.vest` enum case
        //   `coat` (id 6)              — trench/parka/winter/...
        //   `cape` (id 7)              — no `.cape` enum case
        //   `pants` (id 8)             — jeans/chinos/dress
        //   `tights_stockings` (id 11) — closest is `.leggings`, drift
        //   `dress` (id 12)            — maxi/mini/cocktail/...
        //   `jumpsuit` (id 13)         — no `.jumpsuit` enum case
        //   `shoe` (id 14)             — sneaker/loafer/heel/... (rescue)
        //   `sock` (id 17)             — excluded
        //   `leg_warmer` (id 18)       — excluded
        //   `headband` (id 21)         — no good enum match
        //   `tie` (id 23)              — no `.tie` enum case
        //   `glove` (id 26)            — no `.gloves` enum case
        //   `ring` (id 28)             — no `.ring` enum case
        //   `umbrella` (id 32)         — excluded
        default:
            return nil
        }
    }

    /// Rescue mapping for accessory-class Fashionpedia labels that
    /// `fromFashionpediaClass` returns nil for, but where the raw class
    /// gives an unambiguous hint (vs. defaulting blindly to .hat).
    ///
    /// Used by `AddItemViewModel.applyPrefill` exclusively for the
    /// `.accessory` category so that, e.g., a belt detection still
    /// pre-fills as `.belt` even when the upstream
    /// `fromFashionpediaClass` mapping is bypassed (low confidence,
    /// missing prediction, etc.). Returning nil signals "no rescue
    /// available — fall through to the category default."
    ///
    /// **Build 5 vocabulary pass.** Cases pruned to only the accessory
    /// labels the trained model actually emits — `glasses`, `belt`,
    /// `watch`, `scarf`, `necklace`, `bracelet`, `earring`, `bag_wallet`,
    /// `hat`. Aliases like `"sunglasses"` and `"baseballcap"` were dead
    /// code that never fired (the model doesn't emit those tokens).
    static func accessorySubcategoryFromRawClass(_ raw: String) -> ClothingSubcategory? {
        switch raw.lowercased() {
        case "glasses": return .sunglasses
        case "belt": return .belt
        case "watch": return .watch
        case "scarf": return .scarf
        case "necklace": return .necklace
        case "bracelet": return .bracelet
        case "earring": return .earrings
        case "bag_wallet": return .bag
        case "hat": return .hat
        default: return nil
        }
    }

    /// Rescue mapping for shoe-class detections. The model emits only
    /// `shoe`, `boot`, `sandal` (no sneaker/loafer/oxford classes — those
    /// are Fashionpedia *attributes*, not categories). Returning nil for
    /// `shoe` lets the caller fall through to the category default
    /// (`.sneakers`), which is the right product behavior — most shoes are
    /// sneakers and the user can correct on the rare wrong cases.
    ///
    /// Used by `AddItemViewModel.applyPrefill` exclusively for the
    /// `.shoe` category. Mirrors `accessorySubcategoryFromRawClass`'s
    /// rescue-first ordering so that the model's default
    /// `predictedSubcategory` (often `.boots` due to a class-id bias)
    /// never overrides a more specific raw-class signal.
    static func shoeSubcategoryFromRawClass(_ raw: String) -> ClothingSubcategory? {
        switch raw.lowercased() {
        case "boot": return .boots
        case "sandal": return .sandals
        case "shoe": return nil  // let `.sneakers` default fire
        default: return nil
        }
    }
}
