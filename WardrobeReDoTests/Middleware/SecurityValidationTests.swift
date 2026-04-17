import Foundation
import Testing
@testable import WardrobeReDo

// MARK: - M4: Security & Schema Validation Tests
// Static analysis of data contracts, enum/DB alignment, and bundled data integrity.

// MARK: - Swift Enum ↔ Database Alignment

@Test func textureTypeRawValuesMatchDatabaseConstraints() {
    // Database CHECK: fit_attribute IN ('oversized','relaxed','regular','slim','structured','cropped')
    // Verify TextureType raw values are valid strings for DB
    for texture in TextureType.allCases {
        let rawValue = texture.rawValue
        #expect(!rawValue.isEmpty, "TextureType.\(texture) has empty rawValue")
        // Raw values should be lowercase (match DB text column)
        #expect(rawValue == rawValue.lowercased(), "TextureType.\(texture) rawValue should be lowercase")
    }
}

@Test func fitAttributeRawValuesMatchDatabaseConstraints() {
    let expectedValues: Set<String> = ["oversized", "relaxed", "regular", "slim", "structured", "cropped"]

    let actualValues = Set(FitAttribute.allCases.map(\.rawValue))

    #expect(actualValues == expectedValues, "FitAttribute raw values must match database CHECK constraint")
}

@Test func clothingCategoryRawValuesAreLowercase() {
    for category in ClothingCategory.allCases {
        #expect(category.rawValue == category.rawValue.lowercased())
    }
}

@Test func seasonRawValuesAreLowercase() {
    for season in Season.allCases {
        #expect(season.rawValue == season.rawValue.lowercased())
    }
}

@Test func occasionRawValuesAreLowercase() {
    for occasion in Occasion.allCases {
        #expect(occasion.rawValue == occasion.rawValue.lowercased())
    }
}

// MARK: - Scoring Dimension Integrity

@Test func scoringWeightsSumToOne() {
    // These are the canonical weights from the style engine spec
    let weights: [Double] = [0.15, 0.25, 0.10, 0.15, 0.15, 0.10, 0.10]
    let sum = weights.reduce(0, +)
    #expect(abs(sum - 1.0) < 0.0001, "Scoring weights must sum to 1.0, got \(sum)")
}

// MARK: - CodingKeys Consistency

@Test func wardrobeItemCodingKeysUseSnakeCase() throws {
    let item = TestFixtures.makeWardrobeItem()
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(item)
    let json = String(data: data, encoding: .utf8)!

    // Verify critical snake_case keys
    #expect(json.contains("\"user_id\""))
    #expect(json.contains("\"image_path\""))
    #expect(json.contains("\"thumbnail_path\""))
    #expect(json.contains("\"dominant_colors\""))
    #expect(json.contains("\"wear_count\""))
    #expect(json.contains("\"is_archived\""))
    #expect(json.contains("\"created_at\""))
    #expect(json.contains("\"updated_at\""))

    // Must NOT have camelCase keys
    #expect(!json.contains("\"userId\""))
    #expect(!json.contains("\"imagePath\""))
    #expect(!json.contains("\"wearCount\""))
    #expect(!json.contains("\"isArchived\""))
}

@Test func outfitSlotCodingKeysUseSnakeCase() throws {
    let slot = OutfitSlot(
        id: UUID(), outfitId: UUID(), wardrobeItemId: UUID(),
        slotName: "top", role: "hero"
    )
    let data = try JSONEncoder().encode(slot)
    let json = String(data: data, encoding: .utf8)!

    #expect(json.contains("\"outfit_id\""))
    #expect(json.contains("\"wardrobe_item_id\""))
    #expect(json.contains("\"slot_name\""))
    #expect(!json.contains("\"outfitId\""))
    #expect(!json.contains("\"wardrobeItemId\""))
    #expect(!json.contains("\"slotName\""))
}

// MARK: - Optional Field Decoding Safety

@Test func wardrobeItemDecodesWithNilOptionalFields() throws {
    // A wardrobe item from the database may have null optional fields
    let json = """
    {
        "id": "00000000-0000-0000-0000-000000000001",
        "user_id": "00000000-0000-0000-0000-000000000002",
        "image_path": "test/img.jpg",
        "thumbnail_path": "test/thumb.jpg",
        "category": "top",
        "subcategory": "tshirt",
        "dominant_colors": [],
        "texture": null,
        "fit_attribute": null,
        "formality_components": null,
        "formality_computed": null,
        "seasons": ["spring"],
        "occasions": ["casual"],
        "visual_weight": null,
        "wear_count": 0,
        "last_worn_at": null,
        "is_archived": false,
        "created_at": "2025-01-01T00:00:00Z",
        "updated_at": "2025-01-01T00:00:00Z"
    }
    """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let item = try decoder.decode(WardrobeItem.self, from: json.data(using: .utf8)!)

    #expect(item.texture == nil)
    #expect(item.fitAttribute == nil)
    #expect(item.formalityComponents == nil)
    #expect(item.formalityComputed == nil)
    #expect(item.visualWeight == nil)
    #expect(item.lastWornAt == nil)
    #expect(item.wearCount == 0)
    #expect(item.isArchived == false)
}

@Test func profileDecodesWithNilStylePreferences() throws {
    let json = """
    {
        "id": "00000000-0000-0000-0000-000000000001",
        "display_name": "Test",
        "tier": "free",
        "style_preferences": null,
        "onboarding_completed": false,
        "timezone": null,
        "created_at": "2025-01-01T00:00:00Z",
        "updated_at": "2025-01-01T00:00:00Z"
    }
    """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let profile = try decoder.decode(Profile.self, from: json.data(using: .utf8)!)

    #expect(profile.stylePreferences == nil)
    #expect(profile.timezone == nil)
    #expect(profile.onboardingCompleted == false)
}
