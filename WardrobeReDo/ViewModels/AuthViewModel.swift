import Foundation
import Observation
import os

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
        return isEmailValid ? nil : "Enter a valid email address"
    }

    var passwordValidationMessage: String? {
        guard !password.isEmpty else { return nil }
        return isPasswordValid ? nil : "8+ characters, uppercase, lowercase, and a number"
    }

    var confirmPasswordMessage: String? {
        guard !confirmPassword.isEmpty else { return nil }
        return passwordsMatch ? nil : "Passwords don't match"
    }

    // MARK: - Dependencies

    private let authService = AuthService()
    private let logger = Logger(subsystem: "com.wardroberedo", category: "Auth")

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
            errorMessage = mapError(error)
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
                infoMessage = "Account created. Check \(email) for a confirmation link, then sign in."
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
            errorMessage = mapError(error)
        }

        isLoading = false
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

    private func mapError(_ error: Error) -> String {
        // Inspect the full error for codes/payloads, not just localizedDescription
        let raw = String(describing: error).lowercased()
        let msg = error.localizedDescription.lowercased()
        let combined = raw + " " + msg

        if combined.contains("email_not_confirmed") || combined.contains("email not confirmed") {
            return AuthError.emailNotConfirmed.localizedDescription
        }
        if combined.contains("invalid_credentials") || combined.contains("invalid login") || combined.contains("invalid credentials") {
            return AuthError.invalidCredentials.localizedDescription
        }
        if combined.contains("user_already_exists") || combined.contains("already registered") || combined.contains("already exists") {
            return AuthError.emailTaken.localizedDescription
        }
        if combined.contains("weak_password") || combined.contains("password should be") {
            return AuthError.weakPassword.localizedDescription
        }
        if combined.contains("over_email_send_rate_limit") || combined.contains("rate limit") || combined.contains("too many requests") {
            return AuthError.rateLimited.localizedDescription
        }
        if combined.contains("database error saving new user") || combined.contains("unexpected_failure") {
            return AuthError.databaseSignupFailure.localizedDescription
        }
        // Surface the real error in development so the issue is visible
        #if DEBUG
        return "Auth error: \(error.localizedDescription)"
        #else
        return "Something went wrong. Please try again."
        #endif
    }
}
