import SwiftUI

/// 5-stop pill-segment control bound to a `VibeStop`. Drives the
/// outfit generator's per-generation vibe (Safe → Bold). Lives in
/// `Views/Components` because the same control appears in the
/// generation surface, the "What goes with this?" match flow, and
/// Settings (default-vibe row).
///
/// Build 6 — the visual style is intentionally restrained: a row of
/// labelled pills that highlights the active stop. We don't show a
/// continuous slider because user testing on similar features
/// suggested discrete labels read more clearly than a percentage
/// scale.
struct VibeSelector: View {
    @Binding var vibe: VibeStop
    var onChange: ((VibeStop) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack(spacing: Theme.Spacing.xs) {
                ForEach(VibeStop.allCases) { stop in
                    pill(for: stop)
                }
            }
            // Build 14 — localized tagline. Pulls from the catalog
            // ("Polished classics" → "Şık klasikler" under tr).
            Text(vibe.localizedTagline)
                .font(Theme.Fonts.bodySmall)
                .foregroundStyle(Color(Theme.Colors.textSecondary))
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("Vibe: \(vibe.displayName). \(vibe.tagline)")
        }
        .animation(Theme.Animation.standard, value: vibe)
    }

    private func pill(for stop: VibeStop) -> some View {
        let isSelected = stop == vibe
        return Button {
            guard stop != vibe else { return }
            vibe = stop
            onChange?(stop)
        } label: {
            // Build 14 — localized stop label.
            Text(stop.localizedName)
                .font(Theme.Fonts.bodySmall.weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .padding(.horizontal, Theme.Spacing.sm)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity)
                .background(
                    Capsule()
                        .fill(isSelected
                              ? Color(Theme.Colors.primary)
                              : Color(Theme.Colors.surface))
                )
                .overlay(
                    Capsule()
                        .stroke(isSelected
                                ? Color.clear
                                : Color(Theme.Colors.border),
                                lineWidth: 1)
                )
                .foregroundStyle(isSelected
                                 ? Color.white
                                 : Color(Theme.Colors.textPrimary))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(stop.displayName) vibe")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

#Preview {
    StatefulPreviewWrapper(VibeStop.balanced) { binding in
        VStack(spacing: Theme.Spacing.lg) {
            VibeSelector(vibe: binding)
            Text("Current: \(binding.wrappedValue.displayName)")
        }
        .padding()
    }
}

/// Tiny helper so `#Preview` can host a stateful binding without
/// pulling in a heavyweight preview harness.
private struct StatefulPreviewWrapper<Value, Content: View>: View {
    @State private var value: Value
    private let content: (Binding<Value>) -> Content

    init(_ initial: Value, @ViewBuilder content: @escaping (Binding<Value>) -> Content) {
        self._value = State(initialValue: initial)
        self.content = content
    }

    var body: some View {
        content($value)
    }
}
