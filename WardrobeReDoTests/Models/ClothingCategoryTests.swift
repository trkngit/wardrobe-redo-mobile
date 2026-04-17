import Testing
@testable import WardrobeReDo

// MARK: - ClothingCategory Tests

@Test func clothingCategoryHasSixCases() {
    #expect(ClothingCategory.allCases.count == 6)
}

@Test func clothingCategoryDisplayNames() {
    #expect(ClothingCategory.top.displayName == "Tops")
    #expect(ClothingCategory.bottom.displayName == "Bottoms")
    #expect(ClothingCategory.shoe.displayName == "Shoes")
    #expect(ClothingCategory.dress.displayName == "Dresses")
    #expect(ClothingCategory.outerwear.displayName == "Outerwear")
    #expect(ClothingCategory.accessory.displayName == "Accessories")
}

@Test func clothingCategoryIconNames() {
    #expect(ClothingCategory.top.iconName == "tshirt")
    #expect(ClothingCategory.bottom.iconName == "figure.walk")
    #expect(ClothingCategory.shoe.iconName == "shoe")
    #expect(ClothingCategory.dress.iconName == "figure.dress.line.vertical.figure")
    #expect(ClothingCategory.outerwear.iconName == "cloud.rain")
    #expect(ClothingCategory.accessory.iconName == "applewatch")
}

@Test func clothingCategoryRawValuesAreUnique() {
    let rawValues = ClothingCategory.allCases.map(\.rawValue)
    #expect(Set(rawValues).count == rawValues.count)
}
