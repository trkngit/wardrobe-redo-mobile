import SwiftUI

/// Build 8 — extracted press-scale style so both PrimaryButton and
/// GhostButton get the same tactile feedback. Scale 0.96 is the
/// same number iOS system buttons use (~4 % shrink); the spring
/// snap-back feels like a physical button release. Applied via
/// `.buttonStyle(.pressScale)` on the underlying SwiftUI Button.
/// Build 51 — promoted from `private` to internal so the shared `Chip`
/// component can reuse the same tactile feedback app-wide.
struct PressScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.7),
                       value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PressScaleButtonStyle {
    static var pressScale: PressScaleButtonStyle { PressScaleButtonStyle() }
}

struct PrimaryButton: View {
    // Build 27 — was `String`, which silently picked SwiftUI's
    // `Text(verbatim: String)` overload and bypassed the catalog
    // entirely. Switching to `LocalizedStringResource` routes
    // every literal call site through the catalog automatically
    // (literals coerce via `ExpressibleByStringLiteral`), so
    // existing `PrimaryButton("Surprise me")` calls render Turkish
    // when the locale is `tr` instead of staying English forever.
    let title: LocalizedStringResource
    let isLoading: Bool
    let action: () -> Void

    init(_ title: LocalizedStringResource, isLoading: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.isLoading = isLoading
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.sm) {
                if isLoading {
                    ProgressView()
                        .tint(.white)
                        .scaleEffect(0.8)
                }
                Text(title)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(Color(Theme.Colors.primary))
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.button))
        }
        // Build 8 — press scale-down for tactile feedback. Bare
        // Button (no style) on iOS draws no visible press state
        // when wrapped in a custom label, so a Surprise-me tap
        // felt unresponsive before the regen kicked in.
        .buttonStyle(.pressScale)
        .disabled(isLoading)
        .opacity(isLoading ? 0.7 : 1)
    }
}

struct GhostButton: View {
    // Build 27 — same `String` → `LocalizedStringResource` fix as
    // PrimaryButton. See that struct's comment for the rationale.
    let title: LocalizedStringResource
    let action: () -> Void

    init(_ title: LocalizedStringResource, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Color(Theme.Colors.primary))
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.button)
                        .stroke(Color(Theme.Colors.primary), lineWidth: 1)
                )
        }
        // Build 8 — same press feedback as PrimaryButton for visual
        // consistency. Useful for the secondary "Try a different
        // item" CTA in the Match tab failure state.
        .buttonStyle(.pressScale)
    }
}

#Preview {
    VStack(spacing: 16) {
        PrimaryButton("Sign In") {}
        PrimaryButton("Loading...", isLoading: true) {}
        GhostButton("Create Account") {}
    }
    .padding()
}
