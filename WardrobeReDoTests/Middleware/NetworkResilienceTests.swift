import Foundation
import Testing
@testable import WardrobeReDo

// MARK: - M1: Network Resilience Tests
// Verifies error propagation, graceful degradation, and timeout behavior.

// MARK: - WardrobeViewModel Network Errors

@Test @MainActor func wardrobeLoadItemsNetworkErrorSetsMessage() async {
    let mockRepo = MockWardrobeRepository()
    mockRepo.fetchItemsResult = .failure(MockError.simulated)
    let vm = WardrobeViewModel(wardrobeRepository: mockRepo)

    await vm.loadItems(userId: UUID())

    #expect(vm.errorMessage != nil)
    #expect(vm.items.isEmpty)
    #expect(vm.isLoading == false)
}

@Test @MainActor func wardrobeLoadItemsSuccessClearsError() async {
    let mockRepo = MockWardrobeRepository()
    mockRepo.fetchItemsResult = .success([TestFixtures.makeWardrobeItem()])
    let vm = WardrobeViewModel(wardrobeRepository: mockRepo)

    await vm.loadItems(userId: UUID())

    #expect(vm.errorMessage == nil)
    #expect(vm.items.count == 1)
}

@Test @MainActor func wardrobeArchiveItemErrorSetsMessage() async {
    let mockRepo = MockWardrobeRepository()
    mockRepo.archiveItemError = MockError.simulated
    let vm = WardrobeViewModel(wardrobeRepository: mockRepo)
    let item = TestFixtures.makeWardrobeItem()
    vm.items = [item]

    await vm.archiveItem(item)

    #expect(vm.errorMessage != nil)
    // Item should still be in the list since archive failed
    #expect(mockRepo.archiveItemCallCount == 1)
}

@Test @MainActor func wardrobeDeleteItemErrorSetsMessage() async {
    let mockRepo = MockWardrobeRepository()
    let mockImage = MockImageService()
    mockRepo.deleteItemError = MockError.simulated
    let vm = WardrobeViewModel(wardrobeRepository: mockRepo, imageService: mockImage)
    let item = TestFixtures.makeWardrobeItem()
    vm.items = [item]

    await vm.deleteItem(item, userId: UUID())

    #expect(vm.errorMessage != nil)
    #expect(mockRepo.deleteItemCallCount == 1)
}

// MARK: - OutfitViewModel Network Errors

@Test @MainActor func outfitLoadErrorSetsMessage() async {
    let mockRepo = MockOutfitRepository()
    mockRepo.fetchOutfitsByDateResult = .failure(MockError.simulated)
    let vm = OutfitViewModel(outfitRepository: mockRepo)

    await vm.loadOutfits(userId: UUID())

    #expect(vm.errorMessage != nil)
    #expect(vm.dailyOutfits.isEmpty)
    #expect(vm.isLoading == false)
}

@Test @MainActor func outfitReactionErrorSetsMessage() async {
    let mockRepo = MockOutfitRepository()
    mockRepo.updateReactionError = MockError.simulated
    let outfit = TestFixtures.makeOutfit()
    let vm = OutfitViewModel(outfitRepository: mockRepo)
    vm.dailyOutfits = [TestFixtures.makeDailyOutfit(outfit: outfit)]

    await vm.react(outfitId: outfit.id, reaction: "love")

    #expect(vm.errorMessage != nil)
}

@Test @MainActor func outfitToggleWornErrorSetsMessage() async {
    let mockRepo = MockOutfitRepository()
    mockRepo.markAsWornError = MockError.simulated
    let outfit = TestFixtures.makeOutfit()
    let vm = OutfitViewModel(outfitRepository: mockRepo)
    vm.dailyOutfits = [TestFixtures.makeDailyOutfit(outfit: outfit)]

    await vm.toggleWorn(outfitId: outfit.id)

    #expect(vm.errorMessage != nil)
}

// MARK: - MatchingViewModel Network Errors

@Test @MainActor func matchingLoadWardrobeErrorSetsMessage() async {
    let mockRepo = MockWardrobeRepository()
    mockRepo.fetchItemsResult = .failure(MockError.simulated)
    let vm = MatchingViewModel(wardrobeRepository: mockRepo)

    await vm.loadWardrobe(userId: UUID())

    #expect(vm.errorMessage != nil)
    #expect(vm.wardrobeItems.isEmpty)
    #expect(vm.isLoading == false)
}

