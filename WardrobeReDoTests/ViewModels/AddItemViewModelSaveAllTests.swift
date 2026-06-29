import Foundation
import Testing
import UIKit
@testable import WardrobeReDo

/// Build 52 — Phase 2 "Save all N" approval-gallery path.
///
/// The gallery's single button commits every selected proposal in ONE pass
/// via the view model's fast-save loop (no per-item Fast Confirm card),
/// applying per-card category corrections and one shared occasion. These
/// tests lock that contract plus the source-photo dedup, the
/// no-`.details`-stop behavior, and the reset hygiene.
///
/// `.serialized` because the path is gated on `FeatureFlags.isFastAddEnabled`
/// (UserDefaults-backed global) — mirrors `AddItemViewModelBatchProgressTests`.
@MainActor
@Suite("AddItemViewModel.saveAll", .serialized)
struct AddItemViewModelSaveAllTests {

    // MARK: - Helpers

    private func makeBatchVM(
        mockImage: MockImageService,
        mockRepo: MockWardrobeRepository,
        proposals: [MaskProposal]
    ) -> AddItemViewModel {
        let vm = AddItemViewModel(imageService: mockImage, wardrobeRepository: mockRepo)
        vm.proposals = proposals
        vm.selectedProposalIDs = Set(proposals.map(\.id))
        vm.sourcePhotoId = UUID()
        // A non-nil processedImage so `startNextProposal`'s per-proposal cutout
        // swap runs (it guards on `if let current = processedImage`).
        vm.processedImage = ProcessedImage(
            originalData: Data([0xFF]),
            thumbnailData: Data([0xFF]),
            maskedData: Data([0xAB]),
            extractionConfidence: .high,
            extractionMethod: .multiGarmentRFDETR,
            dominantColors: []
        )
        return vm
    }

    private func makeProposal(
        category: ClothingCategory,
        occasions: [Occasion] = [],
        score: Float = 0.9
    ) -> MaskProposal {
        MaskProposalFixture.make(
            predictedCategory: category,
            predictedOccasions: occasions,
            detectionScore: score
        )
    }

    // MARK: - Tests

    @Test func saveAllSavesEveryItemWithoutDetailsStop() async {
        await FeatureFlagTestIsolation.shared.acquire()
        defer { Task { await FeatureFlagTestIsolation.shared.release() } }
        FeatureFlags.resetAll()             // Fast Add + multi-garment default on
        defer { FeatureFlags.resetAll() }

        let mockImage = MockImageService()
        let mockRepo = MockWardrobeRepository()
        let proposals = [
            makeProposal(category: .top, score: 0.9),
            makeProposal(category: .bottom, score: 0.85),
            makeProposal(category: .shoe, score: 0.8),
        ]
        let vm = makeBatchVM(mockImage: mockImage, mockRepo: mockRepo, proposals: proposals)

        await vm.onSaveAllConfirmed(userId: UUID())

        #expect(mockRepo.insertItemCallCount == 3)
        #expect(vm.savedItemsFromSource == 3)
        #expect(vm.didSave == true, "queue drained with saves → batch done → sheet dismisses")
        #expect(vm.currentStep != .details, "fast-save never stops on the per-item form")
        #expect(vm.batchSkippedCount == 0)
        #expect(vm.isFastSaveAll == false, "Save-all state clears when the queue drains")
    }

