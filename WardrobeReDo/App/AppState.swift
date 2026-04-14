import Foundation
import Observation
import Supabase

@MainActor
@Observable
final class AppState {
    var isAuthenticated = false
    var isLoading = true
    var currentUser: Profile?

    private let supabase = SupabaseManager.shared.client

    func initialize() async {
        do {
            let session = try await supabase.auth.session
            isAuthenticated = true
            await loadProfile(userId: session.user.id)
        } catch {
            isAuthenticated = false
        }
        isLoading = false
    }

    func handleAuthChange() async {
        for await (event, session) in supabase.auth.authStateChanges {
            switch event {
            case .signedIn:
                isAuthenticated = true
                if let userId = session?.user.id {
                    await loadProfile(userId: userId)
                }
            case .signedOut:
                isAuthenticated = false
                currentUser = nil
            default:
                break
            }
        }
    }

    private func loadProfile(userId: UUID) async {
        do {
            let profile: Profile = try await supabase
                .from("profiles")
                .select()
                .eq("id", value: userId)
                .single()
                .execute()
                .value
            currentUser = profile
        } catch {
            print("Failed to load profile: \(error)")
        }
    }
}
