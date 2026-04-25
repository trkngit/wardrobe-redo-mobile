import Foundation
import Testing
@testable import WardrobeReDo

/// Behavioral tests for `ItemDetailView`'s bounding-box overlay
/// derivation. Like `MultiGarmentGridViewTests`, this suite exercises
/// view-derived flags rather than rendered SwiftUI output (the project
/// has no `ViewInspector` dependency).
///
/// The overlay itself is a visual concern verified by the PR's manual
/// test plan; the unit cases below pin down the trigger condition —
/// `item.boundingBox != nil` — so a future refactor can't silently drop
/// the multi-pick disambiguation feature.
@MainActor
struct ItemDetailViewTests {

    @Test func overlayVisibleWhenBoundingBoxPresent() {
        let item = TestFixtures.makeWardrobeItem(
            boundingBox: BoundingBoxCodable(
                x: 0.1, y: 0.4, width: 0.3, height: 0.5
            )
        )
        let view = ItemDetailView(item: item)

        #expect(view.shouldShowBoundingBoxOverlay)
    }

    @Test func overlayHiddenWhenBoundingBoxNil() {
        let item = TestFixtures.makeWardrobeItem(boundingBox: nil)
        let view = ItemDetailView(item: item)

        #expect(!view.shouldShowBoundingBoxOverlay)
    }
}
