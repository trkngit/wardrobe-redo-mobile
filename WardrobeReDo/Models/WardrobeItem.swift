import Foundation

struct WardrobeItem: Codable, Identifiable, Sendable {
    let id: UUID
    let userId: UUID
    var imagePath: String
    var thumbnailPath: String
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
