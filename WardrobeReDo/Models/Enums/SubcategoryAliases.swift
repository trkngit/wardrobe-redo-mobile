import Foundation

/// Bridges the Swift `ClothingSubcategory` enum to the fine-grained
/// snake_case subcategory vocabulary used in the bundled `rules.json`.
///
/// Without this map a wardrobe item with subcategory `.sneakers`
/// (rawValue `"sneakers"`) would never satisfy a rule that requires
/// `"sneaker_low"` or `"running_shoe"`. Beam search would expand to
/// zero candidates and the UI would surface a generic timeout.
///
/// The 56 unique subcategory strings in `rules.json` were extracted by
/// scanning every `slot_requirements[].subcategories[]` entry. Each
/// existing camelCase enum rawValue is mapped to the rule strings it
/// reasonably represents (e.g. `dressShoes` → `oxford`, `derby`,
/// `loafer`). Identity matches (`tshirt` → `tshirt`) are handled by
/// `matches(itemSubcategory:requiredSubcategory:)` directly and don't
/// need to be enumerated here.
///
/// Newly added snake_case rawValues (e.g. `sneakerLow = "sneaker_low"`)
/// match their rule string by identity and don't need an alias entry.
enum SubcategoryAliases {

    /// Map: a wardrobe item's `subcategory.rawValue` → the set of
    /// `rules.json` subcategory strings it satisfies. The identity match
    /// is handled separately, so entries here are only the bridging
    /// mappings between camelCase enum rawValues and snake_case rule
    /// strings.
    static let itemMatches: [String: Set<String>] = [
        // MARK: Tops
        "tshirt":           ["tshirt", "tee", "t_shirt"],
        "graphicTee":       ["tshirt", "tee", "graphic_tee"],
        "buttonDown":       ["button_down", "dress_shirt", "oxford", "shirt_jacket"],
        "polo":             ["polo", "polo_shirt"],
        "blazer":           ["blazer", "suit_jacket", "sport_coat"],
        "hoodie":           ["hoodie", "sweatshirt", "pullover_hoodie"],
        "sweater":          ["knit_sweater", "sweater", "sweatshirt", "pullover", "crewneck"],
        "tankTop":          ["tank", "camisole", "tank_top", "muscle_tee"],
        "henley":           ["henley", "henley_shirt"],
        "cropTop":          ["crop_top"],
        "blouse":           ["blouse", "camisole", "silk_blouse"],
        "turtleneck":       ["turtleneck", "knit_sweater", "mock_neck"],
        "vneck":            ["tshirt", "tee", "v_neck", "vneck"],

        // MARK: Bottoms
        "jeans":            ["jeans", "denim_pants", "slim_jean", "straight_jean"],
        "chinos":           ["chinos", "chino_pants", "khakis"],
        "dressPants":       ["dress_pants", "trousers", "slacks", "wool_trousers"],
        "shorts":           ["shorts", "chino_shorts", "athletic_shorts"],
        "cargo":            ["cargo", "cargo_pants"],
        "joggers":          ["joggers", "leggings", "sweatpants", "track_pants"],
        "skirt":            ["midi_skirt", "pencil_skirt", "skirt"],
        "miniSkirt":        ["pencil_skirt", "mini_skirt", "skirt"],
        "midiSkirt":        ["midi_skirt", "skirt"],
        "wideLeg":          ["wide_leg", "wide_leg_pant", "palazzo"],
        "straightLeg":      ["dress_pants", "chinos", "jeans", "straight_pant"],
        "slimFit":          ["chinos", "dress_pants", "jeans", "slim_pant"],

        // MARK: Shoes
        "sneakers":         ["sneaker_low", "sneaker_high", "running_shoe",
                             "athletic_shoe", "trainer", "tennis_shoe"],
        "designerSneakers": ["sneaker_low", "designer_sneaker"],
        "highTops":         ["sneaker_high", "high_top"],
        "dressShoes":       ["oxford", "derby", "loafer", "dress_shoe", "monk_strap", "wholecut"],
        "loafers":          ["loafer", "penny_loafer", "horsebit_loafer", "tassel_loafer"],
        "boots":            ["boot", "chelsea_boot", "ankle_boot", "combat_boot", "work_boot"],
        "chelseaBoots":     ["chelsea_boot", "boot", "ankle_boot"],
        "heels":            ["heel", "pump", "stiletto", "kitten_heel"],
        "flats":            ["ballet_flat", "flat", "ballerina"],
        "sandals":          ["sandal", "slide", "espadrille"],

        // MARK: Dresses
        "casualDress":      ["sundress", "shirt_dress", "midi_dress", "day_dress"],
        "cocktailDress":    ["cocktail_dress", "sheath_dress", "midi_dress"],
        "maxiDress":        ["maxi_dress"],
        "miniDress":        ["slip_dress", "mini_dress"],
        "shirtDress":       ["shirt_dress"],
        "wrapDress":        ["wrap_dress"],

        // MARK: Outerwear
        "winterCoat":       ["overcoat", "winter_coat", "wool_coat"],
        "leatherJacket":    ["leather_jacket", "shirt_jacket", "moto_jacket", "biker_jacket"],
        "denimJacket":      ["denim_jacket", "shirt_jacket", "trucker_jacket"],
        "windbreaker":      ["windbreaker", "shell_jacket"],
        "cardigan":         ["cardigan", "knit_sweater", "knit_cardigan"],
        "varsityJacket":    ["bomber", "denim_jacket", "varsity_jacket", "letterman_jacket"],
        "trench":           ["trench", "overcoat", "trench_coat"],
        "parka":            ["overcoat", "puffer", "parka", "anorak"],
        "bomber":           ["bomber", "bomber_jacket", "ma1"],
        "puffer":           ["puffer", "puffer_jacket", "down_jacket"],

        // MARK: Accessories — usually optional slots, kept for completeness
        "baseballCap":      ["hat", "baseball_cap", "cap", "ballcap"],
        "beanie":           ["hat", "beanie", "knit_hat"],
        "fedoraHat":        ["hat", "fedora", "fedora_hat", "wide_brim_hat"],
        "scarf":            ["scarf", "wool_scarf"],
        "belt":             ["belt", "leather_belt"]
        // watch, sunglasses, necklace, bracelet, bag, backpack, earrings —
        // no rule references in rules.json, so no aliases needed.
    ]

    /// True when the wardrobe item's subcategory satisfies a rule's
    /// required subcategory string.
    ///
    /// Identity match always wins (so newly added snake_case enum cases
    /// like `sneakerLow = "sneaker_low"` work without an alias entry).
    /// Falls back to the alias map for camelCase → snake_case bridging.
    static func matches(itemSubcategory: String, requiredSubcategory: String) -> Bool {
        if itemSubcategory == requiredSubcategory { return true }
        return itemMatches[itemSubcategory]?.contains(requiredSubcategory) ?? false
    }
}
