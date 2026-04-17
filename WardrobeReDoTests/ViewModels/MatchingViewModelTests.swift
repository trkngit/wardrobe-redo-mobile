import Foundation
import Testing
@testable import WardrobeReDo

// MARK: - MatchingViewModel Tests

@Test @MainActor func matchingFilteredItemsAllWhenNoCategory() {
    let vm = MatchingViewModel()
    vm.wardrobeItems = [
        TestFixtures.makeWardrobeItem(category: .top),
        TestFixtures.makeWardrobeItem(category: .bottom, subcategory: .jeans),
    ]
    vm.selectedCategory = nil
    #expect(vm.filteredItems.count == 2)
}

@Test @MainActor func matchingFilteredItemsFilteredByCategory() {
    let vm = MatchingViewModel()
    vm.wardrobeItems = [
        TestFixtures.makeWardrobeItem(category: .top),
        TestFixtures.makeWardrobeItem(category: .top),
        TestFixtures.makeWardrobeItem(category: .bottom, subcategory: .jeans),
    ]
    vm.selectedCategory = .top
    #expect(vm.filteredItems.count == 2)
}

@Test @MainActor func matchingHasResultsFalseWhenEmpty() {
    let vm = MatchingViewModel()
    vm.matchResults = []
    #expect(vm.hasResults == false)
}

@Test @MainActor func matchingHasResultsTrueWithResults() {
    let vm = MatchingViewModel()
    let archetype = TestFixtures.makeStyleArchetype()
    let rule = TestFixtures.makeStyleRule()
    let breakdown = ScoringDimension.allCases.map { DimensionScore(dimension: $0, value: 0.7, reasoning: "") }
    let score = OutfitScore(breakdown: breakdown)
    let items = [TestFixtures.makeWardrobeItem()]
    let slots = items.map { SlotAssignment(item: $0, slotName: $0.category.rawValue, role: "hero") }
    vm.matchResults = [
        OutfitCandidate(items: items, archetype: archetype, rule: rule, score: score,
                        slots: slots, editorialName: "Test", editorialDescription: "desc"),
    ]
    #expect(vm.hasResults == true)
}

@Test @MainActor func matchingSelectItemDeselects() async {
    let vm = MatchingViewModel()
    let item = TestFixtures.makeWardrobeItem()
    vm.wardrobeItems = [item]
    vm.selectedItem = item

    // Tapping same item deselects
    await vm.selectItem(item, userId: UUID())
    #expect(vm.selectedItem == nil)
    #expect(vm.matchResults.isEmpty)
}

@Test @MainActor func matchingInitialState() {
    let vm = MatchingViewModel()
    #expect(vm.wardrobeItems.isEmpty)
    #expect(vm.selectedItem == nil)
    #expect(vm.matchResults.isEmpty)
    #expect(vm.isLoading == false)
    #expect(vm.isMatching == false)
    #expect(vm.selectedOccasion == .casual)
}

// MARK: - Additional Coverage

@Test @MainActor func matchingSelectDifferentItemSwitchesHero() async {
    let vm = MatchingViewModel()
    let item1 = TestFixtures.makeWardrobeItem(category: .top)
    let item2 = TestFixtures.makeWardrobeItem(category: .bottom, subcategory: .jeans)
    vm.wardrobeItems = [item1, item2]

    // Select first
    await vm.selectItem(item1, userId: UUID())
    // Select different — should switch hero
    await vm.selectItem(item2, userId: UUID())
    #expect(vm.selectedItem?.id == item2.id)
    #expect(vm.savedResultIndices.isEmpty)
}

@Test @MainActor func matchingSavedResultIndicesTrackedCorrectly() {
    let vm = MatchingViewModel()
    vm.savedResultIndices.insert(0)
    vm.savedResultIndices.insert(2)

    #expect(vm.savedResultIndices.contains(0))
    #expect(!vm.savedResultIndices.contains(1))
    #expect(vm.savedResultIndices.contains(2))
    #expect(vm.savedResultIndices.count == 2)
}
