import Foundation
import Testing
@testable import WardrobeReDo

/// Tests for `WardrobeGridView`'s thumbnail-URL cache eviction. The view
/// holds two `@State` dictionaries — `thumbnailURLs` keyed by item id and
/// `sourcePhotoURLs` keyed by source-photo path. Without eviction, signed
/// URLs for items the user just deleted (or for source photos that no
/// longer exist after a re-upload) linger for the lifetime of the view —
/// and once the URL's TTL expires (Supabase signed URLs default to 3600s),
/// the cache silently 404s.
///
/// The fix is to drop entries whose key isn't in the live items list at
/// the start of every `loadThumbnails` pass. The pruning logic was
/// extracted into pure static helpers (`pruneItemCache` and
/// `pruneSourcePathCache`) so it can be exercised here without spinning
/// up SwiftUI `@State` or a real view body.
@MainActor
@Suite("WardrobeGridView cache eviction")
struct WardrobeGridViewCacheTests {

    // MARK: - pruneItemCache

    @Test func pruneItemCacheKeepsEntriesForLiveItems() {
        let item = TestFixtures.makeWardrobeItem()
        let url = URL(string: "https://example.com/sig/\(item.id).jpg")!
        let cache: [UUID: URL] = [item.id: url]

        let pruned = WardrobeGridView.pruneItemCache(cache, against: [item])

        #expect(pruned.count == 1)
        #expect(pruned[item.id] == url)
    }

    @Test func pruneItemCacheDropsEntriesForDeletedItems() {
        let kept = TestFixtures.makeWardrobeItem()
        let deletedId = UUID()
        let cache: [UUID: URL] = [
            kept.id: URL(string: "https://example.com/sig/kept.jpg")!,
            deletedId: URL(string: "https://example.com/sig/deleted.jpg")!,
        ]

        // After a delete, `viewModel.items` no longer includes the deleted
        // row. The cache should shed the dead entry.
        let pruned = WardrobeGridView.pruneItemCache(cache, against: [kept])

        #expect(pruned.count == 1)
        #expect(pruned[kept.id] != nil)
        #expect(pruned[deletedId] == nil)
    }

    @Test func pruneItemCacheEmptyItemsClearsEverything() {
        let cache: [UUID: URL] = [
            UUID(): URL(string: "https://example.com/sig/a.jpg")!,
            UUID(): URL(string: "https://example.com/sig/b.jpg")!,
        ]
        let pruned = WardrobeGridView.pruneItemCache(cache, against: [])
        #expect(pruned.isEmpty)
    }

    // MARK: - pruneSourcePathCache

    @Test func pruneSourcePathCacheKeepsReferencedPaths() {
        let path = "users/u/source/cap-1/original.jpg"
        let item = TestFixtures.makeWardrobeItem(sourcePhotoPath: path)
        let cache: [String: URL] = [
            path: URL(string: "https://example.com/sig/cap-1.jpg")!,
        ]

        let pruned = WardrobeGridView.pruneSourcePathCache(cache, against: [item])

        #expect(pruned.count == 1)
        #expect(pruned[path] != nil)
    }

    @Test func pruneSourcePathCacheDropsOrphanedPaths() {
        let livePath = "users/u/source/cap-1/original.jpg"
        let orphanedPath = "users/u/source/cap-2/original.jpg"
        let item = TestFixtures.makeWardrobeItem(sourcePhotoPath: livePath)
        let cache: [String: URL] = [
            livePath: URL(string: "https://example.com/sig/live.jpg")!,
            orphanedPath: URL(string: "https://example.com/sig/orphan.jpg")!,
        ]

        let pruned = WardrobeGridView.pruneSourcePathCache(cache, against: [item])

        #expect(pruned.count == 1)
        #expect(pruned[livePath] != nil)
        #expect(pruned[orphanedPath] == nil)
    }

    @Test func pruneSourcePathCacheItemsWithoutSourcePathDoNotKeepEntries() {
        // Legacy items pre-migration 00008 have `sourcePhotoPath == nil`.
        // The cache is keyed by path — items with no path can't keep any
        // entry alive, so anything in the cache when none of the live
        // items reference a path should be dropped.
        let legacyItem = TestFixtures.makeWardrobeItem(sourcePhotoPath: nil)
        let stalePath = "users/u/source/cap-1/original.jpg"
        let cache: [String: URL] = [
            stalePath: URL(string: "https://example.com/sig/stale.jpg")!,
        ]

        let pruned = WardrobeGridView.pruneSourcePathCache(
            cache,
            against: [legacyItem]
        )

        #expect(pruned.isEmpty)
    }
}