    @Test func saveAllAppliesOneSharedOccasionToEveryItem() async {
        await FeatureFlagTestIsolation.shared.acquire()
        defer { Task { await FeatureFlagTestIsolation.shared.release() } }
        FeatureFlags.resetAll()
        defer { FeatureFlags.resetAll() }

        let mockImage = MockImageService()
        let mockRepo = MockWardrobeRepository()
        // Each proposal predicts a DIFFERENT occasion; the one batch override
        // must win for all of them.
        let proposals = [
            makeProposal(category: .top, occasions: [.casual], score: 0.9),
            makeProposal(category: .bottom, occasions: [.work], score: 0.85),
            makeProposal(category: .dress, occasions: [.athletic], score: 0.8),
        ]
        let vm = makeBatchVM(mockImage: mockImage, mockRepo: mockRepo, proposals: proposals)
        vm.sharedBatchOccasions = [.formal]

        await vm.onSaveAllConfirmed(userId: UUID())

        #expect(mockRepo.insertedItems.count == 3)
        #expect(
            mockRepo.insertedItems.allSatisfy { $0.occasions == [Occasion.formal.rawValue] },
            "the one shared occasion overrides each proposal's ML occasion"
        )
    }

    @Test func saveAllAppliesPerCardCategoryOverride() async {
        await FeatureFlagTestIsolation.shared.acquire()
        defer { Task { await FeatureFlagTestIsolation.shared.release() } }
        FeatureFlags.resetAll()
        defer { FeatureFlags.resetAll() }

        let mockImage = MockImageService()
        let mockRepo = MockWardrobeRepository()
        let p1 = makeProposal(category: .top, score: 0.9)
        let p2 = makeProposal(category: .top, score: 0.85)   // model says .top...
        let vm = makeBatchVM(mockImage: mockImage, mockRepo: mockRepo, proposals: [p1, p2])
        // ...user corrects p2 to .shoe on its card.
        vm.proposalCategoryOverrides[p2.id] = .shoe

        await vm.onSaveAllConfirmed(userId: UUID())

        #expect(mockRepo.insertedItems.count == 2)
        let categories = mockRepo.insertedItems.map(\.category)
        #expect(categories.filter { $0 == ClothingCategory.shoe.rawValue }.count == 1,
                "exactly the corrected item persists the override")
        #expect(categories.filter { $0 == ClothingCategory.top.rawValue }.count == 1,
                "the un-corrected item keeps its ML category")
    }

    @Test func saveAllUploadsSourcePhotoOnceForTheBatch() async {
        await FeatureFlagTestIsolation.shared.acquire()
        defer { Task { await FeatureFlagTestIsolation.shared.release() } }
        FeatureFlags.resetAll()
        defer { FeatureFlags.resetAll() }

        let mockImage = MockImageService()
        mockImage.uploadSourcePhotoPath = "users/abc/source/cap-1/original.jpg"
        let mockRepo = MockWardrobeRepository()
        let proposals = [
            makeProposal(category: .top, score: 0.9),
            makeProposal(category: .bottom, score: 0.85),
            makeProposal(category: .shoe, score: 0.8),
        ]
        let vm = makeBatchVM(mockImage: mockImage, mockRepo: mockRepo, proposals: proposals)

        await vm.onSaveAllConfirmed(userId: UUID())

        #expect(mockImage.uploadCallCount == 3, "one upload call per item")
        // The LAST upload (item 3) must have carried the cached source path so
        // ImageService skips re-uploading the shared source photo for 2..N.
        #expect(
            (mockImage.lastUploadExistingSourcePhotoPath ?? "NEVER-CALLED")
                == "users/abc/source/cap-1/original.jpg",
            "items 2..N reuse the cached source path (no re-upload)"
        )
    }

    @Test func saveAllStateResetsOnCancel() async {
        await FeatureFlagTestIsolation.shared.acquire()
        defer { Task { await FeatureFlagTestIsolation.shared.release() } }
        FeatureFlags.resetAll()
        defer { FeatureFlags.resetAll() }

        let vm = AddItemViewModel()
        let proposal = makeProposal(category: .top)
        vm.proposals = [proposal]
        vm.selectedProposalIDs = [proposal.id]
        vm.proposalCategoryOverrides[proposal.id] = .shoe
        vm.sharedBatchOccasions = [.formal]
        vm.isFastSaveAll = true
        vm.fastSaveUserId = UUID()

        vm.onMultiPickCancelled()

        #expect(vm.proposalCategoryOverrides.isEmpty)
        #expect(vm.sharedBatchOccasions == [.casual])
        #expect(vm.isFastSaveAll == false)
        #expect(vm.fastSaveUserId == nil)
    }
}
