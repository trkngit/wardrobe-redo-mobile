import Foundation

/// Pattern-match clauses that power `AttributeRulesEngine.derive`.
///
/// This file is the Swift translation of
/// `docs/plans/2026-04-19-auto-attribute-detection/RULES_TABLE.md` —
/// reviewer-facing rules live in the markdown; the compiler-checked
/// version lives here. When editing, update both files together.
///
/// Reading these switches:
///   - `(ClothingCategory, ClothingSubcategory, TextureType?)` — third
///     element is optional because the attribute classifier may not have
///     cleared the confidence threshold for texture.
///   - `.silk?` is pattern-match sugar for `.some(.silk)` on the
///     optional texture.
///   - `_` in the texture slot matches both nil and any concrete value.
///   - First-match wins. The ordering follows the numbered rules in
///     `RULES_TABLE.md`, from most specific to least specific.
enum RulesTable {
    // MARK: - Seasons

    static func seasons(
        for category: ClothingCategory,
        subcategory: ClothingSubcategory,
        texture: TextureType?
    ) -> Set<Season> {
        switch (category, subcategory, texture) {

        // MARK: Shoe rules

        // 1. sandals → summer only
        case (.shoe, .sandals, _):
            return [.summer]

        // 2-5. closed-toe boots → fall/winter
        case (.shoe, .boots, _), (.shoe, .chelseaBoots, _):
            return [.fall, .winter]

        // 6. dress footwear → year-round (worn indoors)
        case (.shoe, .heels, _), (.shoe, .flats, _), (.shoe, .loafers, _),
             (.shoe, .oxford, _), (.shoe, .derby, _), (.shoe, .balletFlat, _),
             (.shoe, .dressShoes, _):
            return Set(Season.allCases)

        // 7. sneakers → spring/summer/fall (cold-weather feet need boots)
        case (.shoe, .sneakers, _), (.shoe, .sneakerLow, _), (.shoe, .sneakerHigh, _),
             (.shoe, .highTops, _), (.shoe, .designerSneakers, _), (.shoe, .runningShoe, _):
            return [.spring, .summer, .fall]

        // MARK: Outerwear rules

        // 10. heavy winter coats
        case (.outerwear, .puffer, _), (.outerwear, .parka, _),
             (.outerwear, .winterCoat, _), (.outerwear, .overcoat, _):
            return [.winter]

        // 11-13. shoulder-season jackets
        case (.outerwear, .leatherJacket, _), (.outerwear, .suitJacket, _),
             (.outerwear, .denimJacket, _), (.outerwear, .bomber, _),
             (.outerwear, .varsityJacket, _), (.outerwear, .shirtJacket, _),
             (.outerwear, .windbreaker, _), (.outerwear, .trench, _):
            return [.spring, .fall]

        // 14. heavy-knit cardigans
        case (.outerwear, .cardigan, .wool?), (.outerwear, .cardigan, .knit?):
            return [.fall, .winter]

        // 15-16. lighter cardigans (covers cotton/linen/silk and the
        // "texture unknown" fallback).
        case (.outerwear, .cardigan, _):
            return [.spring, .fall]

        // 17-18. material-driven winter outerwear
        case (.outerwear, _, .wool?), (.outerwear, _, .tweed?),
             (.outerwear, _, .leather?), (.outerwear, _, .suede?):
            return [.fall, .winter]

        // 19. outerwear default — anything except summer
        case (.outerwear, _, _):
            return [.spring, .fall, .winter]

        // MARK: Dress rules

        // 20. hot-weather dress silhouettes
        case (.dress, .sundress, _), (.dress, .maxiDress, _),
             (.dress, .miniDress, _), (.dress, .wrapDress, _):
            return [.spring, .summer]

        // 21. lightweight fabric dresses
        case (.dress, _, .silk?), (.dress, _, .chiffon?), (.dress, _, .satin?),
             (.dress, _, .linen?), (.dress, _, .cotton?):
            return [.spring, .summer]

        // 22-23. heavy fabric dresses
        case (.dress, _, .wool?), (.dress, _, .tweed?), (.dress, _, .velvet?),
             (.dress, _, .knit?), (.dress, _, .leather?), (.dress, _, .suede?):
            return [.fall, .winter]

        // 24-25. dress defaults (cocktail/sheath + anything else) → year-round
        case (.dress, _, _):
            return Set(Season.allCases)

        // MARK: Top rules

        // 30. summer-only tops
        case (.top, .tankTop, _), (.top, .tank, _),
             (.top, .camisole, _), (.top, .cropTop, _):
            return [.spring, .summer]

        // 31. insulating tops
        case (.top, .sweatshirt, _), (.top, .sweater, _),
             (.top, .knitSweater, _), (.top, .hoodie, _),
             (.top, .turtleneck, _):
            return [.fall, .winter]

        // 32. heavy fabric tops
        case (.top, _, .wool?), (.top, _, .tweed?),
             (.top, _, .velvet?), (.top, _, .knit?):
            return [.fall, .winter]

        // 33. lightweight fabric tops
        case (.top, _, .linen?), (.top, _, .silk?), (.top, _, .chiffon?):
            return [.spring, .summer]

        // 34. top default → all seasons
        case (.top, _, _):
            return Set(Season.allCases)

        // MARK: Bottom rules

        // 40. summer-only bottoms
        case (.bottom, .shorts, _), (.bottom, .miniSkirt, _):
            return [.spring, .summer]

        // 41. athleisure — year-round
        case (.bottom, .leggings, _), (.bottom, .joggers, _):
            return Set(Season.allCases)

        // 42. lightweight fabric bottoms
        case (.bottom, _, .linen?), (.bottom, _, .silk?), (.bottom, _, .chiffon?):
            return [.spring, .summer]

        // 43-44. heavy fabric bottoms
        case (.bottom, _, .wool?), (.bottom, _, .tweed?),
             (.bottom, _, .corduroy?), (.bottom, _, .velvet?),
             (.bottom, _, .leather?), (.bottom, _, .suede?):
            return [.fall, .winter]

        // 45-46. denim + bottom default → year-round
        case (.bottom, _, _):
            return Set(Season.allCases)

        // MARK: Accessory rules

        // 50. cold-weather accessories
        case (.accessory, .scarf, _), (.accessory, .beanie, _):
            return [.fall, .winter]

        // 51. sun-protection accessories
        case (.accessory, .sunglasses, _):
            return [.spring, .summer]

        // 52. sun-facing hats
        case (.accessory, .baseballCap, _), (.accessory, .hat, _),
             (.accessory, .fedoraHat, _):
            return [.spring, .summer, .fall]

        // 53. accessory default → year-round
        case (.accessory, _, _):
            return Set(Season.allCases)

        // Unreachable in practice (every ClothingSubcategory belongs to one
        // ClothingCategory via its `.category` property, and each category
        // has a catch-all above), but Swift's exhaustiveness check treats
        // (Category, Subcategory) as a free product — so cross-category
        // combos like (.shoe, .fedoraHat, _) are considered reachable.
        // Non-empty invariant preserved by falling back to all seasons.
        default:
            return Set(Season.allCases)
        }
    }

