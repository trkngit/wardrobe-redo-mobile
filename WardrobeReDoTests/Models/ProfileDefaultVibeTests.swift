import Foundation
import Testing
@testable import WardrobeReDo

// MARK: - Profile.defaultVibe (build 6 follow-up)
//
// Pins the backward-compat decoding contract: any row written
// before migration 00015 (i.e. without a `default_vibe` column)
// must still hydrate cleanly as `.balanced`.

@Test func profileDefaultsVibeToBalancedWhenColumnIsMissing() throws {
    let legacy = """
    {
      "id": "11111111-1111-1111-1111-111111111111",
      "display_name": "Legacy User",
      "tier": "free",
      "onboarding_completed": true,
      "created_at": "2026-04-01T00:00:00Z",
      "updated_at": "2026-04-01T00:00:00Z"
    }
    """.data(using: .utf8)!
    let decoder = JSONDecoder()
    let formatter = ISO8601DateFormatter()
    decoder.dateDecodingStrategy = .custom { d in
        let str = try d.singleValueContainer().decode(String.self)
        guard let date = formatter.date(from: str) else {
            throw DecodingError.dataCorruptedError(in: try d.singleValueContainer(),
                                                   debugDescription: "Bad date \(str)")
        }
        return date
    }
    let profile = try decoder.decode(Profile.self, from: legacy)
    #expect(profile.defaultVibe == .balanced)
}

@Test func profileDecodesExplicitDefaultVibe() throws {
    let modern = """
    {
      "id": "11111111-1111-1111-1111-111111111111",
      "display_name": "Build 6 User",
      "tier": "free",
      "onboarding_completed": true,
      "default_vibe": "bold",
      "created_at": "2026-05-11T00:00:00Z",
      "updated_at": "2026-05-11T00:00:00Z"
    }
    """.data(using: .utf8)!
    let decoder = JSONDecoder()
    let formatter = ISO8601DateFormatter()
    decoder.dateDecodingStrategy = .custom { d in
        let str = try d.singleValueContainer().decode(String.self)
        guard let date = formatter.date(from: str) else {
            throw DecodingError.dataCorruptedError(in: try d.singleValueContainer(),
                                                   debugDescription: "Bad date \(str)")
        }
        return date
    }
    let profile = try decoder.decode(Profile.self, from: modern)
    #expect(profile.defaultVibe == .bold)
}

@Test func profileRoundTripsDefaultVibeThroughEncoder() throws {
    let now = Date()
    let profile = Profile(
        id: UUID(),
        displayName: "Test",
        tier: "free",
        onboardingCompleted: true,
        defaultVibe: .adventurous,
        createdAt: now,
        updatedAt: now
    )
    let data = try JSONEncoder().encode(profile)
    let json = String(data: data, encoding: .utf8) ?? ""
    #expect(json.contains("\"default_vibe\":\"adventurous\""))
}
