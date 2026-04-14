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
    private let userRepository = UserRepository()

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

    func signOut() async {
        do {
            try await supabase.auth.signOut()
        } catch {
            print("Sign out failed: \(error)")
        }
    }

    func refreshProfile() async {
        guard let userId = try? await supabase.auth.session.user.id else { return }
        await loadProfile(userId: userId)
    }

    private func loadProfile(userId: UUID) async {
        do {
            currentUser = try await userRepository.fetchProfile(userId: userId)
        } catch {
            print("Failed to load profile: \(error)")
        }
    }
}
