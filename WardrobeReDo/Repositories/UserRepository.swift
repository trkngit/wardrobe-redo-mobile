import Foundation
import Supabase
// PostgREST is imported transitively via `Supabase`. Xcode 16's Swift 6
// toolchain flags its response types as non-Sendable when they cross the
// main-actor boundary from inside this `@MainActor` repository. Later
// Xcode releases relax this; `@preconcurrency` keeps the same source
// building on both without us having to wait for the SDK to fully audit
// its Sendable surface.
@preconcurrency import PostgREST

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

    /// Build 6 — persist the user's preferred default vibe. The
    /// per-generation slider override stays ephemeral on
    /// `OutfitViewModel.selectedVibe`; this updates only the
    /// stored "where do future generations start" value.
    func updateDefaultVibe(userId: UUID, vibe: VibeStop) async throws {
        try await supabase
            .from("profiles")
            .update(["default_vibe": vibe.rawValue])
            .eq("id", value: userId)
            .execute()
    }
}
