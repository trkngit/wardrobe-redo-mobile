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

    // MARK: - shouldShowLayeredLookHint

    /// A large `.top` proposal — t-shirt + open overshirt photographed
    /// together typically detects as a single torso-spanning blob — should
    /// flip the layered-look hint on so the user knows to re-shoot.
    @Test func layeredLookHintShowsForLargeTopProposal() {
        let bigTop = MaskProposalFixture.make(
            predictedCategory: .top,
            boundingBox: CGRect(x: 0.05, y: 0.05, width: 0.9, height: 0.5)
        )
        let view = makeView(proposals: [bigTop], selectedIDs: [])
        #expect(view.shouldShowLayeredLookHint)
    }

    /// A small / well-cropped `.top` (a single t-shirt photographed at
    /// arm's length) shouldn't trigger the hint — the common case stays
    /// quiet.
    @Test func layeredLookHintHiddenForSmallTopProposal() {
        let smallTop = MaskProposalFixture.make(
            predictedCategory: .top,
            boundingBox: CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4)
        )
        let view = makeView(proposals: [smallTop], selectedIDs: [])
        #expect(!view.shouldShowLayeredLookHint)
    }

    /// A large bottom or outerwear shouldn't trigger the hint — it only
    /// fires for `.top` proposals because that's where layering ambiguity
    /// happens.
    @Test func layeredLookHintIgnoresLargeNonTopProposal() {
        let bigBottom = MaskProposalFixture.make(
            predictedCategory: .bottom,
            boundingBox: CGRect(x: 0.0, y: 0.4, width: 1.0, height: 0.6)
        )
        let view = makeView(proposals: [bigBottom], selectedIDs: [])
        #expect(!view.shouldShowLayeredLookHint)
    }

    /// Threshold is strict-greater-than 0.30 — exactly 30% of the frame
    /// is treated as "not large enough" and stays quiet. We pin the
    /// bbox width to the threshold itself (height = 1.0) to dodge
    /// floating-point ambiguity from a bare 0.5 × 0.6 multiplication.
    @Test func layeredLookHintHiddenAtThresholdBoundary() {
        let exactlyThreshold = MaskProposalFixture.make(
            predictedCategory: .top,
            boundingBox: CGRect(
                x: 0.0,
                y: 0.0,
                width: MultiGarmentGridView.layeredLookAreaThreshold,
                height: 1.0
            )
        )
        let view = makeView(proposals: [exactlyThreshold], selectedIDs: [])
        #expect(!view.shouldShowLayeredLookHint)
    }

    /// One large `.top` mixed with otherwise small proposals is enough
    /// to trip the hint — the heuristic is "any" not "all".
    @Test func layeredLookHintFiresWhenAnyTopExceedsThreshold() {
        let smallShoe = MaskProposalFixture.make(
            predictedCategory: .shoe,
            boundingBox: CGRect(x: 0.1, y: 0.8, width: 0.15, height: 0.1)
        )
        let bigTop = MaskProposalFixture.make(
            predictedCategory: .top,
            boundingBox: CGRect(x: 0.05, y: 0.05, width: 0.9, height: 0.5)
        )
        let view = makeView(proposals: [smallShoe, bigTop], selectedIDs: [])
        #expect(view.shouldShowLayeredLookHint)
    }

    @Test func layeredLookHintHiddenWhenNoProposals() {
        let view = makeView(proposals: [], selectedIDs: [])
        #expect(!view.shouldShowLayeredLookHint)
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
