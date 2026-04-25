import Foundation
import Testing
import UIKit
@testable import WardrobeReDo

/// Coverage for `AddItemViewModel.restorePersistedBatchIfNeeded(currentUserId:)`
/// — the resume path that hydrates a persisted multi-pick batch back
/// into the VM after a jetsam.
///
/// Three contracts:
///   1. Restore lands on the details step with `currentProposal` set
///      from the snapshot, queue + counters preserved.
///   2. Snapshot belonging to a different user is discarded —
///      `restorePersistedBatchIfNeeded` returns false and the disk
///      state is cleared so the new user gets a fresh start.
///   3. The `didJustRestoreBatch` flag flips true so the view can
///      show the resume toast.
@MainActor
@Suite("AddItemViewModel.batchRestore", .serialized)
struct AddItemViewModelBatchRestoreTests {

    /// Wipe persisted batch state before/after each test so they don't
    /// leak into each other. Phase-2 service file is on disk; tests
    /// that exercise it must be tidy.
    private func cleanSlate() {
        BatchPersistenceService.clear()
    }

    // MARK: - Happy path

    @Test func restoreLandsOnDetailsStepWithCurrentProposal() async {
        cleanSlate()
        defer { cleanSlate() }

        let userId = UUID()
        let proposal = MaskProposalFixture.make(
            predictedCategory: .bottom,
            predictedCategoryConfidence: 0.95,
            predictedSubcategory: .jeans,
            predictedTexture: .denim,
            predictedTextureConfidence: 0.85
        )
        guard let persisted = PersistedProposal(from: proposal) else {
            Issue.record("could not encode proposal")
            return
        }

        let snapshot = BatchSnapshot(
            userId: userId,
            sourcePhotoId: UUID(),
            sourcePhotoPath: nil,
            sourcePhotoPNG: nil,
            createdAt: Date(),
            total: 4,
            savedCount: 1,
            skippedCount: 1,
            queue: [persisted, persisted],
            currentProposal: persisted
        )
        BatchPersistenceService.save(snapshot)

        let vm = AddItemViewModel()
        let restored = vm.restorePersistedBatchIfNeeded(currentUserId: userId)

        #expect(restored == true)
        #expect(vm.currentStep == .details)
        #expect(vm.currentProposal?.id == proposal.id)
        #expect(vm.pendingProposalQueue.count == 2)
        #expect(vm.batchTotalCount == 4)
        #expect(vm.savedItemsFromSource == 1)
        #expect(vm.batchSkippedCount == 1)
        #expect(vm.didJustRestoreBatch == true)
    }

    // MARK: - User mismatch

    @Test func restoreDiscardsSnapshotFromDifferentUser() async {
        cleanSlate()
        defer { cleanSlate() }

        let originalUserId = UUID()
        let differentUserId = UUID()
        let proposal = MaskProposalFixture.make()
        guard let persisted = PersistedProposal(from: proposal) else { return }

        let snapshot = BatchSnapshot(
            userId: originalUserId,
            sourcePhotoId: UUID(),
            sourcePhotoPath: nil,
            sourcePhotoPNG: nil,
            createdAt: Date(),
            total: 2,
            savedCount: 0,
            skippedCount: 0,
            queue: [],
            currentProposal: persisted
        )
        BatchPersistenceService.save(snapshot)

        let vm = AddItemViewModel()
        let restored = vm.restorePersistedBatchIfNeeded(currentUserId: differentUserId)

        #expect(restored == false)
        #expect(vm.currentStep == .photo, "VM stays at photo step on mismatch")
        #expect(vm.currentProposal == nil)
        #expect(vm.didJustRestoreBatch == false)
        // And the snapshot is wiped so future restores don't see
        // someone else's state.
        #expect(BatchPersistenceService.load() == nil)
    }

    // MARK: - No snapshot

    @Test func restoreReturnsFalseWhenNoSnapshot() async {
        cleanSlate()

        let vm = AddItemViewModel()
        let restored = vm.restorePersistedBatchIfNeeded(currentUserId: UUID())

        #expect(restored == false)
        #expect(vm.didJustRestoreBatch == false)
    }

    // MARK: - Snapshot without currentProposal

    @Test func restoreSkipsSnapshotMissingCurrentProposal() async {
        cleanSlate()
        defer { cleanSlate() }

        let userId = UUID()
        let snapshot = BatchSnapshot(
            userId: userId,
            sourcePhotoId: UUID(),
            sourcePhotoPath: nil,
            sourcePhotoPNG: nil,
            createdAt: Date(),
            total: 0,
            savedCount: 0,
            skippedCount: 0,
            queue: [],
            currentProposal: nil // no current item — corrupt state
        )
        BatchPersistenceService.save(snapshot)

        let vm = AddItemViewModel()
        let restored = vm.restorePersistedBatchIfNeeded(currentUserId: userId)

        #expect(restored == false)
        // Corrupt snapshot is cleared so a future load is clean.
        #expect(BatchPersistenceService.load() == nil)
    }
}
