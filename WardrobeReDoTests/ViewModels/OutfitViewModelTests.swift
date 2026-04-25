import Foundation
import Testing
@testable import WardrobeReDo

// MARK: - OutfitViewModel Tests

@Test @MainActor func outfitIsEmptyWhenNoOutfitsAndNotLoading() {
    let vm = OutfitViewModel()
    vm.dailyOutfits = []
    vm.isLoading = false
    vm.isGenerating = false
    #expect(vm.isEmpty == true)
}

@Test @MainActor func outfitIsEmptyFalseWhileLoading() {
    let vm = OutfitViewModel()
    vm.isLoading = true
    #expect(vm.isEmpty == false)
}

@Test @MainActor func outfitIsEmptyFalseWhileGenerating() {
    let vm = OutfitViewModel()
    vm.isGenerating = true
    #expect(vm.isEmpty == false)
}

@Test @MainActor func outfitIsEmptyFalseWithOutfits() {
    let vm = OutfitViewModel()
    vm.dailyOutfits = [TestFixtures.makeDailyOutfit()]
    #expect(vm.isEmpty == false)
}

@Test @MainActor func outfitReactToggleNilToLove() async {
    let mockOutfitRepo = MockOutfitRepository()
    let vm = OutfitViewModel(outfitRepository: mockOutfitRepo)

    let outfit = TestFixtures.makeOutfit(reaction: nil)
    vm.dailyOutfits = [TestFixtures.makeDailyOutfit(outfit: outfit)]

    await vm.react(outfitId: outfit.id, reaction: "love")
    #expect(vm.dailyOutfits.first?.outfit.reaction == "love")
    #expect(mockOutfitRepo.updateReactionCallCount == 1)
}

@Test @MainActor func outfitReactToggleSameReactionClears() async {
    let mockOutfitRepo = MockOutfitRepository()
    let vm = OutfitViewModel(outfitRepository: mockOutfitRepo)

    let outfit = TestFixtures.makeOutfit(reaction: "love")
    vm.dailyOutfits = [TestFixtures.makeDailyOutfit(outfit: outfit)]

    await vm.react(outfitId: outfit.id, reaction: "love")
    #expect(vm.dailyOutfits.first?.outfit.reaction == nil)
}

@Test @MainActor func outfitReactSwitchesDifferentReaction() async {
    let mockOutfitRepo = MockOutfitRepository()
    let vm = OutfitViewModel(outfitRepository: mockOutfitRepo)

    let outfit = TestFixtures.makeOutfit(reaction: "love")
    vm.dailyOutfits = [TestFixtures.makeDailyOutfit(outfit: outfit)]

    await vm.react(outfitId: outfit.id, reaction: "like")
    #expect(vm.dailyOutfits.first?.outfit.reaction == "like")
}

// MARK: - regenerateDailyOutfits

@Test @MainActor func regenerateDailyOutfitsDeletesBeforeFetching() async {
    // Confirms the "Generate New Outfits" path:
    //   1. Calls deleteOutfits FIRST so the cache check inside the
    //      shared generation path returns false.
    //   2. Then proceeds through the generation path. With the wardrobe
    //      empty (default mock state), the shared path short-circuits
    //      to a wardrobeTooSmall failure — that's fine for ordering.
    //
    // The single assertion that matters: `deleteOutfits` is the FIRST
    // call recorded by the mock. Anything else proves the regenerate
    // path bypassed the delete and would render the same stale batch.
    let userId = UUID()
    let mockRepo = MockOutfitRepository()
    let mockWardrobe = MockWardrobeRepository()
    let vm = OutfitViewModel(
        outfitRepository: mockRepo,
        wardrobeRepository: mockWardrobe
    )

    await vm.regenerateDailyOutfits(userId: userId)

    #expect(mockRepo.deleteOutfitsCallCount == 1)
    #expect(mockRepo.lastDeleteOutfitsUserId == userId)
    #expect(mockRepo.callLog.first == "deleteOutfits")
    // dailyOutfits should be cleared right after delete so the UI
    // doesn't briefly render the stale cards.
    #expect(vm.dailyOutfits.isEmpty)
    #expect(vm.isRegenerating == false)
}

@Test @MainActor func regenerateDailyOutfitsSurfacesDeleteFailure() async {
    let userId = UUID()
    let mockRepo = MockOutfitRepository()
    mockRepo.deleteOutfitsError = MockError.simulated
    let vm = OutfitViewModel(outfitRepository: mockRepo)

    await vm.regenerateDailyOutfits(userId: userId)

    #expect(mockRepo.deleteOutfitsCallCount == 1)
    #expect(vm.lastFailure != nil)
    #expect(vm.isRegenerating == false)
}

@Test @MainActor func outfitToggleWornFlipsState() async {
    let mockOutfitRepo = MockOutfitRepository()
    let vm = OutfitViewModel(outfitRepository: mockOutfitRepo)

    let outfit = TestFixtures.makeOutfit(isWorn: false)
    vm.dailyOutfits = [TestFixtures.makeDailyOutfit(outfit: outfit)]

    await vm.toggleWorn(outfitId: outfit.id)
    #expect(vm.dailyOutfits.first?.outfit.isWorn == true)
    #expect(mockOutfitRepo.markAsWornCallCount == 1)

    await vm.toggleWorn(outfitId: outfit.id)
    #expect(vm.dailyOutfits.first?.outfit.isWorn == false)
}

// MARK: - Additional Coverage

@Test @MainActor func outfitReactSkipOn() async {
    let mockOutfitRepo = MockOutfitRepository()
    let vm = OutfitViewModel(outfitRepository: mockOutfitRepo)
    let outfit = TestFixtures.makeOutfit(reaction: nil)
    vm.dailyOutfits = [TestFixtures.makeDailyOutfit(outfit: outfit)]

    await vm.react(outfitId: outfit.id, reaction: "skip")
    #expect(vm.dailyOutfits.first?.outfit.reaction == "skip")
}

@Test @MainActor func outfitLoadOutfitsErrorSetsErrorMessage() async {
    let mockOutfitRepo = MockOutfitRepository()
    mockOutfitRepo.fetchOutfitsByDateResult = .failure(MockError.simulated)
    let vm = OutfitViewModel(outfitRepository: mockOutfitRepo)

    await vm.loadOutfits(userId: UUID())
    #expect(vm.errorMessage != nil)
    #expect(vm.isLoading == false)
}

@Test @MainActor func outfitTodayDateStringMatchesFormat() {
    let vm = OutfitViewModel()
    let dateString = vm.todayDateString
    let regex = /^\d{4}-\d{2}-\d{2}$/
    #expect(dateString.wholeMatch(of: regex) != nil)
}

@Test @MainActor func outfitReactErrorSetsMessage() async {
    let mockOutfitRepo = MockOutfitRepository()
    mockOutfitRepo.updateReactionError = MockError.simulated
    let vm = OutfitViewModel(outfitRepository: mockOutfitRepo)
    let outfit = TestFixtures.makeOutfit(reaction: nil)
    vm.dailyOutfits = [TestFixtures.makeDailyOutfit(outfit: outfit)]

    await vm.react(outfitId: outfit.id, reaction: "love")
    #expect(vm.errorMessage == "Couldn't save reaction.")
}
