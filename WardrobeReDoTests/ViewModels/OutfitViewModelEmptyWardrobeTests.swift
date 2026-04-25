import Foundation
import Testing
@testable import WardrobeReDo

/// Coverage for the empty-wardrobe pre-check added to
/// `OutfitViewModel.loadOutfits`. The Outfits tab should surface the
/// actionable `wardrobeTooSmall(itemCount:)` failure on FIRST visit
/// when the user has fewer than 2 items, instead of waiting for the
/// user to tap "Generate" and hit the same wall.
@MainActor
@Suite("OutfitViewModel.emptyWardrobe", .serialized)
struct OutfitViewModelEmptyWardrobeTests {

    @Test func emptyWardrobeSetsWardrobeTooSmallFailureOnLoad() async {
        let mockOutfitRepo = MockOutfitRepository()
        mockOutfitRepo.fetchOutfitsByDateResult = .success([])
        let mockWardrobeRepo = MockWardrobeRepository()
        mockWardrobeRepo.fetchItemsResult = .success([])

        let vm = OutfitViewModel(
            outfitRepository: mockOutfitRepo,
            wardrobeRepository: mockWardrobeRepo
        )
        await vm.loadOutfits(userId: UUID())

        guard case .wardrobeTooSmall(let count) = vm.lastFailure else {
            Issue.record("Expected wardrobeTooSmall failure, got \(String(describing: vm.lastFailure))")
            return
        }
        #expect(count == 0)
    }

    @Test func singleItemWardrobeSetsWardrobeTooSmall() async {
        let mockOutfitRepo = MockOutfitRepository()
        mockOutfitRepo.fetchOutfitsByDateResult = .success([])
        let mockWardrobeRepo = MockWardrobeRepository()
        mockWardrobeRepo.fetchItemsResult = .success([
            TestFixtures.makeWardrobeItem(category: .top, subcategory: .tshirt)
        ])

        let vm = OutfitViewModel(
            outfitRepository: mockOutfitRepo,
            wardrobeRepository: mockWardrobeRepo
        )
        await vm.loadOutfits(userId: UUID())

        guard case .wardrobeTooSmall(let count) = vm.lastFailure else {
            Issue.record("Expected wardrobeTooSmall failure, got \(String(describing: vm.lastFailure))")
            return
        }
        #expect(count == 1)
    }

    @Test func archivedItemsDontCountTowardWardrobeMin() async {
        let mockOutfitRepo = MockOutfitRepository()
        mockOutfitRepo.fetchOutfitsByDateResult = .success([])
        let mockWardrobeRepo = MockWardrobeRepository()
        mockWardrobeRepo.fetchItemsResult = .success([
            TestFixtures.makeWardrobeItem(category: .top, subcategory: .tshirt, isArchived: false),
            TestFixtures.makeWardrobeItem(category: .bottom, subcategory: .jeans, isArchived: true),
            TestFixtures.makeWardrobeItem(category: .shoe, subcategory: .sneakers, isArchived: true),
        ])

        let vm = OutfitViewModel(
            outfitRepository: mockOutfitRepo,
            wardrobeRepository: mockWardrobeRepo
        )
        await vm.loadOutfits(userId: UUID())

        guard case .wardrobeTooSmall(let count) = vm.lastFailure else {
            Issue.record("Expected wardrobeTooSmall failure, got \(String(describing: vm.lastFailure))")
            return
        }
        #expect(count == 1, "only the unarchived item should count")
    }

    @Test func richWardrobeDoesNotSetFailure() async {
        let mockOutfitRepo = MockOutfitRepository()
        mockOutfitRepo.fetchOutfitsByDateResult = .success([])
        let mockWardrobeRepo = MockWardrobeRepository()
        mockWardrobeRepo.fetchItemsResult = .success([
            TestFixtures.makeWardrobeItem(category: .top, subcategory: .tshirt),
            TestFixtures.makeWardrobeItem(category: .bottom, subcategory: .jeans),
            TestFixtures.makeWardrobeItem(category: .shoe, subcategory: .sneakers),
        ])

        let vm = OutfitViewModel(
            outfitRepository: mockOutfitRepo,
            wardrobeRepository: mockWardrobeRepo
        )
        await vm.loadOutfits(userId: UUID())

        // 3 items is enough — no failure should be set; the user can
        // tap Generate and the generic prompt copy stands.
        #expect(vm.lastFailure == nil)
    }

    @Test func generationFailureUserMessageMentionsActionForEmpty() {
        // Pin the user-facing copy so a regression to "Add a few
        // items" doesn't silently land — the Outfits tab depends on
        // it being actionable.
        let failure = GenerationFailure.wardrobeTooSmall(itemCount: 0)
        #expect(failure.userMessage.lowercased().contains("add"))
    }

    @Test func wardrobeTooSmallSuggestsAddingItems() {
        let failure = GenerationFailure.wardrobeTooSmall(itemCount: 0)
        #expect(failure.suggestsAddingItems == true)
    }
}
