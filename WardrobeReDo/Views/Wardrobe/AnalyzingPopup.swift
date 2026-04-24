import SwiftUI

/// Centered card overlay shown on top of `AddItemView` while the
/// extraction pipeline is running. Replaces the inline `.analysis`
/// step (which is being removed in a follow-up commit) with a modal
/// overlay so the underlying capture-source picker stays visible
/// behind a dimmed backdrop and the user has a clear cancel
/// affordance instead of a half-rendered "next" step.
///
/// The view is presentation-only — `isProcessing` lives on
/// `AddItemViewModel`, and the parent decides when to mount or
/// dismiss the overlay via a SwiftUI `.overlay` modifier.
struct AnalyzingPopup: View {
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: Theme.Spacing.lg) {
            ProgressView()
                .progressViewStyle(.circular)
                .scaleEffect(1.4)
                .tint(Color(Theme.Colors.primary))

            VStack(spacing: Theme.Spacing.xs) {
                Text("Analyzing photo…")
                    .font(Theme.Fonts.h3)
                    .foregroundStyle(Color(Theme.Colors.textPrimary))

                Text("Detecting clothing and preparing tap-to-select")
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Color(Theme.Colors.textSecondary))
                    .multilineTextAlignment(.center)
            }

            Button("Cancel", role: .cancel, action: onCancel)
                .font(Theme.Fonts.bodySmall.weight(.medium))
                .padding(.top, Theme.Spacing.sm)
        }
        .padding(Theme.Spacing.xl)
        .frame(maxWidth: 320)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .fill(Color(Theme.Colors.surface))
                .shadow(color: .black.opacity(0.2), radius: 20, y: 4)
        )
    }
}

#Preview {
    ZStack {
        Color(Theme.Colors.background).ignoresSafeArea()
        AnalyzingPopup(onCancel: {})
    }
}
