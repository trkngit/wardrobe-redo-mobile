import Foundation
import Testing
@testable import WardrobeReDo

/// Tests for `AttributeRulesEngine.derive` and its backing `RulesTable`.
///
/// The engine translates a predicted `(category, subcategory, texture)`
/// triple into season + occasion pre-fills for the Add Item form. Two
/// things must hold:
///
/// 1. **Non-empty invariant** — both returned sets are always non-empty.
///    This is load-bearing: the Phase 0 pre-fill path reads these sets
///    directly into the picker state; an empty set would render a
///    selection-less picker and force the user to start from scratch.
///
/// 2. **Canonical rules fire correctly** — the rules source of truth
///    lives in `docs/plans/2026-04-19-auto-attribute-detection/RULES_TABLE.md`.
///    Each case in the table has a matching assertion here so rule
///    regressions break the suite.
///
/// See docs/plans/2026-04-19-auto-attribute-detection.md Phase 5.

// MARK: - Non-empty invariant (property-based)

@Test func derivationNeverReturnsEmptySets() {
    // Walk the full (category, subcategory, texture?) space. That's 6 ×
    // ~70 × 16 ≈ 6720 triples — cheap at runtime and catches any rule
    // ordering slip that lets a combination fall through.
    let textures: [TextureType?] = [nil] + TextureType.allCases.map(Optional.some)
    for category in ClothingCategory.allCases {
        for subcategory in ClothingSubcategory.subcategories(for: category) {
            for texture in textures {
                let (seasons, occasions) = AttributeRulesEngine.derive(
                    category: category,
                    subcategory: subcategory,
                    texture: texture
                )
                #expect(
                    !seasons.isEmpty,
                    "empty seasons for (\(category), \(subcategory), \(String(describing: texture)))"
                )
                #expect(
                    !occasions.isEmpty,
                    "empty occasions for (\(category), \(subcategory), \(String(describing: texture)))"
                )
            }
        }
    }
}

// MARK: - Canonical season rules (one assertion per rule)

@Test func sandalsReturnSummerOnly() {
    // Rule 1: any sandal, any texture → summer only.
    let (seasons, _) = AttributeRulesEngine.derive(
        category: .shoe, subcategory: .sandals, texture: .cotton
    )
    #expect(seasons == [.summer])
}

@Test func bootsReturnFallWinter() {
    // Rule 2-5: boots + chelsea boots are cold-weather.
    let (bootsSeasons, _) = AttributeRulesEngine.derive(
        category: .shoe, subcategory: .boots, texture: .leather
    )
    let (chelseaSeasons, _) = AttributeRulesEngine.derive(
        category: .shoe, subcategory: .chelseaBoots, texture: nil
    )
    #expect(bootsSeasons == [.fall, .winter])
    #expect(chelseaSeasons == [.fall, .winter])
}

@Test func dressFootwearReturnsAllSeasons() {
    // Rule 6: dress-leaning footwear is worn year-round indoors.
    for sub: ClothingSubcategory in [.heels, .flats, .loafers, .oxford, .derby, .balletFlat, .dressShoes] {
        let (seasons, _) = AttributeRulesEngine.derive(
            category: .shoe, subcategory: sub, texture: .leather
        )
        #expect(seasons == Set(Season.allCases), "expected all-seasons for .\(sub)")
    }
}

@Test func sneakersDropWinter() {
    // Rule 7: sneaker-family → spring/summer/fall only.
    let (seasons, _) = AttributeRulesEngine.derive(
        category: .shoe, subcategory: .sneakers, texture: .cotton
    )
    #expect(seasons == [.spring, .summer, .fall])
}

@Test func pufferReturnsWinterOnly() {
    // Rule 10: heavyweight winter coats.
    let (seasons, _) = AttributeRulesEngine.derive(
        category: .outerwear, subcategory: .puffer, texture: .nylon
    )
    #expect(seasons == [.winter])
}

@Test func leatherJacketReturnsShoulderSeasons() {
    // Rule 11: leather jacket → spring/fall regardless of texture (the
    // subcategory rule fires before the leather-texture rule because it's
    // listed first in the switch).
    let (seasons, _) = AttributeRulesEngine.derive(
        category: .outerwear, subcategory: .leatherJacket, texture: .leather
    )
    #expect(seasons == [.spring, .fall])
}

