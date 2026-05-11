import Foundation

struct Profile: Codable, Identifiable, Sendable {
    let id: UUID
    var displayName: String
    var tier: String
    var stylePreferences: StylePreferences?
    var onboardingCompleted: Bool
    var timezone: String?
    /// Build 6 — user's preferred default vibe for outfit
    /// generation. Defaults to `.balanced` so legacy rows that
    /// pre-date migration 00015 hydrate correctly via the
    /// Codable decoder (see `init(from:)` below).
    var defaultVibe: VibeStop
    let createdAt: Date
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case tier
        case stylePreferences = "style_preferences"
        case onboardingCompleted = "onboarding_completed"
        case timezone
        case defaultVibe = "default_vibe"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    init(
        id: UUID,
        displayName: String,
        tier: String,
        stylePreferences: StylePreferences? = nil,
        onboardingCompleted: Bool,
        timezone: String? = nil,
        defaultVibe: VibeStop = .balanced,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.displayName = displayName
        self.tier = tier
        self.stylePreferences = stylePreferences
        self.onboardingCompleted = onboardingCompleted
        self.timezone = timezone
        self.defaultVibe = defaultVibe
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.displayName = try c.decode(String.self, forKey: .displayName)
        self.tier = try c.decode(String.self, forKey: .tier)
        self.stylePreferences = try c.decodeIfPresent(StylePreferences.self, forKey: .stylePreferences)
        self.onboardingCompleted = try c.decode(Bool.self, forKey: .onboardingCompleted)
        self.timezone = try c.decodeIfPresent(String.self, forKey: .timezone)
        // Pre-migration rows lack the column; default to `.balanced`.
        self.defaultVibe = try c.decodeIfPresent(VibeStop.self, forKey: .defaultVibe) ?? .balanced
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        self.updatedAt = try c.decode(Date.self, forKey: .updatedAt)
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
