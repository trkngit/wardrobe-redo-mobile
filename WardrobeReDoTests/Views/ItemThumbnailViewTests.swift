import Foundation
import Testing
@testable import WardrobeReDo

/// `ItemThumbnailView.displayPath(for:)` is the unified resolver every
/// new surface should use to choose between the per-item cutout and
/// the framed source-photo thumbnail. The contract is the same as
/// `ItemCardView.displayPath(for:)` (which has its own `Suite`); these
/// tests pin the contract under the new name so a future refactor that
/// moves the canonical resolver onto `ItemThumbnailView` doesn't
/// silently change the resolution rule.
@MainActor
@Suite("ItemThumbnailView.displayPath")
struct ItemThumbnailViewDisplayPathTests {

    @Test func maskedImagePathPreferredWhenPresent() {
        let item = TestFixtures.makeWardrobeItem(
            maskedImagePath: "users/u/items/123/masked.png"
        )
        #expect(ItemThumbnailView.displayPath(for: item) == "users/u/items/123/masked.png")
    }

    @Test func fallsBackToThumbnailPathWhenMaskedImagePathNil() {
        let item = TestFixtures.makeWardrobeItem(maskedImagePath: nil)
        #expect(ItemThumbnailView.displayPath(for: item) == item.thumbnailPath)
    }

    /// The two resolvers — `ItemCardView.displayPath` and
    /// `ItemThumbnailView.displayPath` — must agree on every input.
    /// PR #27 will migrate the four call sites onto `ItemThumbnailView`;
    /// any divergence here would mean the migration silently changes
    /// which path is rendered.
    @Test func itemCardAndThumbnailResolversAgree() {
        let withMasked = TestFixtures.makeWardrobeItem(
            maskedImagePath: "users/u/items/abc/masked.png"
        )
        #expect(
            ItemCardView.displayPath(for: withMasked)
                == ItemThumbnailView.displayPath(for: withMasked)
        )

        let withoutMasked = TestFixtures.makeWardrobeItem(maskedImagePath: nil)
        #expect(
            ItemCardView.displayPath(for: withoutMasked)
                == ItemThumbnailView.displayPath(for: withoutMasked)
        )
    }
}