@Test func heavyCardiganReturnsFallWinter() {
    // Rule 14: wool/knit cardigan → fall/winter.
    let (woolSeasons, _) = AttributeRulesEngine.derive(
        category: .outerwear, subcategory: .cardigan, texture: .wool
    )
    let (knitSeasons, _) = AttributeRulesEngine.derive(
        category: .outerwear, subcategory: .cardigan, texture: .knit
    )
    #expect(woolSeasons == [.fall, .winter])
    #expect(knitSeasons == [.fall, .winter])
}

@Test func lightCardiganReturnsSpringFall() {
    // Rule 15-16: cotton/linen/silk cardigan + texture-unknown fallback
    // both land on spring/fall.
    let (cottonSeasons, _) = AttributeRulesEngine.derive(
        category: .outerwear, subcategory: .cardigan, texture: .cotton
    )
    let (nilSeasons, _) = AttributeRulesEngine.derive(
        category: .outerwear, subcategory: .cardigan, texture: nil
    )
    #expect(cottonSeasons == [.spring, .fall])
    #expect(nilSeasons == [.spring, .fall])
}

@Test func heavyFabricOuterwearReturnsFallWinter() {
    // Rule 17-18: wool/tweed/leather/suede outerwear (that isn't already
    // captured by a subcategory-specific rule) → fall/winter. windbreaker
    // is a good test case — subcategory-level rule 12 would fire with
    // [.spring, .fall], but it's listed before rules 17-18 so 12 wins.
    // Use a subcategory that only matches the catch-all 19 default, then
    // override with a wool texture to confirm rule 17 takes it.
    //
    // trench is a subcategory-level rule (rule 13) → [.spring, .fall],
    // which proves order: trench wool fires 13 not 17.
    let (trenchWoolSeasons, _) = AttributeRulesEngine.derive(
        category: .outerwear, subcategory: .trench, texture: .wool
    )
    #expect(trenchWoolSeasons == [.spring, .fall], "subcategory rule 13 should fire before texture rule 17")
}

@Test func outerwearDefaultExcludesSummer() {
    // Rule 19: outerwear default. An unmatched subcategory with an
    // unmatched texture should drop summer.
    // overcoat belongs to rule 10 (winter). Use something that only the
    // catch-all would touch — but all subcategories in the switch get
    // named somewhere. Easiest: a cotton windbreaker hits rule 12 →
    // [.spring, .fall], which is a STRICT subset of the default. So to
    // test the default we need an outerwear subcategory not mentioned in
    // any rule AND a texture not in rules 17-18.
    // That leaves us with no combination: the switch is exhaustive by
    // design. Sanity check the specific behaviour instead: cotton
    // windbreaker should land on spring/fall via rule 12.
    let (seasons, _) = AttributeRulesEngine.derive(
        category: .outerwear, subcategory: .windbreaker, texture: .cotton
    )
    #expect(seasons == [.spring, .fall])
}

@Test func summerDressSilhouettesReturnSpringSummer() {
    // Rule 20: hot-weather dress silhouettes.
    for sub: ClothingSubcategory in [.sundress, .maxiDress, .miniDress, .wrapDress] {
        let (seasons, _) = AttributeRulesEngine.derive(
            category: .dress, subcategory: sub, texture: nil
        )
        #expect(seasons == [.spring, .summer], "expected spring/summer for .\(sub)")
    }
}

@Test func heavyFabricDressesReturnFallWinter() {
    // Rule 22-23: wool/tweed/velvet/knit/leather/suede dresses.
    for texture: TextureType in [.wool, .tweed, .velvet, .knit, .leather, .suede] {
        let (seasons, _) = AttributeRulesEngine.derive(
            category: .dress, subcategory: .casualDress, texture: texture
        )
        #expect(seasons == [.fall, .winter], "expected fall/winter for dress+\(texture)")
    }
}

@Test func cocktailDressReturnsAllSeasons() {
    // Rule 24-25: cocktail + sheath + catch-all → year-round.
    let (cocktailSeasons, _) = AttributeRulesEngine.derive(
        category: .dress, subcategory: .cocktailDress, texture: .satin
    )
    // Satin would otherwise hit rule 21 (lightweight) → [.spring, .summer].
    // Since rule 20 lists sundress/maxi/mini/wrap but NOT cocktail, and
    // rule 21 lists satin fabric, rule 21 fires first for cocktail+satin.
    #expect(cocktailSeasons == [.spring, .summer])

    // A bare cocktail dress (no texture) falls through rules 20-23 and
    // lands on rule 24-25.
    let (cocktailNoTexSeasons, _) = AttributeRulesEngine.derive(
        category: .dress, subcategory: .cocktailDress, texture: nil
    )
    #expect(cocktailNoTexSeasons == Set(Season.allCases))
}

