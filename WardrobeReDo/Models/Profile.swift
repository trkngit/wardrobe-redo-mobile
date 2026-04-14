import Foundation

struct Profile: Codable, Identifiable, Sendable {
    let id: UUID
    var displayName: String
    var tier: String
    var stylePreferences: StylePreferences?
    var onboardingCompleted: Bool
    var timezone: String?
    let createdAt: Date
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case tier
        case stylePreferences = "style_preferences"
        case onboardingCompleted = "onboarding_completed"
        case timezone
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

struct StylePreferences: Codable, Sendable {
    var favoriteArchetypeFamilies: [String]?
    var preferredOccasions: [String]?
    var avoidColors: [String]?

    enum CodingKeys: String, CodingKey {
        case favoriteArchetypeFamilies = "favorite_archetype_families"
        case preferredOccasions = "preferred_occasions"
        case avoidColors = "avoid_colors"
    }
}
