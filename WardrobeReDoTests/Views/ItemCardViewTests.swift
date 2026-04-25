import Foundation
import Testing
@testable import WardrobeReDo

/// Tests for `ItemCardView.displayPath(for:)` — the helper that decides
/// which Storage path to load for a wardrobe card thumbnail. Preferring
/// `maskedImagePath` (the cropped cutout) over `thumbnailPath` (the
/// framed source photo) is what makes two items extracted from the same
/// mirror selfie look distinct in the grid.
@MainActor
@Suite("ItemCardView.displayPath")
struct ItemCardViewTests {

    @Test func maskedImagePathPreferredWhenPresent() {
        let item = TestFixtures.makeWardrobeItem(
            maskedImagePath: "users/u/items/123/masked.png"
        )
        // Sanity-check the fixture: thumbnailPath is always set, so the
        // assertion below verifies the helper picks masked over thumb,
        // not just "picked the only available path."
        #expect(item.thumbnailPath.isEmpty == false)
        #expect(item.maskedImagePath != nil)

        #expect(ItemCardView.displayPath(for: item) == item.maskedImagePath)
    }

    @Test func fallsBackToThumbnailPathWhenMaskedImagePathNil() {
        let item = TestFixtures.makeWardrobeItem(maskedImagePath: nil)
        #expect(item.maskedImagePath == nil)

        #expect(ItemCardView.displayPath(for: item) == item.thumbnailPath)
    }
}
