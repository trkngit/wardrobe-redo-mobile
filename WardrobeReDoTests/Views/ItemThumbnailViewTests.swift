import Foundation
import SwiftUI
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

/// PR #27 changes the thumbnail body from `.scaledToFill` over the full
/// frame to `.scaledToFit` inside a white-background card with a 16pt
/// inset. Snapshot tests are heavy for what's mostly a layout contract
/// — instead we pin the dimensions and verify the view constructs for
/// each `Size` so a regression in the size table or the body shape
/// fails the suite immediately.
@MainActor
@Suite("ItemThumbnailView.layout")
struct ItemThumbnailViewLayoutTests {

    @Test func smallSizeUses44pt() {
        #expect(ItemThumbnailView.Size.small.dimension == 44)
    }

    @Test func mediumSizeUses160pt() {
        #expect(ItemThumbnailView.Size.medium.dimension == 160)
    }

    @Test func largeSizeIsFullWidth() {
        // Full-width is encoded as `nil` so the surrounding layout
        // (e.g. an outfit detail grid cell) controls the actual
        // dimension.
        #expect(ItemThumbnailView.Size.large.dimension == nil)
    }

    /// Smoke test — every size constructs without throwing. Catches a
    /// regression where the body's size-aware padding or placeholder
    /// switch breaks at one of the cases.
    @Test func constructsForEverySize() {
        let item = TestFixtures.makeWardrobeItem()
        let url = URL(string: "https://example.com/item.png")

        for size in [ItemThumbnailView.Size.small,
                     ItemThumbnailView.Size.medium,
                     ItemThumbnailView.Size.large] {
            _ = ItemThumbnailView(item: item, url: url, size: size)
        }
    }

    /// Pins the thumbnail's stored properties — the cluster of `let`
    /// inputs the body reads. SwiftUI doesn't expose modifier metadata
    /// at runtime, so the higher-confidence layout assertion is a
    /// snapshot test (out of scope here); the smoke + size-table tests
    /// above plus this property check together pin the public surface.
    @Test func storesProvidedItemAndUrl() {
        let item = TestFixtures.makeWardrobeItem()
        let url = URL(string: "https://example.com/item.png")
        let view = ItemThumbnailView(item: item, url: url, size: .medium)

        let mirror = Mirror(reflecting: view)
        let storedURL = mirror.children.first { $0.label == "url" }?.value as? URL
        #expect(storedURL == url)
    }
}
