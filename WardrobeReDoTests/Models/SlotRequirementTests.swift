import Testing
@testable import WardrobeReDo

// MARK: - SlotRequirement Tests

@Test func slotRequirementIsRequiredFlag() {
    let required = SlotRequirement(category: "top", subcategories: nil, isRequired: true)
    #expect(required.isRequired == true)

    let optional = SlotRequirement(category: "shoe", subcategories: nil, isRequired: false)
    #expect(optional.isRequired == false)
}

@Test func slotRequirementNilSubcategoriesMeansAnyMatch() {
    let slot = SlotRequirement(category: "top", subcategories: nil, isRequired: true)
    #expect(slot.subcategories == nil)

    let restricted = SlotRequirement(category: "top", subcategories: ["tshirt", "polo"], isRequired: true)
    #expect(restricted.subcategories?.count == 2)
    #expect(restricted.subcategories?.contains("tshirt") == true)
}
