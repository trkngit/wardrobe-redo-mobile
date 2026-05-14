import Foundation
import Supabase
// See UserRepository.swift for the rationale — `@preconcurrency` keeps
// this file building on Xcode 16's Swift 6 toolchain without waiting for
// PostgREST to complete its Sendable audit.
@preconcurrency import PostgREST

@MainActor
final class WardrobeRepository: WardrobeRepositoryProtocol {
    private let supabase = SupabaseManager.shared.client
    private let cache: LocalCache

    /// `nonisolated` so non-MainActor callers (e.g. `OutfitGenerationService`
    /// in its persistence bridge) can instantiate the repo without a
    /// `await MainActor.run`. The init only writes the `cache` property,
    /// which is Sendable — the class body's MainActor isolation still
    /// applies to every method call.
    nonisolated init(cache: LocalCache = .shared) {
        self.cache = cache
    }

    /// Fetch items with cache-aware fallback:
    /// 1. Hit Supabase (wrapped in retry for transient failures).
    /// 2. On success → write through to local cache for offline reuse.
    /// 3. On error → if cache has a fresh bucket for this user, return
    ///    it as a last-resort; otherwise re-throw the original error.
    ///
    /// Category filters bypass the cache: the cache stores the user's
    /// full unfiltered list and letting the call site filter in-memory
    /// would leak implementation detail here.
    func fetchItems(userId: UUID, category: ClothingCategory? = nil) async throws -> [WardrobeItem] {
        do {
            let items: [WardrobeItem] = try await withRetry {
                var query = self.supabase
                    .from("wardrobe_items")
                    .select()
                    .eq("user_id", value: userId)
                    .eq("is_archived", value: false)

                if let category {
                    query = query.eq("category", value: category.rawValue)
                }

                return try await query
                    .order("created_at", ascending: false)
                    .execute()
                    .value
            }
            // Only write through when unfiltered — filtered lists would
            // overwrite the authoritative full-wardrobe bucket.
            if category == nil {
                await cache.storeItems(items, userId: userId)
            }
            return items
        } catch {
            if category == nil, let cached = await cache.cachedItems(userId: userId) {
                return cached
            }
            throw error
        }
    }

    func fetchItems(ids: [UUID]) async throws -> [WardrobeItem] {
        guard !ids.isEmpty else { return [] }
        return try await withRetry {
            try await self.supabase
                .from("wardrobe_items")
                .select()
                .in("id", values: ids)
                .execute()
                .value
        }
    }

    func fetchItem(id: UUID) async throws -> WardrobeItem {
        try await withRetry {
            try await self.supabase
                .from("wardrobe_items")
                .select()
                .eq("id", value: id)
                .single()
                .execute()
                .value
        }
    }

    /// Insert with idempotency-aware retry.
    ///
    /// Flow on a network partition:
    ///   1. First POST succeeds server-side but the response is lost.
    ///   2. `withRetry` classifies the timeout as retryable and re-sends.
    ///   3. Server hits the partial unique index on
    ///      `(user_id, idempotency_key)` and returns Postgres 23505.
    ///   4. We catch the duplicate-key error, re-fetch the already-
    ///      inserted row by `(user_id, idempotency_key)`, and return it.
    ///
    /// Legacy call sites that pass `idempotencyKey == nil` keep the
    /// old behavior: retries on duplicate would re-insert. That's a
    /// non-regression against pre-migration-00010 code.
    func insertItem(_ item: NewWardrobeItem) async throws -> WardrobeItem {
        let inserted: WardrobeItem
        do {
            inserted = try await withRetry {
                try await self.supabase
                    .from("wardrobe_items")
                    .insert(item)
                    .select()
                    .single()
                    .execute()
                    .value
            }
        } catch {
            if let key = item.idempotencyKey, isDuplicateKeyError(error) {
                // First attempt actually succeeded — fetch the row.
                let existing: WardrobeItem = try await withRetry {
                    try await self.supabase
                        .from("wardrobe_items")
                        .select()
                        .eq("user_id", value: item.userId)
                        .eq("idempotency_key", value: key)
                        .single()
                        .execute()
                        .value
                }
                await cache.invalidateItems(userId: existing.userId)
                return existing
            }
            throw error
        }
        // Insert may add a row not present in the cached bucket; cheapest
        // correct move is to drop the bucket and let the next fetch
        // repopulate. (Optimistically appending would miss server-side
        // derived fields like formality_computed.)
        await cache.invalidateItems(userId: inserted.userId)
        return inserted
    }

    func updateItem(id: UUID, updates: WardrobeItemUpdate) async throws -> WardrobeItem {
        let updated: WardrobeItem = try await withRetry {
            try await self.supabase
                .from("wardrobe_items")
                .update(updates)
                .eq("id", value: id)
                .select()
                .single()
                .execute()
                .value
        }
        await cache.invalidateItems(userId: updated.userId)
        return updated
    }

    func archiveItem(id: UUID) async throws {
        // Archive doesn't return the row; we look it up first to know
        // which user's cache to invalidate. Failing that lookup is not
        // worth a second retry loop — we archive anyway and only skip
        // the targeted invalidation.
        let userId = try? await fetchItem(id: id).userId
        try await withRetry {
            try await self.supabase
                .from("wardrobe_items")
                .update(["is_archived": true])
                .eq("id", value: id)
                .execute()
        }
        if let userId {
            await cache.invalidateItems(userId: userId)
        }
    }

    func deleteItem(id: UUID) async throws {
        let userId = try? await fetchItem(id: id).userId
        try await withRetry {
            try await self.supabase
                .from("wardrobe_items")
                .delete()
                .eq("id", value: id)
                .execute()
        }
        if let userId {
            await cache.invalidateItems(userId: userId)
        }
    }

