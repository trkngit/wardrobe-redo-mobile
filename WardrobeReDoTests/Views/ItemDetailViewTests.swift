import Foundation
import Testing
@testable import WardrobeReDo

/// Behavioral tests for `ItemDetailView`'s hero-image derivation. Like
/// `MultiGarmentGridViewTests`, this exercises a view-derived value
/// rather than rendered SwiftUI output (the project has no
/// `ViewInspector` dependency).
///
/// Build 50 — the detail hero switched from the full source photo (with
/// a dim+outline bounding-box highlight overlay) to the per-item cutout,
/// matching the grid card. The overlay's outline mislanded in the
/// bottom-right corner (TF feedback #3342). These cases pin
/// `heroImagePath` so a refactor can't silently send the hero back to
/// the raw source photo.
@MainActor
struct ItemDetailViewTests {

    @Test func heroUsesCutoutWhenMaskAvailable() {
        let item = TestFixtures.makeWardrobeItem(maskedImagePath: "masked/jacket.png")
        let view = ItemDetailView(item: item)

        #expect(view.heroImagePath == "masked/jacket.png")
    }

    @Test func heroFallsBackToThumbnailWhenNoMask() {
        let id = UUID()
        let item = TestFixtures.makeWardrobeItem(id: id, maskedImagePath: nil)
        let view = ItemDetailView(item: item)

        // ItemCardView.displayPath falls back to the framed thumbnail
        // when there's no cutout — never the raw source photo.
        #expect(view.heroImagePath == "thumbnails/\(id).jpg")
    }
}
