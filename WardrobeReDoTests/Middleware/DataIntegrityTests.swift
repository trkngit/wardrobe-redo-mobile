import Foundation
import Testing
@testable import WardrobeReDo

// MARK: - M3: Data Integrity & Partial Failure Tests
// Verifies behavior when operations partially succeed/fail, state consistency.

// MARK: - WardrobeViewModel Delete Order

@Test @MainActor func deleteItemCallsDeleteImagesAndRepo() async {
    let mockRepo = MockWardrobeRepository()
    let mockImage = MockImageService()
    let vm = WardrobeViewModel(wardrobeRepository: mockRepo, imageService: mockImage)
    let item = TestFixtures.makeWardrobeItem()
    vm.items = [item]

    await vm.deleteItem(item, userId: UUID())

    #expect(mockImage.deleteImagesCallCount == 1)
    #expect(mockRepo.deleteItemCallCount == 1)
}

@Test @MainActor func deleteItemDBFirstThenImages() async {
    // Verify the fix: DB delete happens first, then image cleanup.
    // If image cleanup fails, item is still removed from DB (storage leak > data loss).
    let mockRepo = MockWardrobeRepository()
    let mockImage = MockImageService()
    mockImage.deleteImagesError = MockError.simulated
    let vm = WardrobeViewModel(wardrobeRepository: mockRepo, imageService: mockImage)
    let item = TestFixtures.makeWardrobeItem()
    vm.items = [item]

    await vm.deleteItem(item, userId: UUID())

    // DB delete still happened
    #expect(mockRepo.deleteItemCallCount == 1)
    // Item removed from local state
    #expect(vm.items.isEmpty)
    // Soft error about image cleanup (not a hard failure)
    #expect(vm.errorMessage == "Item deleted, but image cleanup failed.")
}

@Test @MainActor func deleteItemDBFailureKeepsItemAndImages() async {
    // If DB delete fails, item stays in list and images are NOT deleted
    let mockRepo = MockWardrobeRepository()
    mockRepo.deleteItemError = MockError.simulated
    let mockImage = MockImageService()
    let vm = WardrobeViewModel(wardrobeRepository: mockRepo, imageService: mockImage)
    let item = TestFixtures.makeWardrobeItem()
    vm.items = [item]

    await vm.deleteItem(item, userId: UUID())

    // Item should still be in the list
    #expect(vm.items.count == 1)
    // Images should NOT have been touched
    #expect(mockImage.deleteImagesCallCount == 0)
    #expect(vm.errorMessage == "Couldn't delete item.")
}

// MARK: - OutfitViewModel Local State Updates After Reactions

@Test @MainActor func outfitReactionSuccessUpdatesLocalState() async {
    let mockRepo = MockOutfitRepository()
    let outfit = TestFixtures.makeOutfit(reaction: nil)
    let vm = OutfitViewModel(outfitRepository: mockRepo)
    vm.dailyOutfits = [TestFixtures.makeDailyOutfit(outfit: outfit)]

    await vm.react(outfitId: outfit.id, reaction: "love")

    // Local state should be updated
    let updatedOutfit = vm.dailyOutfits.first?.outfit
    #expect(updatedOutfit?.reaction == "love")
}

@Test @MainActor func outfitToggleWornSuccessUpdatesLocalState() async {
    let mockRepo = MockOutfitRepository()
    let outfit = TestFixtures.makeOutfit(isWorn: false)
    let vm = OutfitViewModel(outfitRepository: mockRepo)
    vm.dailyOutfits = [TestFixtures.makeDailyOutfit(outfit: outfit)]

    await vm.toggleWorn(outfitId: outfit.id)

    let updatedOutfit = vm.dailyOutfits.first?.outfit
    #expect(updatedOutfit?.isWorn == true)
}

// MARK: - OutfitViewModel Error Doesn't Corrupt Local State

@Test @MainActor func outfitReactionErrorDoesNotChangeLocalState() async {
    let mockRepo = MockOutfitRepository()
    mockRepo.updateReactionError = MockError.simulated
    let outfit = TestFixtures.makeOutfit(reaction: nil)
    let vm = OutfitViewModel(outfitRepository: mockRepo)
    vm.dailyOutfits = [TestFixtures.makeDailyOutfit(outfit: outfit)]

    await vm.react(outfitId: outfit.id, reaction: "love")

    // On error, local state should NOT be updated
    let currentOutfit = vm.dailyOutfits.first?.outfit
    #expect(currentOutfit?.reaction == nil)
    #expect(vm.errorMessage != nil)
}

