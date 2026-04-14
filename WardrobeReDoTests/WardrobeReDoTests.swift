import Testing
@testable import WardrobeReDo

@Test func clothingSubcategoryBelongsToCorrectCategory() {
    let tshirt = ClothingSubcategory.tshirt
    #expect(tshirt.category == .top)

    let jeans = ClothingSubcategory.jeans
    #expect(jeans.category == .bottom)

    let sneakers = ClothingSubcategory.sneakers
    #expect(sneakers.category == .shoe)
}

@Test func subcategoriesFilterByCategory() {
    let tops = ClothingSubcategory.subcategories(for: .top)
    #expect(tops.contains(.tshirt))
    #expect(!tops.contains(.jeans))
}
