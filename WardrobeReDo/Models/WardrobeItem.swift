import Foundation

struct WardrobeItem: Codable, Identifiable, Sendable {
    let id: UUID
    let userId: UUID
    var imagePath: String
    var thumbnailPath: String
    /// Path to the background-masked JPEG produced by
    /// `ClothingExtractionService`. Nil for rows uploaded before
    /// migration 00007 — the UI should fall back to `imagePath` in
    /// that case and treat them as "legacy unmasked."
    var maskedImagePath: String?
    /// Synthetic confidence bucket for the mask. Nil on legacy rows.
    var extractionConfidence: ExtractionConfidence?
    /// UUID shared by every `wardrobe_items` row cut out of the same
    /// source capture (e.g. four rows extracted from one photo of a
    /// person in a suit). Nil on legacy rows and on single-item
    /// captures that never entered the "Save & add another garment"
    /// loop. See migration 00008.
    var sourcePhotoId: UUID?
    /// Storage path to the unmasked original source JPEG under
    /// `{userId}/source/{sourcePhotoId}/original.jpg`. Uploaded once
    /// per capture, reused by every garment with the same
    /// `sourcePhotoId`. Nil iff `sourcePhotoId` is nil.
    var sourcePhotoPath: String?
    var category: ClothingCategory
    var subcategory: ClothingSubcategory
    var dominantColors: [ColorProfile]
    var texture: TextureType?
    var fitAttribute: FitAttribute?
    var formalityComponents: FormalityComponents?
    var formalityComputed: Double?
    var seasons: [Season]
    var occasions: [Occasion]
    var visualWeight: VisualWeight?
    var wearCount: Int
    var lastWornAt: Date?
    var isArchived: Bool
    /// Per-field provenance of the auto-attribute pre-fill: for every
    /// field that the ML pipeline pre-seeded, records whether the
    /// final saved value matches the pre-fill (`"ai"`), was overridden
    /// by the user (`"user_changed_from_ai"`), or was typed from
    /// scratch with no pre-fill (`"user"`). See migration 00009.
    /// Empty (not nil) on legacy rows saved before migration 00009 —
    /// Postgres defaults the column to `'{}'::jsonb`.
    var detectedAttributes: [String: String]
    /// Normalized [0, 1] bounding box of the detected garment within
    /// `sourcePhotoPath`. Used by the item detail view to dim
    /// everything outside the bbox so two items extracted from the
    /// same multi-garment capture render distinctly. Nil for legacy
    /// items predating migration 00013 OR for single-item captures
    /// where no bbox was recorded — the detail view falls back to a
    /// plain image render in that case.
    var boundingBox: BoundingBoxCodable?
    let createdAt: Date
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
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
        case formalityComponents = "formality_components"
        case formalityComputed = "formality_computed"
        case seasons, occasions
        case visualWeight = "visual_weight"
        case wearCount = "wear_count"
        case lastWornAt = "last_worn_at"
        case isArchived = "is_archived"
        case detectedAttributes = "detected_attributes"
        case boundingBox = "bounding_box"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    init(
        id: UUID,
        userId: UUID,
        imagePath: String,
        thumbnailPath: String,
        maskedImagePath: String? = nil,
        extractionConfidence: ExtractionConfidence? = nil,
        sourcePhotoId: UUID? = nil,
        sourcePhotoPath: String? = nil,
        category: ClothingCategory,
        subcategory: ClothingSubcategory,
        dominantColors: [ColorProfile],
        texture: TextureType? = nil,
        fitAttribute: FitAttribute? = nil,
        formalityComponents: FormalityComponents? = nil,
        formalityComputed: Double? = nil,
        seasons: [Season],
        occasions: [Occasion],
        visualWeight: VisualWeight? = nil,
        wearCount: Int = 0,
        lastWornAt: Date? = nil,
        isArchived: Bool = false,
        detectedAttributes: [String: String] = [:],
        boundingBox: BoundingBoxCodable? = nil,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
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
        self.formalityComponents = formalityComponents
        self.formalityComputed = formalityComputed
        self.seasons = seasons
        self.occasions = occasions
        self.visualWeight = visualWeight
        self.wearCount = wearCount
        self.lastWornAt = lastWornAt
        self.isArchived = isArchived
        self.detectedAttributes = detectedAttributes
        self.boundingBox = boundingBox
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        userId = try c.decode(UUID.self, forKey: .userId)
        imagePath = try c.decode(String.self, forKey: .imagePath)
        thumbnailPath = try c.decode(String.self, forKey: .thumbnailPath)
        maskedImagePath = try c.decodeIfPresent(String.self, forKey: .maskedImagePath)
        extractionConfidence = try c.decodeIfPresent(ExtractionConfidence.self, forKey: .extractionConfidence)
        sourcePhotoId = try c.decodeIfPresent(UUID.self, forKey: .sourcePhotoId)
        sourcePhotoPath = try c.decodeIfPresent(String.self, forKey: .sourcePhotoPath)
        category = try c.decode(ClothingCategory.self, forKey: .category)
        subcategory = try c.decode(ClothingSubcategory.self, forKey: .subcategory)
        dominantColors = try c.decode([ColorProfile].self, forKey: .dominantColors)
        texture = try c.decodeIfPresent(TextureType.self, forKey: .texture)
        fitAttribute = try c.decodeIfPresent(FitAttribute.self, forKey: .fitAttribute)
        formalityComponents = try c.decodeIfPresent(FormalityComponents.self, forKey: .formalityComponents)
        formalityComputed = try c.decodeIfPresent(Double.self, forKey: .formalityComputed)
        seasons = try c.decode([Season].self, forKey: .seasons)
        occasions = try c.decode([Occasion].self, forKey: .occasions)
        visualWeight = try c.decodeIfPresent(VisualWeight.self, forKey: .visualWeight)
        wearCount = try c.decode(Int.self, forKey: .wearCount)
        lastWornAt = try c.decodeIfPresent(Date.self, forKey: .lastWornAt)
        isArchived = try c.decode(Bool.self, forKey: .isArchived)
        // Default to empty map for any legacy row where PostgREST
        // happens to omit the column (shouldn't occur post-00009 but
        // keeps old test fixtures + pre-migration restores decodable).
        detectedAttributes = try c.decodeIfPresent([String: String].self, forKey: .detectedAttributes) ?? [:]
        // Nil for rows predating migration 00013, for legacy rows
        // where the column is null, and for single-item captures where
        // no bbox was recorded.
        boundingBox = try c.decodeIfPresent(BoundingBoxCodable.self, forKey: .boundingBox)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
    }
}

