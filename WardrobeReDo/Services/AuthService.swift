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

    /// Build 39 — Apple gives us the user's `fullName` exactly once
    /// (on the FIRST sign in for a given Apple ID) as a
    /// `PersonNameComponents`. The Supabase `signInWithIdToken`
    /// flow doesn't accept supplementary metadata, so the
    /// `handle_new_user` trigger that fires on user creation can't
    /// see this name — it falls back to the email prefix.
    ///
    /// This method, called from `AuthViewModel.signInWithApple`
    /// right after a successful sign-in, writes the name directly
    /// into `public.profiles.display_name`. RLS allows the
    /// authenticated user to update their own profile row, so the
    /// session we just established is sufficient.
    ///
    /// Silently no-ops on failure: a stale display name ("User")
    /// is strictly nicer than a sign-in flow that "succeeds" then
    /// throws an error from a polish path. The session is already
    /// live by the time we get here.
    func updateProfileDisplayName(_ name: String, userId: UUID) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try await supabase
                .from("profiles")
                .update(["display_name": trimmed])
                .eq("id", value: userId)
                .execute()
        } catch {
            // Best-effort polish — log and move on. The trigger's
            // fallback already wrote SOMETHING into display_name.
            // We don't want a 4xx here to surface as a sign-in
            // failure for a user who is, by every meaningful
            // measure, signed in.
            print("[AuthService] updateProfileDisplayName failed (non-fatal): \(error)")
        }
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
        // Build 40 — `String(localized:)` resolves each case against
        // the catalog so Turkish locale users see Turkish messages
        // instead of the English fallback. Catalog keys are the
        // English source strings themselves (development language is
        // `en`), so adding a `tr` translation per key is all the
        // localizer / next migration has to ship.
        switch self {
        case .noSession: String(localized: "Unable to create session. Please try again.")
        case .invalidCredentials: String(localized: "Invalid email or password.")
        case .weakPassword: String(localized: "Password must be at least 8 characters with uppercase, lowercase, and a number.")
        case .emailTaken: String(localized: "An account with this email already exists.")
        case .emailNotConfirmed: String(localized: "Please confirm your email before signing in. Check your inbox.")
        case .databaseSignupFailure: String(localized: "Account creation is currently unavailable. The team has been notified.")
        case .rateLimited: String(localized: "Too many attempts. Please wait a minute and try again.")
        }
    }
}
