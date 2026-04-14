import Foundation
import Supabase

@MainActor
final class UserRepository {
    private let supabase = SupabaseManager.shared.client

    func fetchProfile(userId: UUID) async throws -> Profile {
        try await supabase
            .from("profiles")
            .select()
            .eq("id", value: userId)
            .single()
            .execute()
            .value
    }

    func updateProfile(_ profile: Profile) async throws -> Profile {
        try await supabase
            .from("profiles")
            .update(profile)
            .eq("id", value: profile.id)
            .select()
            .single()
            .execute()
            .value
    }

    func updateDisplayName(userId: UUID, name: String) async throws {
        try await supabase
            .from("profiles")
            .update(["display_name": name])
            .eq("id", value: userId)
            .execute()
    }

    func completeOnboarding(userId: UUID) async throws {
        try await supabase
            .from("profiles")
            .update(["onboarding_completed": true])
            .eq("id", value: userId)
            .execute()
    }

    func updateStylePreferences(userId: UUID, preferences: StylePreferences) async throws {
        try await supabase
            .from("profiles")
            .update(["style_preferences": preferences])
            .eq("id", value: userId)
            .execute()
    }
}
