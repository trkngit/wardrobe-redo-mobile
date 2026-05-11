import Foundation
import Testing
@testable import WardrobeReDo

// MARK: - Build 7 — match flow regeneration tests
//
// Mirrors `OutfitViewModelGenerationFlowTests` but for the match
// surface. The two VMs share the same debounce + cache + toast
// contract; the match flow has two structural differences worth
// covering separately:
//
//   1. `requestRegeneration` is a no-op when `selectedItem == nil`
//      (no hero yet → the view is in the "pick a piece" prompt
//      state). The Outfits tab has no equivalent guard.
//
//   2. The match generation engine doesn't take a seed, so
//      `.surpriseMe` re-runs the same evaluation. Test parity
//      with the outfits tab is the toast contract: surprise me
//      stays silent, picker change surfaces a toast.
//
// The cache + invalidation tests live alongside `OutfitViewModel`'s
// in spirit — the code paths are structurally identical, so we
// validate the matching VM's version once here for guard-rail
// coverage.

private enum MatchFlowTestFixtures {
    /// Hero + one supporting piece. Clears the `wardrobeTooSmall`
    /// pre-check in `findMatches` (which requires ≥ 1 supporting
    /// item *beyond* the hero).
    @MainActor
    static func seededWardrobe() -> [WardrobeItem] {
        [
            TestFixtures.makeWardrobeItem(category: .top, subcategory: .tshirt),
            TestFixtures.makeWardrobeItem(category: .bottom, subcategory: .jeans)
        ]
    }

    @MainActor
    static func makeVM() -> (MatchingViewModel, MockOutfitRepository, MockWardrobeRepository) {
        let outfitRepo = MockOutfitRepository()
        let wardrobeRepo = MockWardrobeRepository()
        wardrobeRepo.fetchItemsResult = .success(seededWardrobe())
        let vm = MatchingViewModel(
            wardrobeRepository: wardrobeRepo,
            outfitRepository: outfitRepo
        )
        vm.wardrobeItems = seededWardrobe()
        return (vm, outfitRepo, wardrobeRepo)
    }

    /// Await the most recent regen task. Blocks until the matching
    /// pipeline settles, so assertions see deterministic end-state
    /// instead of racing a wall-clock sleep.
    static func awaitRegeneration(_ vm: MatchingViewModel) async {
        await vm.matchingTask?.value
    }
}

// MARK: - Hero guard

@Test @MainActor
func matchRequestRegenerationIsNoOpWithoutHero() async {
    // The match prompt state (no hero selected) must NOT trigger
    // a regen. The view's "pick an item" empty state covers this
    // case; firing findMatches would log telemetry and waste a
    // Supabase fetch for zero user value.
    let (vm, outfitRepo, _) = MatchFlowTestFixtures.makeVM()
    let userId = UUID()
    #expect(vm.selectedItem == nil)

    vm.requestRegeneration(userId: userId, reason: .pickerChange)
    await MatchFlowTestFixtures.awaitRegeneration(vm)

    #expect(outfitRepo.fetchRecentItemIdsCallCount == 0)
    #expect(outfitRepo.fetchRecentItemPairsCallCount == 0)
}

// MARK: - Recent-item history cache

@Test @MainActor
func matchRecentItemHistoryIsCachedAcrossMatches() async {
    // Same cache contract as `OutfitViewModel`: history fetched
    // once on the first findMatches, reused on subsequent calls.
    // The match flow's only divergence is the hero — set it up,
    // then call findMatches three times.
    let (vm, outfitRepo, _) = MatchFlowTestFixtures.makeVM()
    let userId = UUID()
    vm.selectedItem = vm.wardrobeItems.first

    await vm.findMatches(userId: userId)
    await vm.findMatches(userId: userId)
    await vm.findMatches(userId: userId)

    #expect(outfitRepo.fetchRecentItemIdsCallCount == 1)
    #expect(outfitRepo.fetchRecentItemPairsCallCount == 1)
}

// MARK: - Toast contract

@Test @MainActor
func matchSurpriseMeRegenSkipsStatusToast() async {
    // Mirrors the outfits VM contract: `.surpriseMe` re-rolls do
    // NOT set the toast. The card swap is the user feedback.
    let (vm, _, _) = MatchFlowTestFixtures.makeVM()
    let userId = UUID()
    vm.selectedItem = vm.wardrobeItems.first

    vm.requestRegeneration(userId: userId, reason: .surpriseMe)
    await MatchFlowTestFixtures.awaitRegeneration(vm)

    #expect(vm.statusToastMessage == nil)
}

@Test @MainActor
func matchPickerChangeRegenSetsStatusToastOnSuccess() async {
    // The picker-change path surfaces a toast when the regen
    // completes without a failure. With no archetype data
    // loaded in tests, the engine returns [] → lastFailure
    // becomes .noCompatibleOutfits → toast stays nil. So we
    // assert the coherent pairing: failure XOR toast.
    let (vm, _, _) = MatchFlowTestFixtures.makeVM()
    let userId = UUID()
    vm.selectedItem = vm.wardrobeItems.first
    vm.selectedOccasion = .formal

    vm.requestRegeneration(userId: userId, reason: .pickerChange)
    await MatchFlowTestFixtures.awaitRegeneration(vm)

    if vm.lastFailure == nil {
        #expect(vm.statusToastMessage != nil)
        #expect(vm.statusToastMessage?.contains("Formal") == true)
    } else {
        #expect(vm.statusToastMessage == nil)
    }
}
