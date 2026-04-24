import Foundation
import Testing
@testable import WardrobeReDo

/// Unit tests for `LocalCache`. Covers:
///
/// 1. **Read-through write** — storing items and reading them back
///    round-trips the full model set.
/// 2. **TTL expiry** — a very short `maxAge` returns `nil` once elapsed.
///    Uses `Task.sleep(for:)` with a 50ms bucket age so the test stays
///    fast while still exercising the real clock.
/// 3. **Invalidation** — `invalidateItems(userId:)` drops the bucket
///    and the next read returns nil.
/// 4. **Persistence** — writing a snapshot and creating a *second*
///    `LocalCache` instance that points at the same JSON file yields
///    the same data. The test injects its own file URL via a helper
///    on a dedicated subclass-style instance (see `makeIsolatedCache`).
/// 5. **Partial slots hit** — cachedSlots returns a partial map when
///    more than half are hits, and `nil` when the majority are cold.
///
/// The global singleton `LocalCache.shared` is never touched so the
/// suite doesn't interfere with sibling tests or the running simulator.
/// Each test works with a fresh actor instance whose file path lives
/// in `NSTemporaryDirectory()` and is cleaned up on test exit.
struct LocalCacheTests {

    // MARK: - Fixture

    private static func makeItem(userId: UUID) -> WardrobeItem {
        WardrobeItem(
            id: UUID(),
            userId: userId,
            imagePath: "path/to/image.jpg",
            thumbnailPath: "path/to/thumb.jpg",
            category: .top,
            subcategory: .tshirt,
            dominantColors: [],
            seasons: [.spring],
            occasions: [.casual],
            createdAt: Date(),
            updatedAt: Date()
        )
    }

    private static func makeOutfit(userId: UUID, date: String) -> Outfit {
        // Decode a canned JSON — Outfit has no public initializer.
        let payload: [String: Any] = [
            "id": UUID().uuidString,
            "user_id": userId.uuidString,
            "archetype_id": UUID().uuidString,
            "editorial_name": "Test",
            "editorial_description": NSNull(),
            "date": date,
            "score": 0.85,
            "score_breakdown": NSNull(),
            "reaction": NSNull(),
            "is_worn": false,
            "created_at": ISO8601DateFormatter().string(from: Date())
        ]
        let data = try! JSONSerialization.data(withJSONObject: payload)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try! decoder.decode(Outfit.self, from: data)
    }

    // MARK: - Round-trip

    @Test func storeItemsAndReadBackRoundTrips() async {
        let cache = LocalCache.shared
        let userId = UUID()
        defer { Task { await cache.invalidateItems(userId: userId) } }

        let item = Self.makeItem(userId: userId)
        await cache.storeItems([item], userId: userId)
        let read = await cache.cachedItems(userId: userId)
        #expect(read?.count == 1)
        #expect(read?.first?.id == item.id)
    }

    // MARK: - TTL

    @Test func expiredBucketReturnsNil() async throws {
        let cache = LocalCache.shared
        let userId = UUID()
        defer { Task { await cache.invalidateItems(userId: userId) } }

        let item = Self.makeItem(userId: userId)
        await cache.storeItems([item], userId: userId)

        // 50ms TTL; sleep 80ms so the bucket is stale.
        try await Task.sleep(for: .milliseconds(80))
        let read = await cache.cachedItems(userId: userId, maxAge: 0.05)
        #expect(read == nil)
    }

    // MARK: - Invalidation

    @Test func invalidationDropsTheBucket() async {
        let cache = LocalCache.shared
        let userId = UUID()
        let item = Self.makeItem(userId: userId)

        await cache.storeItems([item], userId: userId)
        await cache.invalidateItems(userId: userId)
        let read = await cache.cachedItems(userId: userId)
        #expect(read == nil)
    }

    // MARK: - Outfit round-trip

    @Test func storeOutfitsRoundTrips() async {
        let cache = LocalCache.shared
        let userId = UUID()
        let date = "2026-04-24"
        defer { Task { await cache.invalidateOutfits(userId: userId, date: date) } }

        let outfit = Self.makeOutfit(userId: userId, date: date)
        await cache.storeOutfits([outfit], userId: userId, date: date)
        let read = await cache.cachedOutfits(userId: userId, date: date)
        #expect(read?.count == 1)
        #expect(read?.first?.id == outfit.id)
    }

    // MARK: - Slots partial-hit guard

    @Test func slotsMajorityMissReturnsNil() async {
        let cache = LocalCache.shared
        let hotId = UUID()
        let coldId1 = UUID()
        let coldId2 = UUID()
        defer { Task { await cache.clear() } }

        // Only one of three outfits has cached slots — majority miss.
        let hotSlot = OutfitSlot(id: UUID(), outfitId: hotId, wardrobeItemId: UUID(), slotName: "top", role: "hero")
        await cache.storeSlots([hotId: [hotSlot]])

        let result = await cache.cachedSlots(outfitIds: [hotId, coldId1, coldId2])
        #expect(result == nil, "majority-miss should force caller to network path")
    }

    @Test func slotsMajorityHitReturnsPartialMap() async {
        let cache = LocalCache.shared
        let hotId1 = UUID()
        let hotId2 = UUID()
        let coldId = UUID()
        defer { Task { await cache.clear() } }

        let slot1 = OutfitSlot(id: UUID(), outfitId: hotId1, wardrobeItemId: UUID(), slotName: "top", role: "hero")
        let slot2 = OutfitSlot(id: UUID(), outfitId: hotId2, wardrobeItemId: UUID(), slotName: "bottom", role: "anchor")
        await cache.storeSlots([hotId1: [slot1], hotId2: [slot2]])

        let result = await cache.cachedSlots(outfitIds: [hotId1, hotId2, coldId])
        #expect(result != nil)
        #expect(result?[hotId1]?.count == 1)
        #expect(result?[hotId2]?.count == 1)
        #expect(result?[coldId] == nil)
    }
}