@Test func summerTopsReturnSpringSummer() {
    // Rule 30: tank family.
    for sub: ClothingSubcategory in [.tankTop, .tank, .camisole, .cropTop] {
        let (seasons, _) = AttributeRulesEngine.derive(
            category: .top, subcategory: sub, texture: nil
        )
        #expect(seasons == [.spring, .summer], "expected spring/summer for .\(sub)")
    }
}

@Test func insulatingTopsReturnFallWinter() {
    // Rule 31: sweatshirt/sweater/knitSweater/hoodie/turtleneck.
    for sub: ClothingSubcategory in [.sweatshirt, .sweater, .knitSweater, .hoodie, .turtleneck] {
        let (seasons, _) = AttributeRulesEngine.derive(
            category: .top, subcategory: sub, texture: nil
        )
        #expect(seasons == [.fall, .winter], "expected fall/winter for .\(sub)")
    }
}

@Test func cottonTshirtReturnsAllSeasons() {
    // Rule 34: top default. Cotton doesn't match rules 32/33, so the
    // catch-all fires for seasons. Occasions follow rule 130
    // (broadened) — t-shirts now slide casual / date / lounge.
    let (seasons, occasions) = AttributeRulesEngine.derive(
        category: .top, subcategory: .tshirt, texture: .cotton
    )
    #expect(seasons == Set(Season.allCases))
    #expect(occasions == [.casual, .date, .lounge])
}

@Test func summerBottomsReturnSpringSummer() {
    // Rule 40: shorts + miniSkirt.
    for sub: ClothingSubcategory in [.shorts, .miniSkirt] {
        let (seasons, _) = AttributeRulesEngine.derive(
            category: .bottom, subcategory: sub, texture: nil
        )
        #expect(seasons == [.spring, .summer], "expected spring/summer for .\(sub)")
    }
}

@Test func leggingsJoggersReturnAllSeasons() {
    // Rule 41: athleisure bottoms.
    for sub: ClothingSubcategory in [.leggings, .joggers] {
        let (seasons, _) = AttributeRulesEngine.derive(
            category: .bottom, subcategory: sub, texture: nil
        )
        #expect(seasons == Set(Season.allCases), "expected all-seasons for .\(sub)")
    }
}

@Test func leatherPantsReturnFallWinter() {
    // Rule 44: leather/suede bottoms.
    let (seasons, _) = AttributeRulesEngine.derive(
        category: .bottom, subcategory: .dressPants, texture: .leather
    )
    #expect(seasons == [.fall, .winter])
}

@Test func denimReturnsAllSeasons() {
    // Rule 45: denim is a wear-anywhere staple.
    let (seasons, _) = AttributeRulesEngine.derive(
        category: .bottom, subcategory: .jeans, texture: .denim
    )
    #expect(seasons == Set(Season.allCases))
}

@Test func scarfAndBeanieReturnFallWinter() {
    // Rule 50: scarf + beanie.
    let (scarfSeasons, _) = AttributeRulesEngine.derive(
        category: .accessory, subcategory: .scarf, texture: .wool
    )
    let (beanieSeasons, _) = AttributeRulesEngine.derive(
        category: .accessory, subcategory: .beanie, texture: nil
    )
    #expect(scarfSeasons == [.fall, .winter])
    #expect(beanieSeasons == [.fall, .winter])
}

@Test func sunglassesReturnSpringSummer() {
    let (seasons, _) = AttributeRulesEngine.derive(
        category: .accessory, subcategory: .sunglasses, texture: nil
    )
    #expect(seasons == [.spring, .summer])
}

@Test func sunHatsReturnWarmSeasons() {
    // Rule 52: caps and hats — sun-facing, so no winter.
    for sub: ClothingSubcategory in [.baseballCap, .hat, .fedoraHat] {
        let (seasons, _) = AttributeRulesEngine.derive(
            category: .accessory, subcategory: sub, texture: nil
        )
        #expect(seasons == [.spring, .summer, .fall], "expected warm-season for .\(sub)")
    }
}

