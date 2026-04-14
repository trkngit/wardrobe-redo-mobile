import Foundation

struct StyleArchetype: Codable, Identifiable, Sendable {
    let id: UUID
    let name: String
    let family: String
    let editorialName: String
    let description: String
    let formalityMin: Double
    let formalityMax: Double
    let seasons: [String]
    let occasions: [String]
    let moodKeywords: [String]
    let colorPreferences: ArchetypeColorPreferences?
    let texturePreferences: ArchetypeTexturePreferences?
    let proportionPreferences: ArchetypeProportionPreferences?

    enum CodingKeys: String, CodingKey {
        case id, name, family
        case editorialName = "editorial_name"
        case description
        case formalityMin = "formality_min"
        case formalityMax = "formality_max"
        case seasons, occasions
        case moodKeywords = "mood_keywords"
        case colorPreferences = "color_preferences"
        case texturePreferences = "texture_preferences"
        case proportionPreferences = "proportion_preferences"
    }
}

struct ArchetypeColorPreferences: Codable, Sendable {
    let preferredHarmonies: [String]?
    let avoidCombinations: [[String]]?
    let neutralBias: Double?

    enum CodingKeys: String, CodingKey {
        case preferredHarmonies = "preferred_harmonies"
        case avoidCombinations = "avoid_combinations"
        case neutralBias = "neutral_bias"
    }
}

struct ArchetypeTexturePreferences: Codable, Sendable {
    let preferred: [String]?
    let avoided: [String]?
    let maxCount: Int?

    enum CodingKeys: String, CodingKey {
        case preferred, avoided
        case maxCount = "max_count"
    }
}

struct ArchetypeProportionPreferences: Codable, Sendable {
    let preferredBalances: [[String]]?
    let allowOversized: Bool?

    enum CodingKeys: String, CodingKey {
        case preferredBalances = "preferred_balances"
        case allowOversized = "allow_oversized"
    }
}
