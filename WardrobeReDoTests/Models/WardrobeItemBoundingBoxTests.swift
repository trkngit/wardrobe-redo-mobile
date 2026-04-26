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

@Test func boundingBoxCodableInitNormalizesNegativeDimensions() {
    // The on-device extraction pipeline emits positive rects, but a
    // future caller passing a flipped rect would have written negative
    // widths/heights into the JSONB column and broken downstream
    // overlay math. CGRect's own `minX/minY/width/height` standardize
    // a flipped rect: the visual region (x ∈ [-0.2, 0.1], y ∈ [-0.1, 0.4])
    // is preserved, just re-anchored to the smaller corner with
    // positive dimensions. That's exactly what we want to persist.
    let rect = CGRect(x: 0.1, y: 0.4, width: -0.3, height: -0.5)
    let bbox = BoundingBoxCodable(rect)

    // Origin shifts to the standardized smaller corner. Use an epsilon
    // comparison because `0.1 + (-0.3)` evaluates to `-0.19999999...`
    // in IEEE 754 double (not exactly -0.2). The rect is the visual
    // region [(-0.2, -0.1), (0.1, 0.4)] regardless of FP precision.
    let eps = 1e-9
    #expect(abs(bbox.x - (-0.2)) < eps)
    #expect(abs(bbox.y - (-0.1)) < eps)
    // Dimensions land positive — `CGRect.width/height` always return
    // the absolute size, so no FP drift here.
    #expect(bbox.width == 0.3)
    #expect(bbox.height == 0.5)
    // The cgRect projection must round-trip to the standardized form
    // of the input — same visual region.
    #expect(bbox.cgRect == rect.standardized)
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

// MARK: - NewWardrobeItem Encoding (PostgREST Insert Payload)

/// Builds a `NewWardrobeItem` with all required fields filled in. The
/// bbox argument is the only one varying across tests; everything else
/// is throwaway placeholder data.
private func makeNewWardrobeItem(
    boundingBox: BoundingBoxCodable? = nil
) -> NewWardrobeItem {
    NewWardrobeItem(
        userId: UUID(),
        imagePath: "test/img.jpg",
        thumbnailPath: "test/thumb.jpg",
        maskedImagePath: nil,
        extractionConfidence: nil,
        sourcePhotoId: nil,
        sourcePhotoPath: nil,
        category: "top",
        subcategory: "tshirt",
        dominantColors: [],
        texture: nil,
        fitAttribute: nil,
        seasons: ["spring"],
        occasions: ["casual"],
        detectedAttributes: nil,
        idempotencyKey: nil,
        boundingBox: boundingBox
    )
}

@Test func newWardrobeItemEncodesBoundingBoxAsSnakeCaseJSON() throws {
    // PostgREST is case-sensitive on column names, so a CodingKeys
    // drift here would silently miss the column on insert. Pin the
    // wire shape: snake_case key, nested object with x/y/width/height
    // doubles.
    let item = makeNewWardrobeItem(
        boundingBox: BoundingBoxCodable(x: 0.1, y: 0.4, width: 0.3, height: 0.5)
    )

    let data = try JSONEncoder().encode(item)
    let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let bbox = try #require(json["bounding_box"] as? [String: Any])

    #expect(bbox["x"] as? Double == 0.1)
    #expect(bbox["y"] as? Double == 0.4)
    #expect(bbox["width"] as? Double == 0.3)
    #expect(bbox["height"] as? Double == 0.5)
}

@Test func newWardrobeItemEncodesNilBoundingBoxAsNullOrAbsent() throws {
    // Pin whichever shape the synthesized encoder picks. Either is
    // valid for PostgREST — absent fields and explicit nulls both
    // resolve to NULL on the column.
    let item = makeNewWardrobeItem(boundingBox: nil)

    let data = try JSONEncoder().encode(item)
    let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

    if let raw = json["bounding_box"] {
        #expect(raw is NSNull)
    } else {
        #expect(json["bounding_box"] == nil)
    }
}

// MARK: - aspectFitRect Helper (ItemDetailView Letterbox Math)

/// Runs through the four shape-vs-frame pairings the bbox overlay can
/// hit. A regression here would silently land the highlight in the
/// `.scaledToFit()` letterbox bands again — the original bug PR #21
/// fixes.
@Test func aspectFitRectSquareImageInLandscapeContainer() {
    // Square (1:1) inside landscape (2:1) → image is taller-aspect
    // than the container, so bands sit on the left and right.
    let rect = aspectFitRect(
        for: CGSize(width: 100, height: 100),
        in: CGSize(width: 400, height: 200)
    )

    #expect(rect.width == 200)
    #expect(rect.height == 200)
    #expect(rect.minX == 100) // (400 - 200) / 2
    #expect(rect.minY == 0)
}

@Test func aspectFitRectPortraitImageInLandscapeContainer() {
    // Portrait (1:2) inside landscape (2:1) → bands left/right.
    let rect = aspectFitRect(
        for: CGSize(width: 100, height: 200),
        in: CGSize(width: 400, height: 200)
    )

    #expect(rect.width == 100) // 200 * (100/200)
    #expect(rect.height == 200)
    #expect(rect.minX == 150) // (400 - 100) / 2
    #expect(rect.minY == 0)
}

@Test func aspectFitRectLandscapeImageInPortraitContainer() {
    // Landscape (2:1) inside portrait (1:2) → bands above/below.
    let rect = aspectFitRect(
        for: CGSize(width: 200, height: 100),
        in: CGSize(width: 200, height: 400)
    )

    #expect(rect.width == 200)
    #expect(rect.height == 100) // 200 / (200/100)
    #expect(rect.minX == 0)
    #expect(rect.minY == 150) // (400 - 100) / 2
}

@Test func aspectFitRectSquareImageInSquareContainer() {
    // Equal aspect ratios → image fills the container, no bands.
    let rect = aspectFitRect(
        for: CGSize(width: 100, height: 100),
        in: CGSize(width: 300, height: 300)
    )

    #expect(rect.width == 300)
    #expect(rect.height == 300)
    #expect(rect.minX == 0)
    #expect(rect.minY == 0)
}

@Test func aspectFitRectReturnsZeroForDegenerateInputs() {
    // Defensive: zero/non-finite inputs would propagate NaN through
    // the overlay rect. Guard returns `.zero` instead.
    #expect(aspectFitRect(for: .zero, in: CGSize(width: 100, height: 100)) == .zero)
    #expect(aspectFitRect(for: CGSize(width: 100, height: 100), in: .zero) == .zero)
    #expect(aspectFitRect(
        for: CGSize(width: CGFloat.infinity, height: 100),
        in: CGSize(width: 100, height: 100)
    ) == .zero)
}
