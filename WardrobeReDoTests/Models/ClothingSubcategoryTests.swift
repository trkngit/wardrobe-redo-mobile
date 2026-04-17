import Testing
@testable import WardrobeReDo

// MARK: - ClothingSubcategory Tests

@Test func subcategoryCategoryMappingForTops() {
    let tops: [ClothingSubcategory] = [.tshirt, .buttonDown, .polo, .blazer, .hoodie, .sweater,
                                        .tankTop, .henley, .cropTop, .blouse, .turtleneck, .vneck, .graphicTee,
                                        .dressShirt, .knitSweater, .sweatshirt, .camisole, .tank]
    for sub in tops {
        #expect(sub.category == .top, "Expected \(sub) to be .top but got \(sub.category)")
    }
}

@Test func subcategoryCategoryMappingForBottoms() {
    let bottoms: [ClothingSubcategory] = [.jeans, .chinos, .dressPants, .shorts, .cargo, .joggers,
                                           .skirt, .miniSkirt, .midiSkirt, .wideLeg, .straightLeg, .slimFit,
                                           .leggings, .pencilSkirt]
    for sub in bottoms {
        #expect(sub.category == .bottom, "Expected \(sub) to be .bottom but got \(sub.category)")
    }
}

@Test func subcategoryCategoryMappingForShoes() {
    let shoes: [ClothingSubcategory] = [.sneakers, .dressShoes, .boots, .sandals, .loafers,
                                         .highTops, .heels, .flats, .designerSneakers, .chelseaBoots,
                                         .sneakerLow, .sneakerHigh, .runningShoe, .oxford, .derby, .balletFlat]
    for sub in shoes {
        #expect(sub.category == .shoe, "Expected \(sub) to be .shoe but got \(sub.category)")
    }
}

@Test func subcategoryCategoryMappingForDresses() {
    let dresses: [ClothingSubcategory] = [.casualDress, .cocktailDress, .maxiDress, .miniDress,
                                           .shirtDress, .wrapDress,
                                           .midiDress, .sundress, .slipDress, .sheathDress]
    for sub in dresses {
        #expect(sub.category == .dress, "Expected \(sub) to be .dress but got \(sub.category)")
    }
}

@Test func subcategoryCategoryMappingForOuterwear() {
    let outerwear: [ClothingSubcategory] = [.winterCoat, .leatherJacket, .denimJacket, .windbreaker,
                                             .cardigan, .varsityJacket, .trench, .parka, .bomber, .puffer,
                                             .suitJacket, .overcoat, .shirtJacket]
    for sub in outerwear {
        #expect(sub.category == .outerwear, "Expected \(sub) to be .outerwear but got \(sub.category)")
    }
}

@Test func subcategoryCategoryMappingForAccessories() {
    let accessories: [ClothingSubcategory] = [.baseballCap, .beanie, .scarf, .belt, .watch,
                                               .sunglasses, .necklace, .bracelet, .bag, .backpack,
                                               .fedoraHat, .earrings, .hat]
    for sub in accessories {
        #expect(sub.category == .accessory, "Expected \(sub) to be .accessory but got \(sub.category)")
    }
}

/// Counts reflect the post-expansion enum. Tops/bottoms/shoes/outerwear
/// gained snake_case rawValue cases (`dress_shirt`, `sneaker_low`, etc.)
/// to match the fine-grained vocabulary in `rules.json`. If you add a
/// new case, bump the count here too — the bundled rules may want it.
@Test func subcategoriesFilterReturnsCorrectCounts() {
    let tops = ClothingSubcategory.subcategories(for: .top)
    #expect(tops.count == 18)
    #expect(tops.contains(.tshirt))
    #expect(tops.contains(.dressShirt))
    #expect(!tops.contains(.jeans))
    #expect(!tops.contains(.sneakers))

    let bottoms = ClothingSubcategory.subcategories(for: .bottom)
    #expect(bottoms.count == 14)
    #expect(bottoms.contains(.pencilSkirt))

    let shoes = ClothingSubcategory.subcategories(for: .shoe)
    #expect(shoes.count == 16)
    #expect(shoes.contains(.sneakerLow))
    #expect(shoes.contains(.oxford))

    let dresses = ClothingSubcategory.subcategories(for: .dress)
    #expect(dresses.count == 10)
    #expect(dresses.contains(.midiDress))

    let outerwear = ClothingSubcategory.subcategories(for: .outerwear)
    #expect(outerwear.count == 13)
    #expect(outerwear.contains(.suitJacket))

    let accessories = ClothingSubcategory.subcategories(for: .accessory)
    #expect(accessories.count == 13)
    #expect(accessories.contains(.hat))
}

@Test func allSubcategoryDisplayNamesAreNonEmpty() {
    for sub in ClothingSubcategory.allCases {
        #expect(!sub.displayName.isEmpty, "\(sub) has empty displayName")
    }
}
