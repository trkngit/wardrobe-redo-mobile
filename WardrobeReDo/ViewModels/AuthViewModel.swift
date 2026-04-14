import Foundation
import Observation

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

    // MARK: - Actions

    func signIn() async {
        guard canSignIn else { return }
        isLoading = true
        errorMessage = nil

        do {
            _ = try await authService.signIn(email: email, password: password)
            clearForm()
        } catch {
            errorMessage = mapError(error)
        }

        isLoading = false
    }

    func signUp() async {
        guard canSignUp else { return }
        isLoading = true
        errorMessage = nil

        do {
            _ = try await authService.signUp(
                email: email,
                password: password,
                displayName: displayName.trimmingCharacters(in: .whitespaces)
            )
            clearForm()
        } catch {
            errorMessage = mapError(error)
        }

        isLoading = false
    }

    func toggleMode() {
        showSignUp.toggle()
        errorMessage = nil
    }

    private func clearForm() {
        email = ""
        password = ""
        displayName = ""
        confirmPassword = ""
        errorMessage = nil
    }

    private func mapError(_ error: Error) -> String {
        let message = error.localizedDescription.lowercased()
        if message.contains("invalid login") || message.contains("invalid credentials") {
            return AuthError.invalidCredentials.localizedDescription
        }
        if message.contains("already registered") || message.contains("already exists") {
            return AuthError.emailTaken.localizedDescription
        }
        if message.contains("weak password") || message.contains("password") {
            return AuthError.weakPassword.localizedDescription
        }
        return "Something went wrong. Please try again."
    }
}
