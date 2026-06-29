import Testing
@testable import WardrobeReDo

// MARK: - AuthViewModel Tests

@Test @MainActor func authEmailValidEmpty() {
    let vm = AuthViewModel()
    vm.email = ""
    #expect(vm.isEmailValid == false)
}

@Test @MainActor func authEmailValidCorrect() {
    let vm = AuthViewModel()
    vm.email = "test@example.com"
    #expect(vm.isEmailValid == true)
}

@Test @MainActor func authEmailInvalidPartial() {
    let vm = AuthViewModel()
    vm.email = "test@"
    #expect(vm.isEmailValid == false)
}

@Test @MainActor func authEmailInvalidNoAt() {
    let vm = AuthViewModel()
    vm.email = "testexample.com"
    #expect(vm.isEmailValid == false)
}

@Test @MainActor func authPasswordInvalidTooShort() {
    let vm = AuthViewModel()
    vm.password = "Pass1"
    #expect(vm.isPasswordValid == false)
}

@Test @MainActor func authPasswordInvalidNoUppercase() {
    let vm = AuthViewModel()
    vm.password = "password1"
    #expect(vm.isPasswordValid == false)
}

@Test @MainActor func authPasswordInvalidNoNumber() {
    let vm = AuthViewModel()
    vm.password = "Password"
    #expect(vm.isPasswordValid == false)
}

@Test @MainActor func authPasswordInvalidNoLowercase() {
    let vm = AuthViewModel()
    vm.password = "PASSWORD1"
    #expect(vm.isPasswordValid == false)
}

@Test @MainActor func authPasswordValid() {
    let vm = AuthViewModel()
    vm.password = "Password1"
    #expect(vm.isPasswordValid == true)
}

@Test @MainActor func authValidationMessageNilWhenEmpty() {
    let vm = AuthViewModel()
    vm.email = ""
    #expect(vm.emailValidationMessage == nil)

    vm.password = ""
    #expect(vm.passwordValidationMessage == nil)
}

@Test @MainActor func authValidationMessageShownWhenInvalid() {
    let vm = AuthViewModel()
    vm.email = "bad"
    #expect(vm.emailValidationMessage != nil)

    vm.password = "weak"
    #expect(vm.passwordValidationMessage != nil)
}

@Test @MainActor func authCanSignInRequiresValidEmailAndPassword() {
    let vm = AuthViewModel()
    vm.email = "test@example.com"
    vm.password = "12345678"
    #expect(vm.canSignIn == true)

    vm.email = "bad"
    #expect(vm.canSignIn == false)

    vm.email = "test@example.com"
    vm.password = "short"
    #expect(vm.canSignIn == false)
}

@Test @MainActor func authCanSignUpRequiresAllFields() {
    let vm = AuthViewModel()
    vm.email = "test@example.com"
    vm.password = "Password1"
    vm.confirmPassword = "Password1"
    vm.displayName = "Test User"
    #expect(vm.canSignUp == true)
}

@Test @MainActor func authCanSignUpFailsWithMismatchedPasswords() {
    let vm = AuthViewModel()
    vm.email = "test@example.com"
    vm.password = "Password1"
    vm.confirmPassword = "Password2"
    vm.displayName = "Test User"
    #expect(vm.canSignUp == false)
}

@Test @MainActor func authCanSignUpFailsWithShortDisplayName() {
    let vm = AuthViewModel()
    vm.email = "test@example.com"
    vm.password = "Password1"
    vm.confirmPassword = "Password1"
    vm.displayName = "A"
    #expect(vm.canSignUp == false)
}

@Test @MainActor func authToggleModeFlipsShowSignUp() {
    let vm = AuthViewModel()
    #expect(vm.showSignUp == false)
    vm.toggleMode()
    #expect(vm.showSignUp == true)
    vm.toggleMode()
    #expect(vm.showSignUp == false)
}

@Test @MainActor func authToggleModeClearsErrorMessage() {
    let vm = AuthViewModel()
    vm.errorMessage = "Some error"
    vm.toggleMode()
    #expect(vm.errorMessage == nil)
}

// MARK: - AuthErrorMapper

