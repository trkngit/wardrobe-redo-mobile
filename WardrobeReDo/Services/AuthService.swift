import Foundation
import Supabase
import AuthenticationServices

@MainActor
final class AuthService {
    private let supabase = SupabaseManager.shared.client

    // MARK: - Email Auth

    /// Result of a sign-up attempt. Email-confirmation projects return
    /// `.confirmationRequired` with no session until the user clicks the link.
    enum SignUpResult: Sendable {
        case signedIn(Session)
        case confirmationRequired(email: String)
    }

    func signUp(email: String, password: String, displayName: String) async throws -> SignUpResult {
        let response = try await supabase.auth.signUp(
            email: email,
            password: password,
            data: ["display_name": .string(displayName)]
        )
        if let session = response.session {
            return .signedIn(session)
        }
        return .confirmationRequired(email: email)
    }

    func signIn(email: String, password: String) async throws -> Session {
        try await supabase.auth.signIn(email: email, password: password)
    }

    func signOut() async throws {
        try await supabase.auth.signOut()
    }

    func resendConfirmation(email: String) async throws {
        try await supabase.auth.resend(email: email, type: .signup)
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
    case emailNotConfirmed
    case databaseSignupFailure
    case rateLimited

    var errorDescription: String? {
        switch self {
        case .noSession: "Unable to create session. Please try again."
        case .invalidCredentials: "Invalid email or password."
        case .weakPassword: "Password must be at least 8 characters with uppercase, lowercase, and a number."
        case .emailTaken: "An account with this email already exists."
        case .emailNotConfirmed: "Please confirm your email before signing in. Check your inbox."
        case .databaseSignupFailure: "Account creation is currently unavailable. The team has been notified."
        case .rateLimited: "Too many attempts. Please wait a minute and try again."
        }
    }
}
