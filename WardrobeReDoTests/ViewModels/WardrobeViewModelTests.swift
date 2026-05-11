import Foundation
import Testing
@testable import WardrobeReDo

// MARK: - WardrobeViewModel Tests

@Test @MainActor func wardrobeFilteredItemsAllWhenNoCategory() {
    let vm = WardrobeViewModel()
    vm.items = [
        TestFixtures.makeWardrobeItem(category: .top),
        TestFixtures.makeWardrobeItem(category: .bottom, subcategory: .jeans),
        TestFixtures.makeWardrobeItem(category: .shoe, subcategory: .sneakers),
    ]
    vm.selectedCategory = nil
    #expect(vm.filteredItems.count == 3)
}

@Test @MainActor func wardrobeFilteredItemsFiltersByCategory() {
    let vm = WardrobeViewModel()
    vm.items = [
        TestFixtures.makeWardrobeItem(category: .top),
        TestFixtures.makeWardrobeItem(category: .top),
        TestFixtures.makeWardrobeItem(category: .bottom, subcategory: .jeans),
    ]
    vm.selectedCategory = .top
    #expect(vm.filteredItems.count == 2)
}

@Test @MainActor func wardrobeItemCountTextZeroItems() {
    let vm = WardrobeViewModel()
    vm.items = []
    #expect(vm.itemCountText == "0 items")
}

@Test @MainActor func wardrobeItemCountTextSingular() {
    let vm = WardrobeViewModel()
    vm.items = [TestFixtures.makeWardrobeItem()]
    #expect(vm.itemCountText == "1 item")
}

@Test @MainActor func wardrobeItemCountTextPlural() {
    let vm = WardrobeViewModel()
    vm.items = (0..<5).map { _ in TestFixtures.makeWardrobeItem() }
    #expect(vm.itemCountText == "5 items")
}

@Test @MainActor func wardrobeItemCountTextWithCategory() {
    let vm = WardrobeViewModel()
    vm.items = (0..<3).map { _ in TestFixtures.makeWardrobeItem(category: .top) }
    vm.selectedCategory = .top
    #expect(vm.itemCountText == "3 Tops")
}

@Test @MainActor func wardrobeSelectCategoryTogglesSame() {
    let vm = WardrobeViewModel()
    vm.selectCategory(.top)
    #expect(vm.selectedCategory == .top)
    vm.selectCategory(.top)
    #expect(vm.selectedCategory == nil)
}

@Test @MainActor func wardrobeSelectCategorySwitchesDifferent() {
    let vm = WardrobeViewModel()
    vm.selectCategory(.top)
    #expect(vm.selectedCategory == .top)
    vm.selectCategory(.bottom)
    #expect(vm.selectedCategory == .bottom)
}

// MARK: - Build 9: search filter

@Test @MainActor func wardrobeSearchMatchesSubcategoryName() {
    // The most natural search target — the user types "Sneakers"
    // because that's what the card says.
    let vm = WardrobeViewModel()
    vm.items = [
        TestFixtures.makeWardrobeItem(category: .top, subcategory: .tshirt),
        TestFixtures.makeWardrobeItem(category: .bottom, subcategory: .jeans),
        TestFixtures.makeWardrobeItem(category: .shoe, subcategory: .sneakers),
    ]
    vm.searchQuery = "sneakers"
    #expect(vm.filteredItems.count == 1)
    #expect(vm.filteredItems.first?.subcategory == .sneakers)
}

@Test @MainActor func wardrobeSearchIsCaseInsensitive() {
    // Mobile keyboards autocapitalize-the-first-letter aggressively,
    // so "Tshirt" with leading caps must match the lowercased
    // canonical name. Texture / category branches share the same
    // path so verifying once is enough.
    let vm = WardrobeViewModel()
    vm.items = [
        TestFixtures.makeWardrobeItem(category: .top, subcategory: .tshirt),
    ]
    vm.searchQuery = "T-shirt"
    #expect(vm.filteredItems.count == 1)
}

@Test @MainActor func wardrobeSearchMatchesTexture() {
    // Texture isn't displayed on the card but IS in the user's
    // mental model ("my denim jacket"). Matching it gives the
    // search bar more reach than just the visible name strings.
    let vm = WardrobeViewModel()
    vm.items = [
        TestFixtures.makeWardrobeItem(category: .top, subcategory: .tshirt, texture: .cotton),
        TestFixtures.makeWardrobeItem(category: .bottom, subcategory: .jeans, texture: .denim),
    ]
    vm.searchQuery = "denim"
    #expect(vm.filteredItems.count == 1)
    #expect(vm.filteredItems.first?.texture == .denim)
}

@Test @MainActor func wardrobeSearchEmptyQueryIsNoOp() {
    // Whitespace and empty strings must return the full list —
    // the field can sit above the chips without changing default
    // behavior, and clearing the query restores the chip-only view.
    let vm = WardrobeViewModel()
    vm.items = (0..<3).map { _ in TestFixtures.makeWardrobeItem() }

    vm.searchQuery = ""
    #expect(vm.filteredItems.count == 3)

    vm.searchQuery = "   "
    #expect(vm.filteredItems.count == 3)
}

@Test @MainActor func wardrobeSearchCombinesWithCategoryChip() {
    // The two filters AND together: category narrows first, then
    // the query narrows what's left. A user picking "Shoe" then
    // typing "sneakers" sees only shoes that match "sneakers".
    let vm = WardrobeViewModel()
    vm.items = [
        TestFixtures.makeWardrobeItem(category: .top, subcategory: .tshirt),
        TestFixtures.makeWardrobeItem(category: .shoe, subcategory: .sneakers),
        TestFixtures.makeWardrobeItem(category: .shoe, subcategory: .boots),
    ]
    vm.selectedCategory = .shoe
    vm.searchQuery = "sneakers"
    #expect(vm.filteredItems.count == 1)
    #expect(vm.filteredItems.first?.subcategory == .sneakers)
}

@Test @MainActor func wardrobeIsEmptyWhenEmptyAndNotLoading() {
    let vm = WardrobeViewModel()
    vm.items = []
    vm.isLoading = false
    #expect(vm.isEmpty == true)
}

@Test @MainActor func wardrobeIsEmptyFalseWhileLoading() {
    let vm = WardrobeViewModel()
    vm.items = []
    vm.isLoading = true
    #expect(vm.isEmpty == false)
}

@Test @MainActor func wardrobeLoadItemsErrorSetsMessage() async {
    let mockRepo = MockWardrobeRepository()
    mockRepo.fetchItemsResult = .failure(MockError.simulated)
    let vm = WardrobeViewModel(wardrobeRepository: mockRepo)

    await vm.loadItems(userId: UUID())
    #expect(vm.errorMessage != nil)
    #expect(vm.items.isEmpty)
    #expect(vm.isLoading == false)
}

@Test @MainActor func wardrobeLoadItemsSuccessSetsItems() async {
    let mockRepo = MockWardrobeRepository()
    let testItems = [TestFixtures.makeWardrobeItem(), TestFixtures.makeWardrobeItem(category: .bottom, subcategory: .jeans)]
    mockRepo.fetchItemsResult = .success(testItems)
    let vm = WardrobeViewModel(wardrobeRepository: mockRepo)

    await vm.loadItems(userId: UUID())
    #expect(vm.items.count == 2)
    #expect(vm.errorMessage == nil)
    #expect(vm.isLoading == false)
    #expect(mockRepo.fetchItemsCallCount == 1)
}
