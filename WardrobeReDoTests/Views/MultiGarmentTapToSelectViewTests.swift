import CoreGraphics
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import WardrobeReDo

/// Structural tests for `MultiGarmentTapToSelectView`'s layout math and
/// derived lists. Keeping the logic in `static` helpers + `Binding`-fed
/// computed properties means we can verify the view's behavior without
/// a live render loop — regressions show up as plain assertion failures
/// rather than flaky snapshot diffs.
///
/// Snapshot regression (per plan Section 13.3) is deferred until
/// `swift-snapshot-testing` lands as a dependency; this suite covers
/// the behaviors that would otherwise be silent.
@MainActor
struct MultiGarmentTapToSelectViewTests {

    // MARK: - displayRect math

    @Test func displayRectCentersLandscapeImageInPortraitContainer() {
        let rect = MultiGarmentTapToSelectView.displayRect(
            for: CGSize(width: 2000, height: 1000),
            in: CGSize(width: 400, height: 800)
        )
        // 2000×1000 in 400×800 → scale 0.2 (400/2000 < 800/1000)
        // width 400, height 200, letterboxed vertically.
        #expect(rect.width == 400)
        #expect(rect.height == 200)
        #expect(rect.origin.x == 0)
        #expect(rect.origin.y == 300) // (800 - 200) / 2
    }

    @Test func displayRectCentersPortraitImageInLandscapeContainer() {
        let rect = MultiGarmentTapToSelectView.displayRect(
            for: CGSize(width: 500, height: 1000),
            in: CGSize(width: 800, height: 400)
        )
        // scale = min(800/500, 400/1000) = min(1.6, 0.4) = 0.4
        // width 200, height 400
        #expect(rect.width == 200)
        #expect(rect.height == 400)
        #expect(rect.origin.x == 300) // (800 - 200) / 2
        #expect(rect.origin.y == 0)
    }

    @Test func displayRectReturnsZeroForDegenerateSize() {
        let zero = MultiGarmentTapToSelectView.displayRect(
            for: .zero,
            in: CGSize(width: 100, height: 100)
        )
        #expect(zero == .zero)

        let emptyContainer = MultiGarmentTapToSelectView.displayRect(
            for: CGSize(width: 100, height: 100),
            in: .zero
        )
        #expect(emptyContainer == .zero)
    }

    // MARK: - viewRect math

    @Test func viewRectScalesNormalizedBoxIntoDisplayRect() {
        let display = CGRect(x: 10, y: 20, width: 200, height: 400)
        let bbox = CGRect(x: 0.25, y: 0.5, width: 0.5, height: 0.25)
        let view = MultiGarmentTapToSelectView.viewRect(for: bbox, in: display)

        // Explicit CGFloat literals — Swift won't implicitly widen
        // `Int` to `CGFloat` in `#expect`.
        #expect(view.origin.x == CGFloat(60))   // 10 + 0.25 * 200
        #expect(view.origin.y == CGFloat(220))  // 20 + 0.5 * 400
        #expect(view.width == CGFloat(100))     // 0.5 * 200
        #expect(view.height == CGFloat(100))    // 0.25 * 400
    }

    // MARK: - tintColor stability

    @Test func tintColorIsStableForTheSameProposal() {
        let proposal = MaskProposalFixture.make()
        let first = MultiGarmentTapToSelectView.tintColor(for: proposal)
        let second = MultiGarmentTapToSelectView.tintColor(for: proposal)
        #expect(first == second)
    }

    @Test func tintColorIsDrawnFromTheDocumentedPalette() {
        let proposal = MaskProposalFixture.make()
        let color = MultiGarmentTapToSelectView.tintColor(for: proposal)
        #expect(MultiGarmentTapToSelectView.proposalPalette.contains(color))
    }

    // MARK: - Derived proposal lists

    @Test func displayedProposalsCapsAtFiveHighestScores() {
        // Descending scores: 0.9, 0.85, 0.8, ...
        let proposals = (0..<8).map { i in
            MaskProposalFixture.make(
                boundingBox: CGRect(x: 0, y: 0, width: 0.1 + Double(i) * 0.05, height: 0.1),
                detectionScore: Float(0.9 - Double(i) * 0.05)
            )
        }
        let view = makeView(proposals: proposals, selectedIDs: [])
        #expect(view.displayedProposals.count == MultiGarmentTapToSelectView.displayedProposalCap)
        #expect(view.overflowProposals.count == 3)
    }

    @Test func displayedProposalsRendersLargestBoxFirst() {
        let big = MaskProposalFixture.make(
            boundingBox: CGRect(x: 0, y: 0, width: 0.8, height: 0.8),
            detectionScore: 0.6
        )
        let small = MaskProposalFixture.make(
            boundingBox: CGRect(x: 0, y: 0, width: 0.2, height: 0.2),
            detectionScore: 0.9
        )
        let view = makeView(proposals: [small, big], selectedIDs: [])
        // Even though `small` has a higher score, in the display list
        // `big` comes first so `small`'s chip renders on top (tappable).
        #expect(view.displayedProposals.first?.id == big.id)
        #expect(view.displayedProposals.last?.id == small.id)
    }

    @Test func overflowProposalsEmptyWhenUnderCap() {
        let proposals = (0..<3).map { _ in MaskProposalFixture.make() }
        let view = makeView(proposals: proposals, selectedIDs: [])
        #expect(view.overflowProposals.isEmpty)
    }

    // MARK: - Summary + CTA copy

    @Test func selectionSummaryFormatsCountAndTotal() {
        let proposals = (0..<3).map { _ in MaskProposalFixture.make() }
        let selected = Set(proposals.prefix(2).map(\.id))
        let view = makeView(proposals: proposals, selectedIDs: selected)
        #expect(view.selectionSummary == "2 of 3 selected")
    }

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
    ) -> MultiGarmentTapToSelectView {
        // Use a stable wrapper so `@Binding` has somewhere to live.
        let box = SelectionBox(value: selectedIDs)
        return MultiGarmentTapToSelectView(
            sourceImage: UIImage(systemName: "photo") ?? UIImage(),
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

    /// Plain reference box so `Binding` has a live backing store in
    /// tests — avoids pulling in SwiftUI's `State` runtime.
    private final class SelectionBox {
        var value: Set<MaskProposal.ID>
        init(value: Set<MaskProposal.ID>) { self.value = value }
    }
}
