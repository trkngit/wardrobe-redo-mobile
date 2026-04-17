import Foundation
import Supabase
// See UserRepository.swift for the rationale — `@preconcurrency` keeps
// this file building on Xcode 16's Swift 6 toolchain without waiting for
// PostgREST to complete its Sendable audit.
@preconcurrency import PostgREST

@MainActor
final class WardrobeRepository: WardrobeRepositoryProtocol {
    private let supabase = SupabaseManager.shared.client

    func fetchItems(userId: UUID, category: ClothingCategory? = nil) async throws -> [WardrobeItem] {
        var query = supabase
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

    func fetchItems(ids: [UUID]) async throws -> [WardrobeItem] {
        guard !ids.isEmpty else { return [] }
        return try await supabase
            .from("wardrobe_items")
            .select()
            .in("id", values: ids)
            .execute()
            .value
    }

    func fetchItem(id: UUID) async throws -> WardrobeItem {
        try await supabase
            .from("wardrobe_items")
            .select()
            .eq("id", value: id)
            .single()
            .execute()
            .value
    }

    func insertItem(_ item: NewWardrobeItem) async throws -> WardrobeItem {
        try await supabase
            .from("wardrobe_items")
            .insert(item)
            .select()
            .single()
            .execute()
            .value
    }

    func updateItem(id: UUID, updates: WardrobeItemUpdate) async throws -> WardrobeItem {
        try await supabase
            .from("wardrobe_items")
            .update(updates)
            .eq("id", value: id)
            .select()
            .single()
            .execute()
            .value
    }

    func archiveItem(id: UUID) async throws {
        try await supabase
            .from("wardrobe_items")
            .update(["is_archived": true])
            .eq("id", value: id)
            .execute()
    }

    func deleteItem(id: UUID) async throws {
        try await supabase
            .from("wardrobe_items")
            .delete()
            .eq("id", value: id)
            .execute()
    }

    func itemCount(userId: UUID) async throws -> Int {
        let items: [WardrobeItem] = try await supabase
            .from("wardrobe_items")
            .select()
            .eq("user_id", value: userId)
            .eq("is_archived", value: false)
            .execute()
            .value
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
    let category: String
    let subcategory: String
    let dominantColors: [ColorProfile]
    let texture: String?
    let fitAttribute: String?
    let seasons: [String]
    let occasions: [String]

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case imagePath = "image_path"
        case thumbnailPath = "thumbnail_path"
        case maskedImagePath = "masked_image_path"
        case extractionConfidence = "extraction_confidence"
        case category, subcategory
        case dominantColors = "dominant_colors"
        case texture
        case fitAttribute = "fit_attribute"
        case seasons, occasions
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
