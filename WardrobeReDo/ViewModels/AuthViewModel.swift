import AuthenticationServices
import Foundation
import Observation
import os
// `Auth` (Supabase's GoTrue module) is imported explicitly so its `AuthError`
// can be referenced as `Auth.AuthError` — the app declares its own top-level
// `AuthError`, and same-module names shadow re-exported ones.
import Auth

@MainActor
@Observable
final class AuthViewModel {
    // MARK: - Form State

    var email = ""
    var password = ""
    var displayName = ""
    var confirmPassword = ""

    var isLoading = false
    var errorMessage: String?
    /// Set when sign-up completed but requires email confirmation. Drives a
    /// success banner instead of an error banner in the view.
    var infoMessage: String?
    var showSignUp = false

    // MARK: - Validation

    var isEmailValid: Bool {
        let pattern = #"^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$"#
        return email.range(of: pattern, options: .regularExpression) != nil
    }

    var isPasswordValid: Bool {
        password.count >= 8
        && password.range(of: "[A-Z]", options: .regularExpression) != nil
        && password.range(of: "[a-z]", options: .regularExpression) != nil
        && password.range(of: "[0-9]", options: .regularExpression) != nil
    }

    var isDisplayNameValid: Bool {
        displayName.trimmingCharacters(in: .whitespaces).count >= 2
    }

    var passwordsMatch: Bool {
        password == confirmPassword
    }

    var canSignIn: Bool {
        isEmailValid && password.count >= 8
    }

    var canSignUp: Bool {
        isEmailValid && isPasswordValid && isDisplayNameValid && passwordsMatch
    }

    // MARK: - Validation Messages

    var emailValidationMessage: String? {
        guard !email.isEmpty else { return nil }
        return isEmailValid ? nil : String(localized: "Enter a valid email address")
    }

    var passwordValidationMessage: String? {
        guard !password.isEmpty else { return nil }
        return isPasswordValid ? nil : String(localized: "8+ characters, uppercase, lowercase, and a number")
    }

    var confirmPasswordMessage: String? {
        guard !confirmPassword.isEmpty else { return nil }
        return passwordsMatch ? nil : String(localized: "Passwords don't match")
    }

    // MARK: - Dependencies

    private let authService = AuthService()
    private let logger = Logger(subsystem: "com.wardroberedo", category: "Auth")

    /// Build 32 — long-lived coordinator. The Apple Sign In sheet
    /// needs the delegate + presentation context provider to be
    /// retained for the lifetime of the modal; storing the
    /// coordinator on the VM is the simplest way.
    private let appleCoordinator = AppleSignInCoordinator()

    // MARK: - Actions

    func signIn() async {
        guard canSignIn else { return }
        isLoading = true
        errorMessage = nil
        infoMessage = nil

        do {
            _ = try await authService.signIn(email: email, password: password)
            clearForm()
        } catch {
            // Build 20 — split public category + private reason so
            // we can grep "signIn failed" across production logs
            // without the error description (which can contain the
            // attempted email / a session token in some error
            // shapes) leaking into Console / Sentry.
            LogPrivacy.error(logger, category: "signIn", reason: error)
            errorMessage = mapError(error, flow: .signIn)
        }

        isLoading = false
    }

    func signUp() async {
        guard canSignUp else { return }
        isLoading = true
        errorMessage = nil
        infoMessage = nil

        do {
            let result = try await authService.signUp(
                email: email,
                password: password,
                displayName: displayName.trimmingCharacters(in: .whitespaces)
            )
            switch result {
            case .signedIn:
                clearForm()
            case .confirmationRequired(let email):
                // Build 40 — localized via the catalog key
                // "Account created. Check %@ for a confirmation link, then sign in."
                // String(localized:) with interpolation resolves the
                // key and substitutes %@ with the email.
                infoMessage = String(localized: "Account created. Check \(email) for a confirmation link, then sign in.")
                showSignUp = false
                // Keep email pre-filled, clear password fields
                password = ""
                confirmPassword = ""
                displayName = ""
            }
        } catch {
            // Build 20 — same privacy split as signIn. signUp errors
            // can carry the display name + email; treat as private.
            LogPrivacy.error(logger, category: "signUp", reason: error)
            errorMessage = mapError(error, flow: .signUp)
        }

        isLoading = false
    }

