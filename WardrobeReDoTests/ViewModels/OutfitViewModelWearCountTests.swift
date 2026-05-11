import Foundation
import Testing
@testable import WardrobeReDo

// MARK: - OutfitViewModel.toggleWorn wear-count hook (build 6)
//
// Phase 5.1 added the novelty bonus to VersatilityScorer. That
// math is only as good as the wear data underneath it — and
// pre-build-6, `wear_count` was never updated when the user
// marked an outfit as worn. This commit wires the hook; these
// tests pin the contract:
//
//   1. toggling un-worn → worn fires the wear-count RPC with
//      every item id in the outfit.
//   2. toggling worn → un-worn does NOT fire the RPC (wear is
//      monotonically increasing).
//   3. an RPC failure doesn't roll back the worn flag — the
//      observable behaviour (the heart icon filling) survives
//      even if the derived signal misses an update.

@MainActor
struct OutfitViewModelWearCountTests {

    @Test func togglingUnwornToWornFiresIncrementForEveryItem() async throws {
        let outfitId = UUID()
        let itemA = UUID()
        let itemB = UUID()

        let outfitRepo = MockOutfitRepository()
        let wardrobeRepo = MockWardrobeRepository()
        let imageService = MockImageService()
        let vm = OutfitViewModel(
            outfitRepository: outfitRepo,
            wardrobeRepository: wardrobeRepo,
            imageService: imageService
        )

        let outfit = TestFixtures.makeOutfit(id: outfitId, isWorn: false)
        let items = [
            TestFixtures.makeWardrobeItem(id: itemA, category: .top, subcategory: .tshirt),
            TestFixtures.makeWardrobeItem(id: itemB, category: .bottom, subcategory: .jeans),
        ]
        let slots = [
            OutfitSlot(id: UUID(), outfitId: outfitId, wardrobeItemId: itemA, slotName: "top", role: "hero"),
            OutfitSlot(id: UUID(), outfitId: outfitId, wardrobeItemId: itemB, slotName: "bottom", role: "supporting"),
        ]
        vm.dailyOutfits = [DailyOutfit(outfit: outfit, slots: slots, items: items)]

        await vm.toggleWorn(outfitId: outfitId)

        #expect(outfitRepo.markAsWornCallCount == 1)
        #expect(outfitRepo.lastIsWorn == true)
        #expect(outfitRepo.incrementWearCountsCallCount == 1)
        #expect(Set(outfitRepo.lastIncrementWearCountIds) == Set([itemA, itemB]))
    }

    @Test func togglingWornToUnwornDoesNotFireIncrement() async throws {
        let outfitId = UUID()
        let outfitRepo = MockOutfitRepository()
        let wardrobeRepo = MockWardrobeRepository()
        let imageService = MockImageService()
        let vm = OutfitViewModel(
            outfitRepository: outfitRepo,
            wardrobeRepository: wardrobeRepo,
            imageService: imageService
        )

        let outfit = TestFixtures.makeOutfit(id: outfitId, isWorn: true)
        let itemId = UUID()
        let items = [TestFixtures.makeWardrobeItem(id: itemId, category: .top, subcategory: .tshirt)]
        let slots = [OutfitSlot(id: UUID(), outfitId: outfitId, wardrobeItemId: itemId, slotName: "top", role: "hero")]
        vm.dailyOutfits = [DailyOutfit(outfit: outfit, slots: slots, items: items)]

        await vm.toggleWorn(outfitId: outfitId)

        #expect(outfitRepo.markAsWornCallCount == 1)
        #expect(outfitRepo.lastIsWorn == false)
        // Wear is monotonic — un-wearing doesn't decrement.
        #expect(outfitRepo.incrementWearCountsCallCount == 0)
    }

    @Test func rpcFailureDoesNotRollBackWornFlag() async throws {
        let outfitId = UUID()
        let outfitRepo = MockOutfitRepository()
        outfitRepo.incrementWearCountsError = NSError(domain: "test", code: -1)
        let wardrobeRepo = MockWardrobeRepository()
        let imageService = MockImageService()
        let vm = OutfitViewModel(
            outfitRepository: outfitRepo,
            wardrobeRepository: wardrobeRepo,
            imageService: imageService
        )

        let outfit = TestFixtures.makeOutfit(id: outfitId, isWorn: false)
        let itemId = UUID()
        let items = [TestFixtures.makeWardrobeItem(id: itemId, category: .top, subcategory: .tshirt)]
        let slots = [OutfitSlot(id: UUID(), outfitId: outfitId, wardrobeItemId: itemId, slotName: "top", role: "hero")]
        vm.dailyOutfits = [DailyOutfit(outfit: outfit, slots: slots, items: items)]

        await vm.toggleWorn(outfitId: outfitId)

        // markAsWorn succeeded; increment failed; outfit still reads
        // as worn locally.
        #expect(outfitRepo.markAsWornCallCount == 1)
        #expect(outfitRepo.incrementWearCountsCallCount == 1)
        #expect(vm.dailyOutfits.first?.outfit.isWorn == true)
    }
}
