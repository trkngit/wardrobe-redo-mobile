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

// MARK: - Build 10: save-all + unsaved count

@Test @MainActor func matchingUnsavedResultCountTracksSavedSet() {
    // The view binds the bulk button's title to this count
    // ("Save all (3)") so it has to reflect every transition:
    // initial state (all unsaved), single-save (decremented),
    // bulk-save (zero). Pure derived state — no network call —
    // so this is the surface that's worth pinning in tests. The
    // save-and-flip side effect is covered by the existing
    // single-save path (`saveAsOutfit`) which already roundtrips
    // through `OutfitGenerationService`; bulk-save shares that
    // code path.
    let vm = MatchingViewModel()
    vm.matchResults = (0..<3).map { _ in matchFixtureCandidate() }
    #expect(vm.unsavedResultCount == 3)

    vm.savedResultIndices.insert(0)
    #expect(vm.unsavedResultCount == 2)

    vm.savedResultIndices = Set(0..<3)
    #expect(vm.unsavedResultCount == 0)
}

@Test @MainActor func matchingSaveAllIsNoOpWhenAllSaved() async {
    let vm = MatchingViewModel()
    vm.matchResults = (0..<2).map { _ in matchFixtureCandidate() }
    vm.savedResultIndices = [0, 1]

    // Calling bulk-save when nothing is unsaved must not throw,
    // mutate state, or hit the network. The early-return guard
    // is what makes the method safe to call from anywhere
    // (telemetry, future UI tests, accidental double-taps).
    await vm.saveAllResults(userId: UUID())

    #expect(vm.savedResultIndices == [0, 1])
    #expect(vm.errorMessage == nil)
}

/// Reusable fixture for tests that need a list of candidates but
/// don't care what's inside them. Hand-rolled here rather than in
/// TestFixtures because no other suite needs it yet and the
/// match-only tests are the natural home.
@MainActor
private func matchFixtureCandidate() -> OutfitCandidate {
    let archetype = TestFixtures.makeStyleArchetype()
    let rule = TestFixtures.makeStyleRule()
    let breakdown = ScoringDimension.allCases.map {
        DimensionScore(dimension: $0, value: 0.7, reasoning: "")
    }
    let score = OutfitScore(breakdown: breakdown)
    let items = [TestFixtures.makeWardrobeItem()]
    let slots = items.map {
        SlotAssignment(item: $0, slotName: $0.category.rawValue, role: "hero")
    }
    return OutfitCandidate(
        items: items,
        archetype: archetype,
        rule: rule,
        score: score,
        slots: slots,
        editorialName: "Test",
        editorialDescription: "desc"
    )
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