    /// Build 32 — Apple Sign In entry point. Drives the native
    /// iOS sheet via `AppleSignInCoordinator`, then forwards the
    /// identity token + raw nonce to `AuthService.signInWithApple`,
    /// which calls Supabase's `signInWithIdToken` to create or
    /// link the user and return a session. The auth state listener
    /// in `AppState` picks up the new session automatically — same
    /// path as email sign in.
    ///
    /// User-cancellation (tapping outside the sheet) returns
    /// `ASAuthorizationError.canceled`; we swallow that silently
    /// instead of showing an "error" because cancelling is a
    /// normal UX, not a failure.
    func signInWithApple() async {
        isLoading = true
        errorMessage = nil
        infoMessage = nil
        do {
            let credential = try await appleCoordinator.requestCredential()
            let session = try await authService.signInWithApple(
                idToken: credential.idToken,
                nonce: credential.rawNonce
            )

            // Build 39 — Apple returns `fullName` only on the FIRST
            // sign-in for a given Apple ID; capture it now or lose
            // it forever. The trigger that created the profile row
            // could only see JWT claims (no name in Apple's JWT),
            // so it fell back to the email prefix. Overwrite with
            // the actual name, then move on. Non-fatal on failure —
            // the user is already signed in.
            if let displayName = Self.displayName(from: credential.fullName) {
                await authService.updateProfileDisplayName(
                    displayName,
                    userId: session.user.id
                )
            }

            clearForm()
        } catch let error as ASAuthorizationError where error.code == .canceled {
            // User dismissed the sheet — no error UI, just reset.
            logger.info("appleSignIn.cancelled")
        } catch {
            LogPrivacy.error(logger, category: "appleSignIn", reason: error)
            errorMessage = mapError(error, flow: .apple)
        }
        isLoading = false
    }

    /// Format Apple's `PersonNameComponents` into a single display
    /// string. Uses `PersonNameComponentsFormatter` so the result
    /// honours locale conventions (e.g. surname-first for `ja_JP`
    /// without us having to special-case it). Returns nil if the
    /// formatter would yield an empty string — Apple frequently
    /// returns a non-nil `PersonNameComponents` with all fields
    /// nil on subsequent sign-ins.
    private static func displayName(from components: PersonNameComponents?) -> String? {
        guard let components else { return nil }
        let formatter = PersonNameComponentsFormatter()
        formatter.style = .default
        let formatted = formatter.string(from: components).trimmingCharacters(in: .whitespacesAndNewlines)
        return formatted.isEmpty ? nil : formatted
    }

    func toggleMode() {
        showSignUp.toggle()
        errorMessage = nil
        infoMessage = nil
    }

    private func clearForm() {
        email = ""
        password = ""
        displayName = ""
        confirmPassword = ""
        errorMessage = nil
        infoMessage = nil
    }

    private func mapError(_ error: Error, flow: AuthFlow) -> String {
        let mapped = AuthErrorMapper.classify(AuthErrorMapper.failure(from: error), flow: flow)
        #if DEBUG
        // Surface the exact unmapped error in development so a new failure
        // shape is visible instead of swallowed by the generic fallback.
        if mapped == .unknown {
            return "Auth error: \(error.localizedDescription)"
        }
        #endif
        return mapped.errorDescription ?? AuthError.unknown.errorDescription ?? ""
    }
}

/// Which auth flow produced a failure. Signup-specific outcomes (email taken,
/// weak password, the signup-trigger DB failure) are only meaningful when
/// *creating* an account — never when signing in.
///
/// Build 52 — before this split, a single shared mapper attributed a
/// login-time backend outage (an HTTP 521 / 5xx while the Supabase project was
/// paused or restoring) to "Account creation is currently unavailable", which
/// was wrong on both counts: it named account creation on the sign-in path,
/// and it pinned a transient infra outage on a signup problem
/// (Sentry WARDROBE-IOS-4).
enum AuthFlow {
    case signIn
    case signUp
    case apple
}

/// Pure, SDK-agnostic classifier for auth failures. Kept apart from the
/// SwiftUI/Supabase plumbing so it unit-tests without constructing real
/// network errors: `failure(from:)` does the impure extraction, `classify`
/// is a pure function of its normalized inputs.
///
/// Design follows the project debugging rule — surface the *exact* cause and
/// never let a generic wrapper hide it. The HTTP status code and GoTrue error
/// code drive the decision; the lowercased string is only a fallback haystack.
enum AuthErrorMapper {
    /// Normalized view of a failure. `errorCode`/`statusCode` are populated
    /// when the SDK surfaces a typed `Auth.AuthError.api`; `isConnectivityFailure`
    /// flags transport-level `URLError`s; `description` is a lowercased fallback.
    struct Failure: Equatable {
        var errorCode: String?
        var statusCode: Int?
        var isConnectivityFailure: Bool
        var description: String

