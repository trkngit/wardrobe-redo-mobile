import Foundation
import Testing
import UIKit
@testable import WardrobeReDo

/// Coverage for the per-batch progress counters added to
/// `AddItemViewModel`. The `AddItemView` reads these to decide whether
/// to render the batch progress bar at the top of the screen and what
/// percentage to fill.
///
/// Three contracts:
///   1. `batchTotalCount` is set when the user confirms the multi-pick
///      grid, and equals the number of selected proposals.
///   2. `batchSkippedCount` increments on every `onSkipCurrentProposal`
///      call so progress advances even for opted-out items.
///   3. Every batch-end path resets both counters to 0 so the next
///      single-item flow doesn't accidentally render the bar.
@MainActor
@Suite("AddItemViewModel.batchProgress", .serialized)
struct AddItemViewModelBatchProgressTests {

    // MARK: - confirm sets total

    @Test func multiPickConfirmStampsBatchTotal() async {
        await FeatureFlagTestIsolation.shared.acquire()
        defer { Task { await FeatureFlagTestIsolation.shared.release() } }
        FeatureFlags.resetAll()

        let vm = AddItemViewModel()
        let proposals = (0..<3).map { _ in MaskProposalFixture.make() }
        vm.proposals = proposals
        vm.selectedProposalIDs = Set(proposals.map(\.id))

        vm.onMultiPickConfirmed()

        #expect(vm.batchTotalCount == 3)
        #expect(vm.batchSkippedCount == 0)
    }

    @Test func multiPickConfirmReflectsOnlySelectedProposals() async {
        await FeatureFlagTestIsolation.shared.acquire()
        defer { Task { await FeatureFlagTestIsolation.shared.release() } }
        FeatureFlags.resetAll()

        let vm = AddItemViewModel()
        let proposals = (0..<5).map { _ in MaskProposalFixture.make() }
        vm.proposals = proposals
        // Only 2 of 5 selected.
        vm.selectedProposalIDs = Set(proposals.prefix(2).map(\.id))

        vm.onMultiPickConfirmed()

        #expect(vm.batchTotalCount == 2)
    }

    // MARK: - skip increments

    @Test func skipIncrementsSkippedCounter() async {
        await FeatureFlagTestIsolation.shared.acquire()
        defer { Task { await FeatureFlagTestIsolation.shared.release() } }
        FeatureFlags.resetAll()

        let vm = AddItemViewModel()
        let proposals = (0..<3).map { _ in MaskProposalFixture.make() }
        vm.proposals = proposals
        vm.selectedProposalIDs = Set(proposals.map(\.id))
        vm.onMultiPickConfirmed()

        vm.onSkipCurrentProposal()
        #expect(vm.batchSkippedCount == 1)

        vm.onSkipCurrentProposal()
        #expect(vm.batchSkippedCount == 2)
    }

    // MARK: - cancel resets

    @Test func multiPickCancelClearsBatchCounters() async {
        await FeatureFlagTestIsolation.shared.acquire()
        defer { Task { await FeatureFlagTestIsolation.shared.release() } }
        FeatureFlags.resetAll()

        let vm = AddItemViewModel()
        let proposals = (0..<3).map { _ in MaskProposalFixture.make() }
        vm.proposals = proposals
        vm.selectedProposalIDs = Set(proposals.map(\.id))
        vm.onMultiPickConfirmed()
        vm.onSkipCurrentProposal()

        // Confirm the cancel path zeros everything so the next photo
        // opens with the bar hidden.
        vm.onMultiPickCancelled()
        #expect(vm.batchTotalCount == 0)
        #expect(vm.batchSkippedCount == 0)
    }
}
