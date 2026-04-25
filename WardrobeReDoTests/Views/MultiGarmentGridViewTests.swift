import CoreGraphics
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import WardrobeReDo

/// Structural tests for `MultiGarmentGridView`'s derived lists and
/// summary copy. Focused on logic that doesn't need a live render loop:
///
///   - `sortedProposals` orders detected items by descending confidence
///     so the highest-scoring garment is the user's first eye-catch.
///   - `selectionSummary` formats the "X of Y" subtitle.
///   - `confirmButtonTitle` pluralizes the CTA correctly (1 item vs N).
///
/// Snapshot regression for the actual card layout is deferred to the
/// project's existing snapshot suite; this file covers the behaviors a
/// snapshot test wouldn't catch (counts, ordering, copy).
@MainActor
struct MultiGarmentGridViewTests {

    // MARK: - sortedProposals

    @Test func sortedProposalsOrdersByDescendingScore() {
        let mid = MaskProposalFixture.make(detectionScore: 0.7)
        let high = MaskProposalFixture.make(detectionScore: 0.95)
        let low = MaskProposalFixture.make(detectionScore: 0.5)
        let view = makeView(proposals: [mid, low, high], selectedIDs: [])

        let ids = view.sortedProposals.map(\.id)
        #expect(ids == [high.id, mid.id, low.id])
    }

    @Test func sortedProposalsHandlesEmptyInput() {
        let view = makeView(proposals: [], selectedIDs: [])
        #expect(view.sortedProposals.isEmpty)
    }

    @Test func sortedProposalsKeepsAllItems() {
        // No 5-item cap (the old overlay design's "+N more" sheet is
        // gone — the grid scrolls).
        let proposals = (0..<10).map { i in
            MaskProposalFixture.make(detectionScore: Float(0.9 - Double(i) * 0.05))
        }
        let view = makeView(proposals: proposals, selectedIDs: [])
        #expect(view.sortedProposals.count == 10)
    }

    // MARK: - selectionSummary

    @Test func selectionSummaryFormatsCountAndTotal() {
        let proposals = (0..<3).map { _ in MaskProposalFixture.make() }
        let selected = Set(proposals.prefix(2).map(\.id))
        let view = makeView(proposals: proposals, selectedIDs: selected)
        #expect(view.selectionSummary == "2 of 3 selected")
    }

    @Test func selectionSummaryWhenNothingSelected() {
        let proposals = (0..<4).map { _ in MaskProposalFixture.make() }
        let view = makeView(proposals: proposals, selectedIDs: [])
        #expect(view.selectionSummary == "0 of 4 selected")
    }

    // MARK: - confirmButtonTitle

    @Test func confirmButtonTitleIsSingularForOneItem() {
        let proposals = (0..<3).map { _ in MaskProposalFixture.make() }
        let selected: Set<MaskProposal.ID> = [proposals[0].id]
        let view = makeView(proposals: proposals, selectedIDs: selected)
        #expect(view.confirmButtonTitle == "Save 1 item")
    }

    @Test func confirmButtonTitleIsPluralForMultipleItems() {
        let proposals = (0..<4).map { _ in MaskProposalFixture.make() }
        let selected = Set(proposals.prefix(3).map(\.id))
        let view = makeView(proposals: proposals, selectedIDs: selected)
        #expect(view.confirmButtonTitle == "Save 3 items")
    }

    @Test func confirmButtonTitleIsZeroWhenNothingSelected() {
        let proposals = (0..<4).map { _ in MaskProposalFixture.make() }
        let view = makeView(proposals: proposals, selectedIDs: [])
        #expect(view.confirmButtonTitle == "Save 0 items")
    }

    // MARK: - Helpers

    private func makeView(
        proposals: [MaskProposal],
        selectedIDs: Set<MaskProposal.ID>
    ) -> MultiGarmentGridView {
        let box = SelectionBox(value: selectedIDs)
        return MultiGarmentGridView(
            proposals: proposals,
            selectedIDs: Binding(
                get: { box.value },
                set: { box.value = $0 }
            ),
            onConfirmed: {},
            onUseFullPhoto: {},
            onCancel: {}
        )
    }

    /// Stable backing store for `Binding` — same pattern the old
    /// MultiGarmentTapToSelectView tests used. Avoids pulling in
    /// SwiftUI's `State` runtime in a unit-test context.
    private final class SelectionBox {
        var value: Set<MaskProposal.ID>
        init(value: Set<MaskProposal.ID>) { self.value = value }
    }
}
