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
