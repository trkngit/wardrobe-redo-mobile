import Foundation

struct Outfit: Codable, Identifiable, Sendable {
    let id: UUID
    let userId: UUID
    let archetypeId: UUID
    var editorialName: String
    var editorialDescription: String?
    let date: String
    let score: Double
    var scoreBreakdown: ScoreBreakdown?
    var reaction: String?
    var isWorn: Bool
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case archetypeId = "archetype_id"
        case editorialName = "editorial_name"
        case editorialDescription = "editorial_description"
        case date, score
        case scoreBreakdown = "score_breakdown"
        case reaction
        case isWorn = "is_worn"
        case createdAt = "created_at"
    }
}

struct ScoreBreakdown: Codable, Sendable {
    let proportion: Double
    let colorHarmony: Double
    let textureMix: Double
    let formality: Double
    let formula: Double
    let versatility: Double
    let occasion: Double

    enum CodingKeys: String, CodingKey {
        case proportion
        case colorHarmony = "color_harmony"
        case textureMix = "texture_mix"
        case formality, formula, versatility, occasion
    }
}

struct OutfitSlot: Codable, Identifiable, Sendable {
    let id: UUID
    let outfitId: UUID
    let wardrobeItemId: UUID
    let slotName: String
    let role: String

    enum CodingKeys: String, CodingKey {
        case id
        case outfitId = "outfit_id"
        case wardrobeItemId = "wardrobe_item_id"
        case slotName = "slot_name"
        case role
    }
}
