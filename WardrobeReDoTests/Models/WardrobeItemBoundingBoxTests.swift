import Foundation
import Testing
@testable import WardrobeReDo

// MARK: - BoundingBoxCodable JSON / CGRect Round-Trips

@Test func boundingBoxCodableRoundTripsThroughJSON() throws {
    let original = BoundingBoxCodable(x: 0.1, y: 0.4, width: 0.3, height: 0.5)
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(BoundingBoxCodable.self, from: data)

    #expect(decoded == original)
    #expect(decoded.x == 0.1)
    #expect(decoded.y == 0.4)
    #expect(decoded.width == 0.3)
    #expect(decoded.height == 0.5)
}

@Test func boundingBoxCodableConvertsToCGRect() {
    let bbox = BoundingBoxCodable(x: 0.1, y: 0.4, width: 0.3, height: 0.5)
    let rect = bbox.cgRect

    #expect(rect.minX == 0.1)
    #expect(rect.minY == 0.4)
    #expect(rect.width == 0.3)
    #expect(rect.height == 0.5)
}

@Test func boundingBoxCodableInitFromCGRect() {
    let rect = CGRect(x: 0.2, y: 0.3, width: 0.4, height: 0.5)
    let bbox = BoundingBoxCodable(rect)

    #expect(bbox.x == 0.2)
    #expect(bbox.y == 0.3)
    #expect(bbox.width == 0.4)
    #expect(bbox.height == 0.5)
    // The cgRect projection should round-trip back to the source rect.
    #expect(bbox.cgRect == rect)
}

// MARK: - WardrobeItem Codable Integration

/// Minimum valid `wardrobe_items` JSON without a bounding box. Each
/// test layers its own `bounding_box` value on top so the rest of the
/// payload stays in one place.
private let minimalWardrobeItemJSONWithoutBoundingBox = """
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

@Test func wardrobeItemDecodesWithBoundingBoxField() throws {
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
        "bounding_box": {"x": 0.1, "y": 0.4, "width": 0.3, "height": 0.5},
        "created_at": "2025-01-01T00:00:00Z",
        "updated_at": "2025-01-01T00:00:00Z"
    }
    """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let item = try decoder.decode(WardrobeItem.self, from: json.data(using: .utf8)!)

    #expect(item.boundingBox != nil)
    #expect(item.boundingBox?.x == 0.1)
    #expect(item.boundingBox?.y == 0.4)
    #expect(item.boundingBox?.width == 0.3)
    #expect(item.boundingBox?.height == 0.5)
}

@Test func wardrobeItemDecodesWithMissingBoundingBoxField() throws {
    // Legacy rows predating migration 00013 omit the column entirely.
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let item = try decoder.decode(
        WardrobeItem.self,
        from: minimalWardrobeItemJSONWithoutBoundingBox.data(using: .utf8)!
    )

    #expect(item.boundingBox == nil)
}

@Test func wardrobeItemDecodesWithNullBoundingBoxField() throws {
    // Post-migration rows where the bbox simply wasn't recorded come
    // back from PostgREST as an explicit null on the column.
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
        "bounding_box": null,
        "created_at": "2025-01-01T00:00:00Z",
        "updated_at": "2025-01-01T00:00:00Z"
    }
    """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let item = try decoder.decode(WardrobeItem.self, from: json.data(using: .utf8)!)

    #expect(item.boundingBox == nil)
}

@Test func wardrobeItemEncodesBoundingBoxField() throws {
    let bbox = BoundingBoxCodable(x: 0.2, y: 0.3, width: 0.4, height: 0.5)
    let original = TestFixtures.makeWardrobeItem(boundingBox: bbox)

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(original)

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(WardrobeItem.self, from: data)

    // The roundtrip is the contract; the exact JSON shape is an
    // implementation detail of the synthesized encoder.
    #expect(decoded.boundingBox == bbox)
}
