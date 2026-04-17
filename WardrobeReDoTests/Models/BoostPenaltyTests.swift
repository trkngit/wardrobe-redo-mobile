import Foundation
import Testing
@testable import WardrobeReDo

// MARK: - BoostConditions / PenaltyConditions Tests

@Test func boostConditionsJsonDecoding() throws {
    let json = """
    {
        "seasonal_boosts": {"spring": 0.1, "summer": 0.05},
        "day_of_week_boosts": {"friday": 0.15}
    }
    """.data(using: .utf8)!

    let decoded = try JSONDecoder().decode(BoostConditions.self, from: json)
    #expect(decoded.seasonalBoosts?["spring"] == 0.1)
    #expect(decoded.seasonalBoosts?["summer"] == 0.05)
    #expect(decoded.dayOfWeekBoosts?["friday"] == 0.15)
}

@Test func penaltyConditionsJsonDecoding() throws {
    let json = """
    {
        "avoid_seasons": ["summer"],
        "avoid_occasions": ["formal", "work"]
    }
    """.data(using: .utf8)!

    let decoded = try JSONDecoder().decode(PenaltyConditions.self, from: json)
    #expect(decoded.avoidSeasons?.contains("summer") == true)
    #expect(decoded.avoidOccasions?.count == 2)
}

@Test func boostAndPenaltyConditionsCanBeNil() throws {
    let json = """
    {
        "id": "\(UUID().uuidString)",
        "archetype_id": "\(UUID().uuidString)",
        "slot_requirements": [],
        "weight": 1.0,
        "preferred_harmony": "analogous"
    }
    """.data(using: .utf8)!

    let rule = try JSONDecoder().decode(StyleRule.self, from: json)
    #expect(rule.boostConditions == nil)
    #expect(rule.penaltyConditions == nil)
    #expect(rule.proportionRule == nil)
    #expect(rule.textureRule == nil)
}