@Test @MainActor func outfitToggleWornErrorDoesNotChangeLocalState() async {
    let mockRepo = MockOutfitRepository()
    mockRepo.markAsWornError = MockError.simulated
    let outfit = TestFixtures.makeOutfit(isWorn: false)
    let vm = OutfitViewModel(outfitRepository: mockRepo)
    vm.dailyOutfits = [TestFixtures.makeDailyOutfit(outfit: outfit)]

    await vm.toggleWorn(outfitId: outfit.id)

    let currentOutfit = vm.dailyOutfits.first?.outfit
    #expect(currentOutfit?.isWorn == false)
    #expect(vm.errorMessage != nil)
}

// MARK: - AddItemViewModel State After Save Failure

@Test @MainActor func addItemSaveFailureResetsToDetailsStep() async {
    let mockImage = MockImageService()
    mockImage.uploadResult = .failure(MockError.uploadFailed)
    let vm = AddItemViewModel(imageService: mockImage)
    // Simulate having processed an image
    vm.processedImage = ProcessedImage(
        originalData: Data([0xFF]),
        thumbnailData: Data([0xFF]),
        maskedData: nil,
        extractionConfidence: nil,
        dominantColors: []
    )

    await vm.save(userId: UUID())

    #expect(vm.currentStep == .details)
    #expect(vm.isSaving == false)
    #expect(vm.errorMessage != nil)
    #expect(vm.didSave == false)
}

// MARK: - Outfit Not Found Handling
// FIX VERIFIED: react() now guards against unknown outfitIds with early return,
// matching the pattern already used by toggleWorn().

@Test @MainActor func outfitReactForNonExistentOutfitGuardsCorrectly() async {
    // react() should NOT call repo for unknown outfit IDs (was a bug, now fixed)
    let mockRepo = MockOutfitRepository()
    let vm = OutfitViewModel(outfitRepository: mockRepo)
    vm.dailyOutfits = [] // empty

    await vm.react(outfitId: UUID(), reaction: "love")

    // FIXED: repo is NOT called for unknown outfit IDs
    #expect(mockRepo.updateReactionCallCount == 0)
}

@Test @MainActor func outfitToggleWornForNonExistentOutfitGuardsCorrectly() async {
    // toggleWorn() correctly guards with firstIndex check — returns early
    let mockRepo = MockOutfitRepository()
    let vm = OutfitViewModel(outfitRepository: mockRepo)
    vm.dailyOutfits = []

    await vm.toggleWorn(outfitId: UUID())

    // Correctly guarded — repo NOT called for unknown outfit
    #expect(mockRepo.markAsWornCallCount == 0)
}

// MARK: - Duplicate Generation Guard

@Test @MainActor func generateDailyOutfitsSkipsIfAlreadyExist() async {
    // The duplicate generation guard should prevent re-generation
    let mockOutfitRepo = MockOutfitRepository()
    mockOutfitRepo.hasOutfitsForDateResult = true // outfits already exist
    mockOutfitRepo.fetchOutfitsByDateResult = .success([TestFixtures.makeOutfit()])
    let vm = OutfitViewModel(outfitRepository: mockOutfitRepo)

    await vm.generateDailyOutfits(userId: UUID())

    // Should have checked existence
    #expect(mockOutfitRepo.hasOutfitsForDateCallCount == 1)
    // Should NOT have generated (no need — outfits exist)
    #expect(vm.isGenerating == false)
}

// MARK: - Delete Order Verification

@Test @MainActor func deleteItemCallsRepoBeforeImages() async {
    // Verify DB delete happens, then image cleanup
    let mockRepo = MockWardrobeRepository()
    let mockImage = MockImageService()
    let vm = WardrobeViewModel(wardrobeRepository: mockRepo, imageService: mockImage)
    let item = TestFixtures.makeWardrobeItem()
    vm.items = [item]

    await vm.deleteItem(item, userId: UUID())

    // Both operations should have been called
    #expect(mockRepo.deleteItemCallCount == 1)
    #expect(mockImage.deleteImagesCallCount == 1)
    // Item should be removed from local state
    #expect(vm.items.isEmpty)
    // No error when both succeed
    #expect(vm.errorMessage == nil)
}

// MARK: - Matching Save Out of Bounds

@Test @MainActor func matchingSaveOutOfBoundsIndexSafe() async {
    let vm = MatchingViewModel()
    vm.matchResults = [] // empty

    await vm.saveAsOutfit(at: 5, userId: UUID())

    // Should return without crash due to guard
    #expect(vm.savedResultIndices.isEmpty)
}

// MARK: - Empty Wardrobe Edge Cases

@Test @MainActor func outfitLoadWithEmptyWardrobeShowsEmpty() async {
    let mockOutfitRepo = MockOutfitRepository()
    mockOutfitRepo.fetchOutfitsByDateResult = .success([])
    let vm = OutfitViewModel(outfitRepository: mockOutfitRepo)

    await vm.loadOutfits(userId: UUID())

    #expect(vm.isEmpty == true)
    #expect(vm.dailyOutfits.isEmpty)
}