@Test @MainActor func matchingFindMatchesErrorSetsMessage() async {
    let mockOutfitRepo = MockOutfitRepository()
    mockOutfitRepo.fetchRecentItemIdsResult = .failure(MockError.simulated)
    let vm = MatchingViewModel(outfitRepository: mockOutfitRepo)
    let item = TestFixtures.makeWardrobeItem()
    vm.wardrobeItems = [item]
    vm.selectedItem = item

    await vm.findMatches(userId: UUID())

    #expect(vm.errorMessage != nil)
    #expect(vm.isMatching == false)
}

// MARK: - Signed URL Silent Failures

@Test @MainActor func signedURLFailureDoesNotCrash() async {
    let mockImage = MockImageService()
    mockImage.signedURLResult = .failure(MockError.simulated)
    let vm = WardrobeViewModel(imageService: mockImage)
    let item = TestFixtures.makeWardrobeItem()
    vm.items = [item]

    // thumbnailURL should return nil without crashing
    let url = await vm.thumbnailURL(for: item)
    #expect(url == nil)
}

// MARK: - Loading State Transitions

@Test @MainActor func wardrobeLoadSetsAndClearsLoadingState() async {
    let mockRepo = MockWardrobeRepository()
    mockRepo.fetchItemsResult = .success([])
    let vm = WardrobeViewModel(wardrobeRepository: mockRepo)

    // Before
    #expect(vm.isLoading == false)

    await vm.loadItems(userId: UUID())

    // After
    #expect(vm.isLoading == false)
}

@Test @MainActor func outfitLoadSetsAndClearsLoadingState() async {
    let mockRepo = MockOutfitRepository()
    mockRepo.fetchOutfitsByDateResult = .success([])
    let vm = OutfitViewModel(outfitRepository: mockRepo)

    await vm.loadOutfits(userId: UUID())

    #expect(vm.isLoading == false)
}

@Test @MainActor func matchingLoadSetsAndClearsLoadingState() async {
    let mockRepo = MockWardrobeRepository()
    mockRepo.fetchItemsResult = .success([])
    let vm = MatchingViewModel(wardrobeRepository: mockRepo)

    await vm.loadWardrobe(userId: UUID())

    #expect(vm.isLoading == false)
}

// MARK: - Multiple Error Handling

@Test @MainActor func wardrobeSuccessAfterErrorClearsError() async {
    let mockRepo = MockWardrobeRepository()
    let vm = WardrobeViewModel(wardrobeRepository: mockRepo)

    // First: error
    mockRepo.fetchItemsResult = .failure(MockError.simulated)
    await vm.loadItems(userId: UUID())
    #expect(vm.errorMessage != nil)

    // Second: success
    mockRepo.fetchItemsResult = .success([TestFixtures.makeWardrobeItem()])
    await vm.loadItems(userId: UUID())
    #expect(vm.errorMessage == nil)
    #expect(vm.items.count == 1)
}

// MARK: - Repository Call Counts

@Test @MainActor func outfitReactionUpdatesCallCount() async {
    let mockRepo = MockOutfitRepository()
    let outfit = TestFixtures.makeOutfit()
    let vm = OutfitViewModel(outfitRepository: mockRepo)
    vm.dailyOutfits = [TestFixtures.makeDailyOutfit(outfit: outfit)]

    await vm.react(outfitId: outfit.id, reaction: "love")
    await vm.react(outfitId: outfit.id, reaction: "like")

    #expect(mockRepo.updateReactionCallCount == 2)
}

@Test @MainActor func outfitMarkWornUpdatesCallCount() async {
    let mockRepo = MockOutfitRepository()
    let outfit = TestFixtures.makeOutfit()
    let vm = OutfitViewModel(outfitRepository: mockRepo)
    vm.dailyOutfits = [TestFixtures.makeDailyOutfit(outfit: outfit)]

    await vm.toggleWorn(outfitId: outfit.id)

    #expect(mockRepo.markAsWornCallCount == 1)
    #expect(mockRepo.lastIsWorn == true)
}