    // MARK: - Occasions

    static func occasions(
        for category: ClothingCategory,
        subcategory: ClothingSubcategory,
        texture: TextureType?
    ) -> Set<Occasion> {
        switch (category, subcategory, texture) {

        // MARK: Formal / work skew

        // 100. dressy-fabric tops
        case (.top, _, .silk?), (.top, _, .satin?), (.top, _, .chiffon?):
            return [.work, .date, .formal]

        // 101. dress bottoms
        case (.bottom, .dressPants, _), (.bottom, .pencilSkirt, _):
            return [.work, .formal]

        // 102. dress shoes
        case (.shoe, .heels, _), (.shoe, .dressShoes, _),
             (.shoe, .oxford, _), (.shoe, .derby, _), (.shoe, .loafers, _):
            return [.work, .date, .formal]

        // 103. formal outerwear
        case (.outerwear, .suitJacket, _), (.outerwear, .trench, _),
             (.outerwear, .overcoat, _):
            return [.work, .formal]

        // 104. formal dresses
        case (.dress, .cocktailDress, _), (.dress, .sheathDress, _):
            return [.work, .date, .formal]

        // 105. wool/tweed tops — dressy-casual
        case (.top, _, .wool?), (.top, _, .tweed?):
            return [.casual, .work, .date]

        // MARK: Athletic

        // 110. athleisure bottoms
        case (.bottom, .joggers, _), (.bottom, .leggings, _):
            return [.casual, .athletic, .lounge]

        // 111. athletic footwear
        case (.shoe, .sneakers, _), (.shoe, .sneakerLow, _), (.shoe, .sneakerHigh, _),
             (.shoe, .highTops, _), (.shoe, .runningShoe, _), (.shoe, .designerSneakers, _):
            return [.casual, .athletic]

        // 112. performance fabric tops
        case (.top, _, .synthetic?), (.top, _, .nylon?):
            return [.casual, .athletic]

        // MARK: Lounge

        // 120. lounge-leaning tops
        case (.top, .sweatshirt, _), (.top, .hoodie, _):
            return [.casual, .athletic, .lounge]

        // MARK: Casual defaults

        // 130. basic tops → casual
        case (.top, .tshirt, _), (.top, .tankTop, _), (.top, .tank, _),
             (.top, .camisole, _), (.top, .cropTop, _), (.top, .graphicTee, _),
             (.top, .henley, _), (.top, .polo, _):
            return [.casual]

        // 131. casual bottoms
        case (.bottom, .jeans, _), (.bottom, .shorts, _),
             (.bottom, .cargo, _), (.bottom, .chinos, _):
            return [.casual, .date]

        // 132. sandals → casual only
        case (.shoe, .sandals, _):
            return [.casual]

        // 133. casual outerwear
        case (.outerwear, .denimJacket, _), (.outerwear, .bomber, _),
             (.outerwear, .varsityJacket, _), (.outerwear, .shirtJacket, _):
            return [.casual, .date]

        // 134. casual dresses
        case (.dress, .sundress, _), (.dress, .casualDress, _):
            return [.casual, .date]

        // 135. accessories — don't narrow occasion
        case (.accessory, _, _):
            return [.casual, .work, .date, .formal]

        // MARK: Fallback (matches the non-empty invariant)

        // 199. default → casual
        default:
            return [.casual]
        }
    }
}