private func failure(
    code: String? = nil,
    status: Int? = nil,
    connectivity: Bool = false,
    description: String = ""
) -> AuthErrorMapper.Failure {
    AuthErrorMapper.Failure(
        errorCode: code,
        statusCode: status,
        isConnectivityFailure: connectivity,
        description: description
    )
}

// --- The WARDROBE-IOS-4 regression: a backend outage on the SIGN-IN path
//     must never be reported as "account creation unavailable". ---

@Test func mapErrorSignIn521IsServerUnreachableNotSignupFailure() {
    // Cloudflare "web server is down" while the Supabase project is paused/restoring.
    let result = AuthErrorMapper.classify(
        failure(code: "unexpected_failure", status: 521,
                description: "AuthError api status 521 web server is down"),
        flow: .signIn
    )
    #expect(result == .serverUnreachable)
    #expect(result != .databaseSignupFailure)
}

@Test func mapErrorSignIn500UnexpectedFailureIsServerUnreachable() {
    // GoTrue 500 / unexpected_failure during a restore — the broad code that
    // used to misfire as databaseSignupFailure on the login path.
    let result = AuthErrorMapper.classify(
        failure(code: "unexpected_failure", status: 500),
        flow: .signIn
    )
    #expect(result == .serverUnreachable)
}

@Test func mapErrorSignInNoNetworkIsServerUnreachable() {
    let result = AuthErrorMapper.classify(failure(connectivity: true), flow: .signIn)
    #expect(result == .serverUnreachable)
}

@Test func mapErrorBareUnexpectedFailureIsServerUnreachable() {
    // No HTTP status surfaced — still a transient backend hiccup, not signup.
    let result = AuthErrorMapper.classify(failure(code: "unexpected_failure"), flow: .signIn)
    #expect(result == .serverUnreachable)
}

// --- Invalid credentials (the common, real sign-in failure). ---

@Test func mapErrorInvalidCredentialsIsInvalidCredentials() {
    let result = AuthErrorMapper.classify(
        failure(code: "invalid_credentials", status: 400),
        flow: .signIn
    )
    #expect(result == .invalidCredentials)
}

@Test func mapErrorEmailNotConfirmedIsEmailNotConfirmed() {
    let result = AuthErrorMapper.classify(
        failure(code: "email_not_confirmed", status: 400),
        flow: .signIn
    )
    #expect(result == .emailNotConfirmed)
}

@Test func mapErrorRateLimitedIsRateLimited() {
    let result = AuthErrorMapper.classify(
        failure(code: "over_email_send_rate_limit", status: 429),
        flow: .signIn
    )
    #expect(result == .rateLimited)
}

// --- Signup-disabled is reachable ONLY on the signup path. ---

@Test func mapErrorSignUpDatabaseErrorIsSignupFailure() {
    // The genuine handle_new_user trigger rollback — only meaningful when
    // creating an account, even though it arrives as a 500.
    let result = AuthErrorMapper.classify(
        failure(code: "unexpected_failure", status: 500,
                description: "Database error saving new user"),
        flow: .signUp
    )
    #expect(result == .databaseSignupFailure)
}

@Test func mapErrorSignInDatabaseErrorTextIsNotSignupFailure() {
    // Same payload, but on the sign-in path it can't be a signup failure —
    // the 500 makes it server-unreachable, never databaseSignupFailure.
    let result = AuthErrorMapper.classify(
        failure(code: "unexpected_failure", status: 500,
                description: "Database error saving new user"),
        flow: .signIn
    )
    #expect(result == .serverUnreachable)
    #expect(result != .databaseSignupFailure)
}

@Test func mapErrorSignUpEmailTakenIsEmailTaken() {
    let result = AuthErrorMapper.classify(
        failure(code: "user_already_exists", status: 422),
        flow: .signUp
    )
    #expect(result == .emailTaken)
}

@Test func mapErrorSignUpWeakPasswordIsWeakPassword() {
    let result = AuthErrorMapper.classify(
        failure(code: "weak_password", status: 422),
        flow: .signUp
    )
    #expect(result == .weakPassword)
}

@Test func mapErrorUnrecognizedIsUnknown() {
    let result = AuthErrorMapper.classify(
        failure(description: "some brand new 4xx we don't map"),
        flow: .signIn
    )
    #expect(result == .unknown)
}
