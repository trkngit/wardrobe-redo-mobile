import SwiftUI

struct LoginView: View {
    var body: some View {
        ZStack {
            Color(Theme.Colors.background)
                .ignoresSafeArea()

            VStack(spacing: Theme.Spacing.xl) {
                Spacer()

                // Editorial branding
                VStack(spacing: Theme.Spacing.sm) {
                    Text("Wardrobe")
                        .font(Theme.Fonts.display)
                        .foregroundStyle(Color(Theme.Colors.primary))
                    Text("Your daily style, curated.")
                        .font(Theme.Fonts.body)
                        .foregroundStyle(Color(Theme.Colors.textSecondary))
                }

                Spacer()

                // Auth form placeholder — implemented in Sprint 1
                VStack(spacing: Theme.Spacing.md) {
                    Text("Sign in to continue")
                        .font(Theme.Fonts.h3)
                        .foregroundStyle(Color(Theme.Colors.textPrimary))
                }

                Spacer()
            }
            .padding(.horizontal, Theme.Spacing.lg)
        }
    }
}

#Preview {
    LoginView()
}