        init(
            errorCode: String? = nil,
            statusCode: Int? = nil,
            isConnectivityFailure: Bool = false,
            description: String = ""
        ) {
            self.errorCode = errorCode
            self.statusCode = statusCode
            self.isConnectivityFailure = isConnectivityFailure
            self.description = description.lowercased()
        }
    }

    static func classify(_ failure: Failure, flow: AuthFlow) -> AuthError {
        let code = (failure.errorCode ?? "").lowercased()
        let haystack = failure.description
        let status = failure.statusCode

        // 1. Transport-level failure (offline / DNS / TLS / timeout). Never a
        //    credential or signup problem — the backend was simply not reached.
        if failure.isConnectivityFailure { return .serverUnreachable }

        // 2. The one genuinely signup-only server failure: the
        //    `handle_new_user` trigger rolling back with the precise text
        //    "Database error saving new user". Checked before the generic 5xx
        //    rule below because it also arrives as a 500 — but it only makes
        //    sense while *creating* an account. Deliberately NOT keyed off the
        //    broad `unexpected_failure` code, which also fires on the login
        //    path during a pause/restore (the WARDROBE-IOS-4 misfire).
        if flow == .signUp, haystack.contains("database error saving new user") {
            return .databaseSignupFailure
        }

        // 3. Origin 5xx or a Cloudflare edge error (e.g. 521 "web server is
        //    down" while the project is paused/restoring) → backend down.
        if let status, status >= 500 { return .serverUnreachable }
        if haystack.contains("web server is down")
            || haystack.contains("bad gateway")
            || haystack.contains("service unavailable")
            || haystack.contains("gateway timeout")
            || haystack.contains("cloudflare") {
            return .serverUnreachable
        }

        // 4. Invalid credentials (400 / 401 / invalid_grant).
        if code == "invalid_credentials"
            || haystack.contains("invalid_credentials")
            || haystack.contains("invalid_grant")
            || haystack.contains("invalid login")
            || haystack.contains("invalid credentials") {
            return .invalidCredentials
        }

        // 5. Email not yet confirmed.
        if code == "email_not_confirmed" || haystack.contains("email not confirmed") {
            return .emailNotConfirmed
        }

        // 6. Rate limited (429).
        if status == 429
            || code.contains("rate_limit")
            || haystack.contains("rate limit")
            || haystack.contains("too many requests") {
            return .rateLimited
        }

        // 7. Sign-up-only outcomes.
        if flow == .signUp {
            if code == "user_already_exists" || code == "email_exists"
                || haystack.contains("already registered") || haystack.contains("already exists") {
                return .emailTaken
            }
            if code == "weak_password"
                || haystack.contains("weak_password") || haystack.contains("password should be") {
                return .weakPassword
            }
        }

        // 8. A bare `unexpected_failure` with no 5xx status surfaced is still
        //    almost always a transient backend hiccup — prefer "try again"
        //    over a dead-end generic message.
        if code == "unexpected_failure" || haystack.contains("unexpected_failure") {
            return .serverUnreachable
        }

        return .unknown
    }

    /// Impure extraction of a `Failure` from a real error: pulls the typed
    /// HTTP status + GoTrue code out of `Auth.AuthError.api`, flags
    /// transport-level `URLError`s, and keeps a lowercased string fallback.
    static func failure(from error: Error) -> Failure {
        var errorCode: String?
        var statusCode: Int?
        var connectivity = false

        // A non-cancelled URLError is unambiguously "couldn't reach the server".
        if let urlError = error as? URLError, urlError.code != .cancelled {
            connectivity = true
        }

        // `Auth.AuthError` is qualified to disambiguate from the app's own
        // `AuthError` declared in AuthService.swift.
        if let authError = error as? Auth.AuthError {
            switch authError {
            case let .api(_, code, _, response):
                errorCode = code.rawValue
                statusCode = response.statusCode
            case .weakPassword:
                errorCode = "weak_password"
            case .sessionMissing:
                errorCode = "session_not_found"
            default:
                break
            }
        }

        let description = String(describing: error) + " " + error.localizedDescription
        return Failure(
            errorCode: errorCode,
            statusCode: statusCode,
            isConnectivityFailure: connectivity,
            description: description
        )
    }
}