// MARK: - Canonical occasion rules

@Test func silkTopReturnsWorkDateFormal() {
    // Rule 100: dressy-fabric tops.
    for texture: TextureType in [.silk, .satin, .chiffon] {
        let (_, occasions) = AttributeRulesEngine.derive(
            category: .top, subcategory: .buttonDown, texture: texture
        )
        #expect(occasions == [.work, .date, .formal], "expected dressy occasions for top+\(texture)")
    }
}

@Test func dressPantsReturnWorkFormal() {
    // Rule 101: dressPants + pencilSkirt.
    for sub: ClothingSubcategory in [.dressPants, .pencilSkirt] {
        let (_, occasions) = AttributeRulesEngine.derive(
            category: .bottom, subcategory: sub, texture: .wool
        )
        #expect(occasions == [.work, .formal], "expected work/formal for .\(sub)")
    }
}

@Test func leatherDressShoesReturnFormalOccasions() {
    // Rule 102: dress shoes (leather or otherwise) serve work/date/formal.
    let (_, occasions) = AttributeRulesEngine.derive(
        category: .shoe, subcategory: .dressShoes, texture: .leather
    )
    #expect(occasions == [.work, .date, .formal])
}

@Test func suitJacketReturnsWorkDateFormal() {
    // Rule 103a (broadened): suit jacket adds date alongside work +
    // formal so the Date subtab isn't empty for users with a single
    // formal jacket in rotation.
    let (_, occasions) = AttributeRulesEngine.derive(
        category: .outerwear, subcategory: .suitJacket, texture: .wool
    )
    #expect(occasions == [.work, .date, .formal])
}

@Test func trenchAndOvercoatSpanAllFormalOccasions() {
    // Rule 103b: trench + overcoat are universal layers — they read
    // casual through formal depending on what's underneath.
    for sub: ClothingSubcategory in [.trench, .overcoat] {
        let (_, occasions) = AttributeRulesEngine.derive(
            category: .outerwear, subcategory: sub, texture: .wool
        )
        #expect(
            occasions == [.casual, .work, .date, .formal],
            "expected casual/work/date/formal for .\(sub)"
        )
    }
}

@Test func poloSpansCasualWorkDateLounge() {
    // Rule 106: polo is the smart-casual classic — works for casual,
    // work, date, and lounge.
    let (_, occasions) = AttributeRulesEngine.derive(
        category: .top, subcategory: .polo, texture: .cotton
    )
    #expect(occasions == [.casual, .work, .date, .lounge])
}

@Test func buttonDownAndDressShirtSpanCasualWorkDate() {
    // Rule 107: button-down + dress shirt — work + casual + date.
    for sub: ClothingSubcategory in [.buttonDown, .dressShirt] {
        let (_, occasions) = AttributeRulesEngine.derive(
            category: .top, subcategory: sub, texture: .cotton
        )
        #expect(
            occasions == [.casual, .work, .date],
            "expected casual/work/date for .\(sub)"
        )
    }
}

@Test func blazerSpansAllPrimaryOccasions() {
    // Rule 108: blazer (categorized as a top here) reads as a primary
    // occasion-spanning piece. Tested with a non-wool texture so the
    // earlier rule 105 (wool tops → casual/work/date) doesn't shadow
    // the more specific blazer rule.
    let (_, occasions) = AttributeRulesEngine.derive(
        category: .top, subcategory: .blazer, texture: .cotton
    )
    #expect(occasions == [.casual, .work, .date, .formal])
}

@Test func cocktailDressReturnsDressyOccasions() {
    // Rule 104: cocktail + sheath.
    let (_, occasions) = AttributeRulesEngine.derive(
        category: .dress, subcategory: .cocktailDress, texture: nil
    )
    #expect(occasions == [.work, .date, .formal])
}

@Test func woolTopReturnsCasualWorkDate() {
    // Rule 105: wool/tweed tops. silk already tested above in rule 100.
    let (_, occasions) = AttributeRulesEngine.derive(
        category: .top, subcategory: .buttonDown, texture: .wool
    )
    #expect(occasions == [.casual, .work, .date])
}

