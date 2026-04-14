import Foundation

struct StyleRule: Codable, Identifiable, Sendable {
    let id: UUID
    let archetypeId: UUID
    let slotRequirements: [SlotRequirement]
    let weight: Double
    let boostConditions: BoostConditions?
    let penaltyConditions: PenaltyConditions?
    let preferredHarmony: String
    let proportionRule: ProportionRule?
    let textureRule: TextureRule?

    enum CodingKeys: String, CodingKey {
        case id
        case archetypeId = "archetype_id"
        case slotRequirements = "slot_requirements"
        case weight
        case boostConditions = "boost_conditions"
        case penaltyConditions = "penalty_conditions"
        case preferredHarmony = "preferred_harmony"
        case proportionRule = "proportion_rule"
        case textureRule = "texture_rule"
    }
}

struct SlotRequirement: Codable, Sendable {
    let category: String
    let subcategories: [String]?
    let isRequired: Bool

    enum CodingKeys: String, CodingKey {
        case category, subcategories
        case isRequired = "is_required"
    }
}

struct BoostConditions: Codable, Sendable {
    let seasonalBoosts: [String: Double]?
    let dayOfWeekBoosts: [String: Double]?

    enum CodingKeys: String, CodingKey {
        case seasonalBoosts = "seasonal_boosts"
        case dayOfWeekBoosts = "day_of_week_boosts"
    }
}

struct PenaltyConditions: Codable, Sendable {
    let avoidSeasons: [String]?
    let avoidOccasions: [String]?

    enum CodingKeys: String, CodingKey {
        case avoidSeasons = "avoid_seasons"
        case avoidOccasions = "avoid_occasions"
    }
}

struct ProportionRule: Codable, Sendable {
    let topFit: [String]?
    let bottomFit: [String]?
    let allowed: [[String]]?
    let forbidden: [[String]]?

    enum CodingKeys: String, CodingKey {
        case topFit = "top_fit"
        case bottomFit = "bottom_fit"
        case allowed, forbidden
    }
}

struct TextureRule: Codable, Sendable {
    let minTextures: Int?
    let maxTextures: Int?
    let requiredContrast: Bool?

    enum CodingKeys: String, CodingKey {
        case minTextures = "min_textures"
        case maxTextures = "max_textures"
        case requiredContrast = "required_contrast"
    }
}
