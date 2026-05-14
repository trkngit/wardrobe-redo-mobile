import SnapshotTesting
import SwiftUI
import XCTest
@testable import WardrobeReDo

/// Build 23 — visual regression net for `ItemCardView`, the cell
/// that fills the wardrobe grid. Touches typography (subcategory
/// name, category caption), color (background, border), and image
/// rendering (placeholder when no thumbnail URL is provided).
///
/// Renders without a network — the test passes `thumbnailURL: nil`
/// so KFImage falls through to its placeholder. The placeholder
/// itself is part of the regression target because it's the
/// fallback users see when signed URLs are still resolving.
@MainActor
final class ItemCardViewSnapshotTests: XCTestCase {

    func testItemCard_defaultState() {
        let host = ItemCardSnapshotHost()
        assertSnapshot(
            of: host,
            as: .image(layout: .fixed(width: 180, height: 240)),
            record: .missing
        )
    }
}

@MainActor
private struct ItemCardSnapshotHost: View {
    var body: some View {
        ItemCardView(
            item: TestFixtures.makeWardrobeItem(category: .top, subcategory: .tshirt),
            thumbnailURL: nil
        )
        .padding()
    }
}
