import Foundation
import Testing
@testable import WardrobeReDo

// MARK: - JSON Round-Trip Tests

@Test func colorProfileEncodeDecodeRoundTrip() throws {
    let original = TestFixtures.makeColorProfile()
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(ColorProfile.self, from: data)

    #expect(decoded.hex == original.hex)
    #expect(decoded.hue == original.hue)
    #expect(decoded.saturation == original.saturation)
    #expect(decoded.lightness == original.lightness)
    #expect(decoded.percentage == original.percentage)
    #expect(decoded.colorFamily == original.colorFamily)
    #expect(decoded.isNeutral == original.isNeutral)
}

@Test func colorProfileSnakeCaseCodingKeys() throws {
    let profile = TestFixtures.makeColorProfile(colorFamily: "navy", isNeutral: false)
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .useDefaultKeys
    let data = try encoder.encode(profile)
    let json = String(data: data, encoding: .utf8)!

    #expect(json.contains("\"color_family\""))
    #expect(json.contains("\"is_neutral\""))
    #expect(!json.contains("\"colorFamily\""))
}

@Test func scoreBreakdownEncodeDecodeRoundTrip() throws {
    let original = TestFixtures.makeScoreBreakdown()
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(ScoreBreakdown.self, from: data)

    #expect(decoded.proportion == original.proportion)
    #expect(decoded.colorHarmony == original.colorHarmony)
    #expect(decoded.textureMix == original.textureMix)
    #expect(decoded.formality == original.formality)
    #expect(decoded.formula == original.formula)
    #expect(decoded.versatility == original.versatility)
    #expect(decoded.occasion == original.occasion)
}

@Test func scoreBreakdownSnakeCaseKeys() throws {
    let breakdown = TestFixtures.makeScoreBreakdown()
    let data = try JSONEncoder().encode(breakdown)
    let json = String(data: data, encoding: .utf8)!

    #expect(json.contains("\"color_harmony\""))
    #expect(json.contains("\"texture_mix\""))
    #expect(!json.contains("\"colorHarmony\""))
}

@Test func outfitEncodeDecodeRoundTrip() throws {
    let original = TestFixtures.makeOutfit(
        score: 0.85,
        scoreBreakdown: TestFixtures.makeScoreBreakdown(),
        reaction: "love",
        isWorn: true
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(original)

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(Outfit.self, from: data)

    #expect(decoded.id == original.id)
    #expect(decoded.editorialName == original.editorialName)
    #expect(decoded.score == original.score)
    #expect(decoded.reaction == original.reaction)
    #expect(decoded.isWorn == original.isWorn)
    #expect(decoded.scoreBreakdown != nil)
}

@Test func outfitSnakeCaseKeys() throws {
    let outfit = TestFixtures.makeOutfit()
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(outfit)
    let json = String(data: data, encoding: .utf8)!

    #expect(json.contains("\"user_id\""))
    #expect(json.contains("\"archetype_id\""))
    #expect(json.contains("\"editorial_name\""))
    #expect(json.contains("\"is_worn\""))
    #expect(json.contains("\"created_at\""))
}

@Test func outfitSlotEncodeDecodeRoundTrip() throws {
    let original = OutfitSlot(
        id: UUID(), outfitId: UUID(), wardrobeItemId: UUID(),
        slotName: "top", role: "hero"
    )
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(OutfitSlot.self, from: data)

    #expect(decoded.id == original.id)
    #expect(decoded.outfitId == original.outfitId)
    #expect(decoded.wardrobeItemId == original.wardrobeItemId)
    #expect(decoded.slotName == original.slotName)
    #expect(decoded.role == original.role)
}

@Test func wardrobeItemEncodeDecodeRoundTrip() throws {
    let original = TestFixtures.makeWardrobeItem(
        texture: .leather,
        fitAttribute: .slim,
        seasons: [.fall, .winter],
        occasions: [.casual, .date]
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(original)

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(WardrobeItem.self, from: data)

    #expect(decoded.id == original.id)
    #expect(decoded.category == .top)
    #expect(decoded.subcategory == .tshirt)
    #expect(decoded.texture == .leather)
    #expect(decoded.fitAttribute == .slim)
    #expect(decoded.seasons == [.fall, .winter])
    #expect(decoded.occasions == [.casual, .date])
    #expect(decoded.dominantColors.count == 1)
}

@Test func profileEncodeDecodeRoundTrip() throws {
    let prefs = StylePreferences(
        favoriteArchetypeFamilies: ["classic", "modern"],
        preferredOccasions: ["casual"],
        avoidColors: nil
    )
    let original = TestFixtures.makeProfile(stylePreferences: prefs)

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(original)

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(Profile.self, from: data)

    #expect(decoded.id == original.id)
    #expect(decoded.displayName == "Test User")
    #expect(decoded.onboardingCompleted == true)
    #expect(decoded.stylePreferences?.favoriteArchetypeFamilies == ["classic", "modern"])
}

@Test func styleArchetypeEncodeDecodeRoundTrip() throws {
    let original = TestFixtures.makeStyleArchetype(
        name: "urban_edge",
        family: "streetwear",
        editorialName: "Urban Edge",
        formalityMin: 0.1,
        formalityMax: 0.4
    )
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(StyleArchetype.self, from: data)

    #expect(decoded.id == original.id)
    #expect(decoded.name == "urban_edge")
    #expect(decoded.family == "streetwear")
    #expect(decoded.editorialName == "Urban Edge")
    #expect(decoded.formalityMin == 0.1)
    #expect(decoded.formalityMax == 0.4)
    #expect(decoded.seasons.count == 4)
    #expect(decoded.occasions == ["casual"])
}

@Test func styleRuleEncodeDecodeRoundTrip() throws {
    let original = TestFixtures.makeStyleRule(
        weight: 0.8,
        preferredHarmony: "complementary"
    )
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(StyleRule.self, from: data)

    #expect(decoded.id == original.id)
    #expect(decoded.weight == 0.8)
    #expect(decoded.preferredHarmony == "complementary")
    #expect(decoded.slotRequirements.count == 3)
    #expect(decoded.slotRequirements[0].isRequired == true)
}