struct ColorProfile: Codable, Sendable {
    let hex: String
    let hue: Double
    let saturation: Double
    let lightness: Double
    let percentage: Double
    let colorFamily: String
    let isNeutral: Bool

    enum CodingKeys: String, CodingKey {
        case hex, hue, saturation, lightness, percentage
        case colorFamily = "color_family"
        case isNeutral = "is_neutral"
    }
}

struct FormalityComponents: Codable, Sendable {
    let colorBrightness: Double
    let textureSmoothness: Double
    let patternScale: Double
    let structuralScore: Double

    enum CodingKeys: String, CodingKey {
        case colorBrightness = "color_brightness"
        case textureSmoothness = "texture_smoothness"
        case patternScale = "pattern_scale"
        case structuralScore = "structural_score"
    }
}

/// Normalized [0, 1] bounding box of a detected garment within a
/// source photo. Persisted as JSONB on `wardrobe_items.bounding_box`
/// (migration 00013). Coordinates survive any future image resize /
/// re-encode without recomputation.
///
/// Example payload:
///
///     {"x": 0.1, "y": 0.4, "width": 0.3, "height": 0.5}
struct BoundingBoxCodable: Codable, Sendable, Equatable, Hashable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    /// CGRect projection of the normalized box. Multiply by the
    /// rendered image size at the call site to get a pixel rect.
    var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }

    init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// Convenience round-trip from a CGRect produced by the on-device
    /// extraction pipeline. Inputs are expected to already be in
    /// normalized [0, 1] coordinates — this initializer doesn't clamp.
    init(_ rect: CGRect) {
        self.x = Double(rect.minX)
        self.y = Double(rect.minY)
        self.width = Double(rect.width)
        self.height = Double(rect.height)
    }
}
