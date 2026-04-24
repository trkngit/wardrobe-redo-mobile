import Foundation
import OSLog

/// On-device read-through cache for Supabase-backed models.
///
/// Stored as a single JSON snapshot at `Library/Caches/wardrobe-cache.json`
/// so the OS can purge under disk pressure and we stay out of iCloud
/// backups. We intentionally do **not** use SwiftData here: its strict-
/// concurrency story under Swift 6 forces `@ModelActor` isolation and a
/// second mental model for data access, which is overkill for the four
/// flat buckets we need (items, outfits-by-date, slots-by-outfit,
/// profile). An `actor` with a Codable snapshot file is simpler,
/// auditable in a file diff, and just as offline-safe.
///
/// **Not** the source of truth — Supabase is. Callers should always try
/// the network first and fall back to the cache on failure. The cache
/// is written through on successful fetches so it stays warm for the
/// next offline launch. Writes (inserts/updates/deletes) invalidate
/// the affected user's items bucket and let the next fetch repopulate
/// it; we do **not** speculatively mutate cached collections on write,
/// because the server may apply triggers we haven't modelled (e.g.
/// `updated_at`, `formality_computed`).
///
/// TTL: each bucket records a `savedAt` timestamp. `maxAge` defaults to
/// 7 days; callers can opt into a shorter age via the fetch helpers.
/// Expired buckets are returned as `nil` so the call site sees "no
/// cache" and surfaces the underlying network error to the user.
actor LocalCache {
    /// Shared singleton. Injection-free so existing `@MainActor` repos
    /// can `await LocalCache.shared.cachedItems(...)` without DI churn.
    static let shared = LocalCache()

    private let log = Logger(subsystem: "com.wardroberedo", category: "LocalCache")

    /// Default TTL. Seven days matches Kingfisher's disk cache retention
    /// so a user who goes offline for a week sees the same ghost data
    /// across text and image layers.
    static let defaultMaxAge: TimeInterval = 7 * 24 * 60 * 60

    // MARK: - Snapshot shape

    /// Single on-disk envelope. All three buckets are optional so a
    /// partially-warm cache (e.g. items populated but no outfits fetched
    /// yet) still round-trips. `Sendable` is explicit because the
    /// static `.empty` is accessed from the actor's `init`.
    private struct Snapshot: Codable, Sendable {
        var itemsByUser: [String: Bucket<[WardrobeItem]>]
        var outfitsByUserDate: [String: Bucket<[Outfit]>]
        var slotsByOutfit: [String: Bucket<[OutfitSlot]>]

        static let empty = Snapshot(
            itemsByUser: [:],
            outfitsByUserDate: [:],
            slotsByOutfit: [:]
        )
    }

    /// A bucket pairs cached data with the wall-clock time it was
    /// written, so the reader can apply TTL.
    private struct Bucket<T: Codable & Sendable>: Codable, Sendable {
        let value: T
        let savedAt: Date
    }

    private var snapshot: Snapshot = .empty
    private var loaded = false

    // MARK: - File location

    /// URL of the snapshot file under `Library/Caches/`. Lazy and
    /// cached because `FileManager.url(for:in:appropriateFor:create:)`
    /// can throw on sandbox-weird environments (shouldn't happen on
    /// iOS but the API is marked throwing).
    private lazy var fileURL: URL? = {
        do {
            let caches = try FileManager.default.url(
                for: .cachesDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            return caches.appendingPathComponent("wardrobe-cache.json")
        } catch {
            log.error("Could not resolve caches dir: \(String(describing: error), privacy: .public)")
            return nil
        }
    }()

    // MARK: - Public API — reads

    /// Return cached items for a user, honoring TTL. `nil` means
    /// "no usable cache" — caller should surface the network error.
    func cachedItems(userId: UUID, maxAge: TimeInterval = LocalCache.defaultMaxAge) -> [WardrobeItem]? {
        loadIfNeeded()
        guard let bucket = snapshot.itemsByUser[userId.uuidString] else { return nil }
        guard isFresh(bucket.savedAt, maxAge: maxAge) else { return nil }
        return bucket.value
    }

    /// Return cached outfits for a user+date, honoring TTL.
    func cachedOutfits(
        userId: UUID,
        date: String,
        maxAge: TimeInterval = LocalCache.defaultMaxAge
    ) -> [Outfit]? {
        loadIfNeeded()
        let key = Self.outfitKey(userId: userId, date: date)
        guard let bucket = snapshot.outfitsByUserDate[key] else { return nil }
        guard isFresh(bucket.savedAt, maxAge: maxAge) else { return nil }
        return bucket.value
    }

    /// Return cached slots grouped by outfit ID, honoring TTL.
    /// Missing outfits in the input set simply aren't in the output.
    func cachedSlots(
        outfitIds: [UUID],
        maxAge: TimeInterval = LocalCache.defaultMaxAge
    ) -> [UUID: [OutfitSlot]]? {
        loadIfNeeded()
        guard !outfitIds.isEmpty else { return [:] }
        var result: [UUID: [OutfitSlot]] = [:]
        var missing = 0
        for id in outfitIds {
            if let bucket = snapshot.slotsByOutfit[id.uuidString],
               isFresh(bucket.savedAt, maxAge: maxAge) {
                result[id] = bucket.value
            } else {
                missing += 1
            }
        }
        // If more than half are missing we treat the cache as cold and
        // force the caller onto the network path. Otherwise a partial
        // hit may silently mislead the UI into rendering a half-filled
        // outfit carousel.
        if missing > outfitIds.count / 2 { return nil }
        return result
    }

    // MARK: - Public API — writes

    func storeItems(_ items: [WardrobeItem], userId: UUID) {
        loadIfNeeded()
        snapshot.itemsByUser[userId.uuidString] = Bucket(value: items, savedAt: Date())
        persist()
    }

    func storeOutfits(_ outfits: [Outfit], userId: UUID, date: String) {
        loadIfNeeded()
        let key = Self.outfitKey(userId: userId, date: date)
        snapshot.outfitsByUserDate[key] = Bucket(value: outfits, savedAt: Date())
        persist()
    }

    func storeSlots(_ slotsByOutfit: [UUID: [OutfitSlot]]) {
        loadIfNeeded()
        let now = Date()
        for (outfitId, slots) in slotsByOutfit {
            snapshot.slotsByOutfit[outfitId.uuidString] = Bucket(value: slots, savedAt: now)
        }
        persist()
    }

    // MARK: - Public API — invalidation

    /// Wipe cached items for a user. Call after insert/update/delete so
    /// the next read re-fetches fresh data. Outfits are left alone —
    /// they go stale on their own TTL.
    func invalidateItems(userId: UUID) {
        loadIfNeeded()
        snapshot.itemsByUser.removeValue(forKey: userId.uuidString)
        persist()
    }

    /// Wipe cached outfits for a user+date. Call after saveOutfit so
    /// the next daily-view read pulls fresh rows.
    func invalidateOutfits(userId: UUID, date: String) {
        loadIfNeeded()
        let key = Self.outfitKey(userId: userId, date: date)
        snapshot.outfitsByUserDate.removeValue(forKey: key)
        persist()
    }

    /// Wipe everything — used on sign-out so the next user doesn't see
    /// the previous user's wardrobe. RLS already prevents server-side
    /// leakage; this handles the local UX symmetry.
    func clear() {
        snapshot = .empty
        persist()
    }

    // MARK: - Private

    private func isFresh(_ savedAt: Date, maxAge: TimeInterval) -> Bool {
        Date().timeIntervalSince(savedAt) < maxAge
    }

    private static func outfitKey(userId: UUID, date: String) -> String {
        "\(userId.uuidString)|\(date)"
    }

    /// Decode snapshot from disk on first access. Missing file = empty
    /// snapshot. Corrupt file = empty snapshot + log (so a bad migration
    /// doesn't brick the app; the next successful fetch rebuilds it).
    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let url = fileURL, FileManager.default.fileExists(atPath: url.path) else {
            return
        }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            snapshot = try decoder.decode(Snapshot.self, from: data)
        } catch {
            log.error("Cache decode failed; starting empty: \(String(describing: error), privacy: .public)")
            snapshot = .empty
        }
    }

    private func persist() {
        guard let url = fileURL else { return }
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(snapshot)
            try data.write(to: url, options: .atomic)
        } catch {
            // Non-fatal: next write retries. We log rather than throw
            // so a full-disk event doesn't crash every cache-touching
            // repo call.
            log.error("Cache persist failed: \(String(describing: error), privacy: .public)")
        }
    }
}