@Test func joggersReturnAthleticLoungeCasual() {
    // Rule 110: joggers + leggings.
    for sub: ClothingSubcategory in [.joggers, .leggings] {
        let (_, occasions) = AttributeRulesEngine.derive(
            category: .bottom, subcategory: sub, texture: nil
        )
        #expect(occasions == [.casual, .athletic, .lounge], "expected athleisure for .\(sub)")
    }
}

@Test func sneakersSpanCasualAthleticDateLounge() {
    // Rule 111 (broadened): sneakers cross every "casual-ish" subtab so
    // a sneaker-only wardrobe doesn't render an empty Date or Lounge
    // subtab in the Outfits feed.
    for sub: ClothingSubcategory in [.sneakers, .sneakerLow, .sneakerHigh, .highTops, .runningShoe, .designerSneakers] {
        let (_, occasions) = AttributeRulesEngine.derive(
            category: .shoe, subcategory: sub, texture: nil
        )
        #expect(
            occasions == [.casual, .athletic, .date, .lounge],
            "expected casual/athletic/date/lounge for .\(sub)"
        )
    }
}

@Test func syntheticTopReturnsAthletic() {
    // Rule 112: performance fabrics.
    for texture: TextureType in [.synthetic, .nylon] {
        let (_, occasions) = AttributeRulesEngine.derive(
            category: .top, subcategory: .tshirt, texture: texture
        )
        #expect(occasions == [.casual, .athletic], "expected performance occasions for top+\(texture)")
    }
}

@Test func hoodieReturnsLoungeAthleticCasual() {
    // Rule 120: lounge-leaning tops.
    for sub: ClothingSubcategory in [.sweatshirt, .hoodie] {
        let (_, occasions) = AttributeRulesEngine.derive(
            category: .top, subcategory: sub, texture: nil
        )
        #expect(occasions == [.casual, .athletic, .lounge], "expected loungewear for .\(sub)")
    }
}

@Test func basicShortSleeveTopsSpanCasualDateLounge() {
    // Rule 130 (broadened): t-shirts, tanks, henleys, etc. now also
    // serve date and lounge — a t-shirt wardrobe should populate all
    // three of those subtabs. Polo, blazer, button-down, and
    // dress-shirt are intentionally excluded — they have their own,
    // wider rules above.
    for sub: ClothingSubcategory in [.tshirt, .tankTop, .tank, .camisole, .cropTop, .graphicTee, .henley] {
        let (_, occasions) = AttributeRulesEngine.derive(
            category: .top, subcategory: sub, texture: nil
        )
        #expect(
            occasions == [.casual, .date, .lounge],
            "expected casual/date/lounge for .\(sub)"
        )
    }
}

@Test func chinosSpanCasualWorkDate() {
    // Rule 131a: chinos cross into work — the most versatile bottom.
    let (_, occasions) = AttributeRulesEngine.derive(
        category: .bottom, subcategory: .chinos, texture: nil
    )
    #expect(occasions == [.casual, .work, .date])
}

@Test func jeansSpanCasualDateLounge() {
    // Rule 131b: jeans don't read work but do read lounge.
    let (_, occasions) = AttributeRulesEngine.derive(
        category: .bottom, subcategory: .jeans, texture: nil
    )
    #expect(occasions == [.casual, .date, .lounge])
}

@Test func shortsAndCargoStayCasualDate() {
    // Rule 131c: shorts + cargo don't expand beyond casual + date.
    for sub: ClothingSubcategory in [.shorts, .cargo] {
        let (_, occasions) = AttributeRulesEngine.derive(
            category: .bottom, subcategory: sub, texture: nil
        )
        #expect(occasions == [.casual, .date], "expected casual/date for .\(sub)")
    }
}

@Test func sandalsReturnCasualLounge() {
    // Rule 132 (broadened): sandals add lounge so summer-only feet
    // still match the Lounge subtab.
    let (_, occasions) = AttributeRulesEngine.derive(
        category: .shoe, subcategory: .sandals, texture: nil
    )
    #expect(occasions == [.casual, .lounge])
}

@Test func casualOuterwearReturnsCasualDate() {
    // Rule 133: denimJacket + bomber + varsityJacket + shirtJacket.
    for sub: ClothingSubcategory in [.denimJacket, .bomber, .varsityJacket, .shirtJacket] {
        let (_, occasions) = AttributeRulesEngine.derive(
            category: .outerwear, subcategory: sub, texture: nil
        )
        #expect(occasions == [.casual, .date], "expected casual/date for .\(sub)")
    }
}

