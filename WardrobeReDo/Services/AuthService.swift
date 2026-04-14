import Foundation
import Supabase
import AuthenticationServices

@MainActor
final class AuthService {
    private let supabase = SupabaseManager.shared.client

    // MARK: - Email Auth

    func signUp(email: String, password: String, displayName: String) async throws -> Session {
        let response = try await supabase.auth.signUp(
            email: email,
            password: password,
            data: ["display_name": .string(displayName)]
        )
        guard let session = response.session else {
            throw AuthError.noSession
        }
        return session
    }

    func signIn(email: String, password: String) async throws -> Session {
        try await supabase.auth.signIn(email: email, password: password)
    }

    func signOut() async throws {
        try await supabase.auth.signOut()
    }

    // MARK: - Apple Sign In

    func signInWithApple(idToken: String, nonce: String) async throws -> Session {
        try await supabase.auth.signInWithIdToken(
            credentials: .init(provider: .apple, idToken: idToken, nonce: nonce)
        )
    }

    // MARK: - Session

    var currentSession: Session? {
        get async {
            try? await supabase.auth.session
        }
    }

    var currentUserId: UUID? {
        get async {
            await currentSession?.user.id
        }
    }
}

enum AuthError: LocalizedError {
    case noSession
    case invalidCredentials
    case weakPassword
    case emailTaken

    var errorDescription: String? {
        switch self {
        case .noSession: "Unable to create session. Please try again."
        case .invalidCredentials: "Invalid email or password."
        case .weakPassword: "Password must be at least 8 characters with uppercase, lowercase, and a number."
        case .emailTaken: "An account with this email already exists."
        }
    }
}
