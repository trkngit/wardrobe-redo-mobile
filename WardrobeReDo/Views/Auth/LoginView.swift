import AuthenticationServices
import SwiftUI

struct LoginView: View {
    @State private var viewModel = AuthViewModel()

    var body: some View {
        ZStack {
            Color(Theme.Colors.background)
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    // Editorial branding
                    VStack(spacing: Theme.Spacing.sm) {
                        Text("Wardrobe")
                            .font(Theme.Fonts.display)
                            .foregroundStyle(Color(Theme.Colors.primary))

                        Text("Your daily style, curated.")
                            .font(Theme.Fonts.body)
                            .foregroundStyle(Color(Theme.Colors.textSecondary))
                    }
                    .padding(.top, 80)
                    .padding(.bottom, Theme.Spacing.xxl)

                    // Build 32 — Apple Sign In is the primary path.
                    // Tap the native button → iOS sheet → Face/Touch
                    // ID → instant session. Bypasses email confirmation
                    // entirely, which is the most common failure mode
                    // for the email path. Sits above both sign-in and
                    // sign-up forms because it covers both cases (Apple
                    // creates the account on first use, signs in on
                    // subsequent uses).
                    appleSignInSection

                    orDivider

                    if viewModel.showSignUp {
                        signUpForm
                    } else {
                        signInForm
                    }
                }
                .padding(.horizontal, Theme.Spacing.lg)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .animation(Theme.Animation.standard, value: viewModel.showSignUp)
    }

    // MARK: - Apple Sign In

    private var appleSignInSection: some View {
        VStack(spacing: Theme.Spacing.md) {
            SignInWithAppleButton(
                .signIn,
                onRequest: { _ in
                    // No-op: the AppleSignInCoordinator on the VM
                    // owns the nonce + scope setup. The native
                    // button still has to be present to render the
                    // system-styled chrome; we just don't use its
                    // request hook.
                },
                onCompletion: { _ in
                    // Same: the coordinator owns the completion
                    // handling. We use the button purely for its
                    // visual treatment. Tap fires `signInWithApple`
                    // which drives the coordinator's own request.
                    Task { await viewModel.signInWithApple() }
                }
            )
            .signInWithAppleButtonStyle(.black)
            .frame(height: 48)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.button))
            // Eat the native button's own action so our `Task`
            // path is the only one that fires. Without this iOS
            // also kicks off its own (uncoordinated) request when
            // the user taps.
            .allowsHitTesting(false)
            .overlay {
                Button {
                    Task { await viewModel.signInWithApple() }
                } label: {
                    Color.clear
                }
                .accessibilityLabel("Sign in with Apple")
            }

            if let error = viewModel.errorMessage, !viewModel.showSignUp {
                errorBanner(error)
            }
        }
        .padding(.bottom, Theme.Spacing.md)
    }

    private var orDivider: some View {
        HStack(spacing: Theme.Spacing.md) {
            Rectangle()
                .fill(Color(Theme.Colors.border))
                .frame(height: 1)
            Text("or")
                .font(Theme.Fonts.caption)
                .foregroundStyle(Color(Theme.Colors.textSecondary))
            Rectangle()
                .fill(Color(Theme.Colors.border))
                .frame(height: 1)
        }
        .padding(.bottom, Theme.Spacing.lg)
    }

    // MARK: - Sign In Form

    private var signInForm: some View {
        VStack(spacing: Theme.Spacing.md) {
            Text("Sign In")
                .font(Theme.Fonts.h2)
                .foregroundStyle(Color(Theme.Colors.textPrimary))
                .frame(maxWidth: .infinity, alignment: .leading)

            EditorialTextField(
                placeholder: "Email",
                text: $viewModel.email,
                validationMessage: viewModel.emailValidationMessage,
                keyboardType: .emailAddress,
                textContentType: .emailAddress
            )
            .textInputAutocapitalization(.never)

            EditorialTextField(
                placeholder: "Password",
                text: $viewModel.password,
                isSecure: true,
                textContentType: .password
            )

            if let info = viewModel.infoMessage {
                infoBanner(info)
            }

            if let error = viewModel.errorMessage {
                errorBanner(error)
            }

            GoldButton("Sign In", isLoading: viewModel.isLoading) {
                Task { await viewModel.signIn() }
            }
            .disabled(!viewModel.canSignIn)
            .opacity(viewModel.canSignIn ? 1 : 0.5)
            .padding(.top, Theme.Spacing.sm)

            divider

            GhostButton("Create Account") {
                viewModel.toggleMode()
            }
        }
    }

    // MARK: - Sign Up Form

    private var signUpForm: some View {
        VStack(spacing: Theme.Spacing.md) {
            Text("Create Account")
                .font(Theme.Fonts.h2)
                .foregroundStyle(Color(Theme.Colors.textPrimary))
                .frame(maxWidth: .infinity, alignment: .leading)

            EditorialTextField(
                placeholder: "Display Name",
                text: $viewModel.displayName,
                textContentType: .name
            )

            EditorialTextField(
                placeholder: "Email",
                text: $viewModel.email,
                validationMessage: viewModel.emailValidationMessage,
                keyboardType: .emailAddress,
                textContentType: .emailAddress
            )
            .textInputAutocapitalization(.never)

            EditorialTextField(
                placeholder: "Password",
                text: $viewModel.password,
                isSecure: true,
                validationMessage: viewModel.passwordValidationMessage,
                textContentType: .newPassword
            )

            EditorialTextField(
                placeholder: "Confirm Password",
                text: $viewModel.confirmPassword,
                isSecure: true,
                validationMessage: viewModel.confirmPasswordMessage,
                textContentType: .newPassword
            )

            if let info = viewModel.infoMessage {
                infoBanner(info)
            }

            if let error = viewModel.errorMessage {
                errorBanner(error)
            }

            GoldButton("Create Account", isLoading: viewModel.isLoading) {
                Task { await viewModel.signUp() }
            }
            .disabled(!viewModel.canSignUp)
            .opacity(viewModel.canSignUp ? 1 : 0.5)
            .padding(.top, Theme.Spacing.sm)

            divider

            GhostButton("Already have an account? Sign In") {
                viewModel.toggleMode()
            }
        }
    }

    // MARK: - Shared Components

    private var divider: some View {
        HStack {
            Rectangle()
                .fill(Color(Theme.Colors.border))
                .frame(height: 1)
            Text("or")
                .font(Theme.Fonts.caption)
                .foregroundStyle(Color(Theme.Colors.textSecondary))
            Rectangle()
                .fill(Color(Theme.Colors.border))
                .frame(height: 1)
        }
        .padding(.vertical, Theme.Spacing.sm)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: "exclamationmark.circle")
            Text(message)
                .font(Theme.Fonts.bodySmall)
        }
        .foregroundStyle(Color(Theme.Colors.destructive))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Spacing.md)
        .background(Color(Theme.Colors.destructive).opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
    }

    private func infoBanner(_ message: String) -> some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: "envelope.badge")
            Text(message)
                .font(Theme.Fonts.bodySmall)
        }
        .foregroundStyle(Color(Theme.Colors.primary))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Spacing.md)
        .background(Color(Theme.Colors.primary).opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
    }
}

#Preview("Sign In") {
    LoginView()
}
