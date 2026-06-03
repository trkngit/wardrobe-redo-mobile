import SwiftUI

/// The app's single chip / pill control. Build 51 unified five drifting
/// chip styles (the wardrobe + match category filters, the outfits +
/// match occasion pickers, the Add/Edit attribute chips, the profile
/// toggles, the onboarding chips) into this one component so the button
/// language is consistent everywhere.
///
/// Styling follows `DESIGN.md` ("Tags/Chips — rounded pill, Primary
/// Muted background, Primary text"), adjusted for dark-mode contrast:
///   • **Selected** — solid burgundy (`primary`) fill + white text.
///   • **Unselected** — the soft burgundy `primaryMuted` wash + high-
///     contrast `textPrimary` text + a 1pt `border` edge.
///
/// Literal "burgundy text on a burgundy wash" fails WCAG contrast in dark
/// mode (~2.2:1), so the FILL carries the brand tint while the TEXT stays
/// high-contrast. The 1pt border (raised to ~3:1 vs the background in
/// Build 51) is what makes an unselected chip read as a tappable pill
/// instead of blending into the dark background — the reported problem.
///
/// Lay chips out in a `FlowLayout` so each keeps its intrinsic width and
/// wraps naturally; never put them in an equal-width grid (that leaves
/// ragged gaps between short and long labels).
struct Chip: View {
    private let label: LocalizedStringResource
    private let icon: String?
    private let isSelected: Bool
    private let action: () -> Void

    init(
        _ label: LocalizedStringResource,
        icon: String? = nil,
        isSelected: Bool,
        action: @escaping () -> Void
    ) {
        self.label = label
        self.icon = icon
        self.isSelected = isSelected
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.xs) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 12))
                }
                Text(label)
                    .font(Theme.Fonts.caption)
            }
            .foregroundStyle(isSelected ? Color.white : Color(Theme.Colors.textPrimary))
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.sm)
            .background(
                Capsule()
                    .fill(isSelected
                          ? Color(Theme.Colors.primary)
                          : Color(Theme.Colors.primaryMuted))
            )
            .overlay(
                Capsule()
                    .stroke(isSelected ? Color.clear : Color(Theme.Colors.border), lineWidth: 1)
            )
        }
        .buttonStyle(.pressScale)
        .animation(Theme.Animation.standard, value: isSelected)
        // VoiceOver: the Button already reads the label + "button"; add
        // the selected trait so it announces "selected" on the active
        // chip, matching the gold/burgundy visual cue.
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
