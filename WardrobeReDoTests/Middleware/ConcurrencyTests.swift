import Foundation
import Testing
@testable import WardrobeReDo

// MARK: - M2: Concurrency & State Consistency Tests
// Verifies state machine transitions, double-call guards, and state consistency.

// MARK: - AddItemViewModel State Machine

@Test @MainActor func addItemSaveGuardsWithoutProcessedImage() async {
    let vm = AddItemViewModel()
    vm.processedImage = nil

    await vm.save(userId: UUID())

    // Should return immediately without changing state
    #expect(vm.isSaving == false)
    #expect(vm.currentStep == .photo)
}

@Test @MainActor func addItemCanSavePreventsDoubleSave() {
    let vm = AddItemViewModel()
    vm.isSaving = true

    #expect(vm.canSave == false)
}

@Test @MainActor func addItemResetClearsAllState() {
    let vm = AddItemViewModel()
    vm.currentStep = .details
    vm.category = .shoe
    vm.texture = .leather
    vm.fitAttribute = .slim
    vm.selectedSeasons = [.winter]
    vm.selectedOccasions = [.formal]
    vm.isProcessing = true
    vm.isSaving = true
    vm.errorMessage = "test error"
    vm.didSave = true

    vm.reset()

    #expect(vm.currentStep == .photo)
    #expect(vm.category == .top)
    #expect(vm.subcategory == .tshirt)
    #expect(vm.texture == nil)
    #expect(vm.fitAttribute == nil)
    #expect(vm.selectedSeasons == Set(Season.allCases))
    #expect(vm.selectedOccasions == [.casual])
    #expect(vm.isProcessing == false)
    #expect(vm.isSaving == false)
    #expect(vm.errorMessage == nil)
    #expect(vm.didSave == false)
}

// MARK: - MatchingViewModel State Transitions

@Test @MainActor func matchingSelectItemToggle() async {
    let vm = MatchingViewModel()
    let item = TestFixtures.makeWardrobeItem()
    vm.wardrobeItems = [item]

    // Select
    await vm.selectItem(item, userId: UUID())
    // Since matchResults depend on generation service, selectedItem should be set
    // but we can't fully test without mocking generationService

    // Deselect same item
    await vm.selectItem(item, userId: UUID())
    #expect(vm.selectedItem == nil)
    #expect(vm.matchResults.isEmpty)
    #expect(vm.savedResultIndices.isEmpty)
}

@Test @MainActor func matchingSelectDifferentItemClearsResults() async {
    let vm = MatchingViewModel()
    let item1 = TestFixtures.makeWardrobeItem()
    let item2 = TestFixtures.makeWardrobeItem(category: .bottom, subcategory: .jeans)
    vm.wardrobeItems = [item1, item2]

    // Select first
    await vm.selectItem(item1, userId: UUID())
    // Select different — results should clear
    await vm.selectItem(item2, userId: UUID())

    #expect(vm.selectedItem?.id == item2.id)
    #expect(vm.savedResultIndices.isEmpty)
}

@Test @MainActor func matchingSavedResultIndicesTracked() {
    let vm = MatchingViewModel()
    vm.savedResultIndices.insert(0)
    vm.savedResultIndices.insert(2)

    #expect(vm.savedResultIndices.contains(0))
    #expect(!vm.savedResultIndices.contains(1))
    #expect(vm.savedResultIndices.contains(2))
}

// MARK: - OutfitViewModel Reaction State Consistency

@Test @MainActor func outfitReactionNilToLove() async {
    let mockRepo = MockOutfitRepository()
    let outfit = TestFixtures.makeOutfit(reaction: nil)
    let vm = OutfitViewModel(outfitRepository: mockRepo)
    vm.dailyOutfits = [TestFixtures.makeDailyOutfit(outfit: outfit)]

    await vm.react(outfitId: outfit.id, reaction: "love")

    #expect(mockRepo.lastReaction as? String == "love")
}

@Test @MainActor func outfitReactionLoveToLoveClearsReaction() async {
    let mockRepo = MockOutfitRepository()
    let outfit = TestFixtures.makeOutfit(reaction: "love")
    let vm = OutfitViewModel(outfitRepository: mockRepo)
    vm.dailyOutfits = [TestFixtures.makeDailyOutfit(outfit: outfit)]

    await vm.react(outfitId: outfit.id, reaction: "love")

    // Same reaction tapped = clear (nil)
    // The last reaction sent to repo should be nil
    let sentReaction = mockRepo.lastReaction
    #expect(sentReaction as? String? == Optional<String>.none)
}

@Test @MainActor func outfitReactionSwitchFromLoveToLike() async {
    let mockRepo = MockOutfitRepository()
    let outfit = TestFixtures.makeOutfit(reaction: "love")
    let vm = OutfitViewModel(outfitRepository: mockRepo)
    vm.dailyOutfits = [TestFixtures.makeDailyOutfit(outfit: outfit)]

    await vm.react(outfitId: outfit.id, reaction: "like")

    #expect(mockRepo.lastReaction as? String == "like")
}

@Test @MainActor func outfitToggleWornFalseToTrue() async {
    let mockRepo = MockOutfitRepository()
    let outfit = TestFixtures.makeOutfit(isWorn: false)
    let vm = OutfitViewModel(outfitRepository: mockRepo)
    vm.dailyOutfits = [TestFixtures.makeDailyOutfit(outfit: outfit)]

    await vm.toggleWorn(outfitId: outfit.id)

    #expect(mockRepo.lastIsWorn == true)
}

@Test @MainActor func outfitToggleWornTrueToFalse() async {
    let mockRepo = MockOutfitRepository()
    let outfit = TestFixtures.makeOutfit(isWorn: true)
    let vm = OutfitViewModel(outfitRepository: mockRepo)
    vm.dailyOutfits = [TestFixtures.makeDailyOutfit(outfit: outfit)]

    await vm.toggleWorn(outfitId: outfit.id)

    #expect(mockRepo.lastIsWorn == false)
}
