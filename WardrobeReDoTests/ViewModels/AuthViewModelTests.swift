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