    func itemCount(userId: UUID) async throws -> Int {
        let items: [WardrobeItem] = try await withRetry {
            try await self.supabase
                .from("wardrobe_items")
                .select()
                .eq("user_id", value: userId)
                .eq("is_archived", value: false)
                .execute()
                .value
        }
        return items.count
    }
}

// MARK: - Insert/Update DTOs

struct NewWardrobeItem: Codable, Sendable {
    let userId: UUID
    let imagePath: String
    let thumbnailPath: String
    /// Storage path to the background-masked JPEG. Nil when extraction
    /// failed (e.g. on simulator builds that can't run Vision) — the
    /// insert still succeeds and the row renders from `imagePath`.
    let maskedImagePath: String?
    /// One of ExtractionConfidence.rawValue, or nil when extraction
    /// was skipped entirely (simulator, iOS < 17).
    let extractionConfidence: String?
    /// Shared across every row cut out of the same source capture.
    /// Populated by `AddItemViewModel` on the *first* save of a
    /// multi-garment loop and reused by garments 2..N. Nil for
    /// single-item captures. See migration 00008.
    let sourcePhotoId: UUID?
    /// Storage path to the unmasked source JPEG. Uploaded lazily on
    /// the *second* save of a capture (when we know the user is
    /// actually building a group) and passed to every subsequent row
    /// so storage usage stays proportional to *captures*, not
    /// garments. Nil iff `sourcePhotoId` is nil.
    let sourcePhotoPath: String?
    let category: String
    let subcategory: String
    let dominantColors: [ColorProfile]
    let texture: String?
    let fitAttribute: String?
    let seasons: [String]
    let occasions: [String]
    /// Per-field provenance map produced by the pre-fill diff in
    /// `AddItemViewModel.save(userId:)`. Keys match the field names
    /// snapshot by `applyPrefill` ("category", "subcategory", "texture",
    /// "fit", "seasons", "occasions"). Values are one of "ai",
    /// "user", or "user_changed_from_ai". Omitted from the encoded
    /// payload when nil so pre-migration-00009 databases aren't told
    /// about a column they don't yet have — Postgres' `DEFAULT '{}'`
    /// still fills the cell on insert.
    let detectedAttributes: [String: String]?
    /// Client-generated UUID that dedupes retried inserts. Stored in
    /// the `idempotency_key` column (see migration 00010). Pre-00010
    /// databases simply receive it as an unrecognized column; PostgREST
    /// returns a 400 that the client treats as a soft error (the item
    /// is saved next run once the migration lands). Set nil on this
    /// struct to opt-out (e.g. legacy tests that never retry).
    let idempotencyKey: UUID?
    /// Normalized [0, 1] bounding box of the detected garment within
    /// `sourcePhotoPath`. Stored in the `bounding_box` JSONB column
    /// (see migration 00013). Nil for single-item captures where no
    /// bbox was recorded — matches the shape of legacy rows.
    let boundingBox: BoundingBoxCodable?
    /// Build 6 Phase 8B — fraction of the source frame the
    /// extracted mask covered, in [0, 1]. Sourced from
    /// `ProcessedImage.silhouetteArea`. Nil when extraction was
    /// skipped or failed; the row hydrates with the column null
    /// and `ColorHarmonyScorer` falls back to the category default
    /// alone (Phase 8A behaviour).
    let silhouetteArea: Double?

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case imagePath = "image_path"
        case thumbnailPath = "thumbnail_path"
        case maskedImagePath = "masked_image_path"
        case extractionConfidence = "extraction_confidence"
        case sourcePhotoId = "source_photo_id"
        case sourcePhotoPath = "source_photo_path"
        case category, subcategory
        case dominantColors = "dominant_colors"
        case texture
        case fitAttribute = "fit_attribute"
        case seasons, occasions
        case detectedAttributes = "detected_attributes"
        case idempotencyKey = "idempotency_key"
        case boundingBox = "bounding_box"
        case silhouetteArea = "silhouette_area"
    }

    init(
        userId: UUID,
        imagePath: String,
        thumbnailPath: String,
        maskedImagePath: String?,
        extractionConfidence: String?,
        sourcePhotoId: UUID?,
        sourcePhotoPath: String?,
        category: String,
        subcategory: String,
        dominantColors: [ColorProfile],
        texture: String?,
        fitAttribute: String?,
        seasons: [String],
        occasions: [String],
        detectedAttributes: [String: String]?,
        idempotencyKey: UUID?,
        boundingBox: BoundingBoxCodable? = nil,
        silhouetteArea: Double? = nil
    ) {
        self.userId = userId
        self.imagePath = imagePath
        self.thumbnailPath = thumbnailPath
        self.maskedImagePath = maskedImagePath
        self.extractionConfidence = extractionConfidence
        self.sourcePhotoId = sourcePhotoId
        self.sourcePhotoPath = sourcePhotoPath
        self.category = category
        self.subcategory = subcategory
        self.dominantColors = dominantColors
        self.texture = texture
        self.fitAttribute = fitAttribute
        self.seasons = seasons
        self.occasions = occasions
        self.detectedAttributes = detectedAttributes
        self.idempotencyKey = idempotencyKey
        self.boundingBox = boundingBox
        self.silhouetteArea = silhouetteArea
    }
}

struct WardrobeItemUpdate: Codable, Sendable {
    var category: String?
    var subcategory: String?
    var texture: String?
    var fitAttribute: String?
    var seasons: [String]?
    var occasions: [String]?
    var isArchived: Bool?

    enum CodingKeys: String, CodingKey {
        case category, subcategory, texture
        case fitAttribute = "fit_attribute"
        case seasons, occasions
        case isArchived = "is_archived"
    }
}
