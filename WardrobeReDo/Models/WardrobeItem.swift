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
        case createdAt = "created_at"
        case updatedAt = "updated_at"
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
