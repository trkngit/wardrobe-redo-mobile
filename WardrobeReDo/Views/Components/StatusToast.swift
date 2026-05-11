import SwiftUI

/// Build 7 — small, reusable confirmation toast.
///
/// Extracted from the `cancellationToast` pattern in `AddItemView`
/// so the Outfits + Match tabs can confirm "your tap committed" when
/// a picker change triggers a debounced regeneration. Mounted at the
/// bottom of the host view via `.overlay(alignment: .bottom)`.
///
/// Visual style mirrors the cancellation toast (Capsule + shadow +
/// system-image icon) so the app stays visually consistent.
///
/// Lifecycle: the host VM sets a `String?` message field; the view
/// observes it, mounts the toast on `message != nil`, and clears the
/// field after ~1.5 s via an `.onChange` task. No global toast queue
/// — each surface owns its own message slot.
struct StatusToast: View {
    let message: String
    var systemImage: String = "checkmark.circle.fill"

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: systemImage)
                .foregroundStyle(Color(Theme.Colors.primary))
            Text(message)
                .font(Theme.Fonts.bodySmall.weight(.medium))
                .foregroundStyle(Color(Theme.Colors.textPrimary))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.md)
        .background(
            Capsule()
                .fill(Color(Theme.Colors.surface))
                .shadow(color: .black.opacity(0.15), radius: 12, y: 2)
        )
        .accessibilityAddTraits(.isStaticText)
    }
}

extension View {
    /// Mount a `StatusToast` at the bottom of the receiver and clear
    /// `message` after `duration` seconds. The toast's transition is
    /// the same slide-up-with-fade used by `AddItemView`'s
    /// cancellation toast — visual consistency across surfaces.
    ///
    /// Pass a `Binding<String?>`: setting it surfaces the toast;
    /// the modifier auto-nils it after the visible duration. Tests
    /// can observe the same binding to verify the surface fired.
    func statusToast(
        message: Binding<String?>,
        duration: TimeInterval = 1.5
    ) -> some View {
        self.overlay(alignment: .bottom) {
            if let text = message.wrappedValue {
                StatusToast(message: text)
                    .padding(.bottom, Theme.Spacing.xl)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task(id: text) {
                        try? await Task.sleep(for: .seconds(duration))
                        // Only clear if no newer message arrived
                        // mid-flight — Tasks tagged with `id: text`
                        // are auto-cancelled when `text` changes,
                        // so this branch only runs for the most
                        // recent message.
                        if message.wrappedValue == text {
                            message.wrappedValue = nil
                        }
                    }
            }
        }
        .animation(.spring(duration: 0.3), value: message.wrappedValue)
    }
}