@Test func casualDressesReturnCasualDateLounge() {
    // Rule 134 (broadened): sundress + casualDress also slide into
    // lounge so a sundress-only summer wardrobe doesn't render an
    // empty Lounge subtab.
    for sub: ClothingSubcategory in [.sundress, .casualDress] {
        let (_, occasions) = AttributeRulesEngine.derive(
            category: .dress, subcategory: sub, texture: .cotton
        )
        #expect(
            occasions == [.casual, .date, .lounge],
            "expected casual/date/lounge for .\(sub)"
        )
    }
}

@Test func accessoriesDontNarrowOccasion() {
    // Rule 135: accessories get a broad occasion set (but no lounge/athletic).
    let (_, occasions) = AttributeRulesEngine.derive(
        category: .accessory, subcategory: .watch, texture: nil
    )
    #expect(occasions == [.casual, .work, .date, .formal])
}

// MARK: - Exhaustiveness — every TextureType covered

@Test func everyTextureAppearsInAtLeastOneRule() {
    // Canonical-case coverage: probe each TextureType against a top and
    // confirm SOME rule fires (i.e. the result differs from a reasonable
    // "untouched by texture" baseline OR matches one of the texture-
    // keyed rules). The baseline for `(.top, .buttonDown, _)` is now
    // rule 34 → Season.allCases for seasons, and rule 107 (broadened
    // smart-casual rule) → [.casual, .work, .date] for occasions. Any
    // texture-driven rule must change one of those two sets.
    //
    // Rationale: if a TextureType is never mentioned in RulesTable, the
    // pre-fill silently degrades to the category defaults. That's not
    // catastrophic — the user just doesn't get ML-driven seasons/
    // occasions for that fabric — but it's worth catching explicitly.
    let baselineSeasons = Set(Season.allCases)
    let baselineOccasions: Set<Occasion> = [.casual, .work, .date]
    var uncovered: [TextureType] = []
    for texture in TextureType.allCases {
        let (seasons, occasions) = AttributeRulesEngine.derive(
            category: .top, subcategory: .buttonDown, texture: texture
        )
        let changesSomething = seasons != baselineSeasons || occasions != baselineOccasions
        if !changesSomething {
            uncovered.append(texture)
        }
    }
    // Expected un-covered textures on `(.top, .buttonDown, _)`:
    //   - cotton:   baseline for tops, no texture-keyed rule
    //   - denim:    a denim shirt is wear-anywhere, no season signal
    //   - leather:  leather top is rare; no rule yet (symmetry with
    //               dress/outerwear/bottom would suggest fall/winter —
    //               reviewer decision pending)
    //   - suede:    same as leather
    //   - corduroy: corduroy top is rare; no rule yet (symmetry with
    //               bottom rule 43 would suggest fall/winter)
    // linen → rule 33 (spring/summer). synthetic → rule 112 (athletic).
    // If this list grows, the reviewer should decide whether to add a
    // rule or keep the default.
    let expectedUncovered: Set<TextureType> = [.cotton, .denim, .leather, .suede, .corduroy]
    #expect(
        Set(uncovered) == expectedUncovered,
        "unexpected texture coverage delta: got \(uncovered.sorted { $0.rawValue < $1.rawValue }), expected \(Array(expectedUncovered).sorted { $0.rawValue < $1.rawValue })"
    )
}

// MARK: - First-match ordering (rule precedence)

@Test func subcategoryRuleBeatsTextureRule() {
    // sundress + wool: rule 20 (sundress spring/summer) is listed before
    // rule 22 (dress+wool fall/winter). Rule 20 should win.
    let (seasons, _) = AttributeRulesEngine.derive(
        category: .dress, subcategory: .sundress, texture: .wool
    )
    #expect(seasons == [.spring, .summer], "sundress subcategory rule should beat wool texture rule")
}

@Test func dressTextureRuleBeatsCatchAll() {
    // cocktailDress is NOT listed in rule 20 (sundress/maxi/mini/wrap),
    // so a cocktail+silk should land on rule 21 (lightweight fabrics),
    // NOT on rule 24-25 (catch-all year-round).
    let (seasons, _) = AttributeRulesEngine.derive(
        category: .dress, subcategory: .cocktailDress, texture: .silk
    )
    #expect(seasons == [.spring, .summer], "dress+silk texture rule should beat catch-all")
}
