import SwiftUI

enum Theme {

    // MARK: - Colors (named assets in xcassets with light/dark variants)

    enum Colors {
        static let background = "Background"
        static let surface = "Surface"
        static let textPrimary = "TextPrimary"
        static let textSecondary = "TextSecondary"
        static let primary = "BrandPrimary"
        static let primaryLight = "PrimaryLight"
        static let primaryMuted = "PrimaryMuted"
        static let destructive = "Destructive"
        static let muted = "Muted"
        static let border = "Border"

        // Build 38 — Mono + Burgundy hero palette. The 100 sites that
        // read `primary` now resolve to burgundy (`#5C1A2A`). The
        // previous ink primary moves into `charcoal` for hierarchy
        // moments that aren't body text but also aren't brand-
        // accented. Gold + sage stay declared but de-featured:
        //
        //   • `charcoal` (#3A3A3A) — mid-tone for filter labels,
        //     non-primary nav icons, secondary headings. Reaches
        //     for it whenever ink-on-paper hierarchy is needed
        //     without recruiting the burgundy hero or the muted
        //     grey text-secondary.
        //   • `gold` — premium-accent role, RARE. Only seasonal
        //     editorial moments (year-in-review, anniversary). The
        //     burgundy now carries the "pop" the gold used to do.
        //   • `accentSage` — success / "fits your vibe" / capture-
        //     good frame. Mirrors the gold pattern: declared so the
        //     next UI surface that needs it can pull without an
        //     asset roundtrip.
        static let charcoal = "Charcoal"
        static let gold = "Gold"
        static let accentSage = "AccentSage"
    }

    // MARK: - Typography

    enum Fonts {
        static let display = Font.custom("CormorantGaramond-SemiBold", size: 34, relativeTo: .largeTitle)
        static let h1 = Font.custom("CormorantGaramond-SemiBold", size: 28, relativeTo: .title)
        static let h2 = Font.custom("CormorantGaramond-Medium", size: 22, relativeTo: .title2)
        static let h3 = Font.custom("CormorantGaramond-Medium", size: 18, relativeTo: .title3)
        // Build 21 — `.system(size:)` does NOT respect Dynamic Type.
        // Switching to `.system(_:weight:)` with semantic styles maps
        // our visual hierarchy to the iOS scale so users with Larger
        // Accessibility Sizes see proportionally bigger body / caption
        // text. The default body size at default Dynamic Type setting
        // is 17pt — close enough to our prior 16pt that no card layout
        // changes are needed.
        static let body = Font.system(.body, weight: .regular)
        static let bodySmall = Font.system(.subheadline, weight: .regular)
        static let caption = Font.system(.caption, weight: .regular)
        static let overline = Font.system(.caption2, weight: .medium)
    }

    // MARK: - Spacing (4pt base unit)

    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 16
        static let lg: CGFloat = 24
        static let xl: CGFloat = 32
        static let xxl: CGFloat = 48
    }

    // MARK: - Corner Radius

    enum Radius {
        static let card: CGFloat = 12
        static let button: CGFloat = 12
        static let chip: CGFloat = 20
        static let avatar: CGFloat = .infinity
    }

    // MARK: - Shadows

    enum Shadows {
        static func card() -> some ViewModifier {
            CardShadow()
        }
    }

    // MARK: - Animation

    enum Animation {
        static let standard = SwiftUI.Animation.easeOut(duration: 0.2)
        static let entrance = SwiftUI.Animation.easeOut(duration: 0.15)
        static let spring = SwiftUI.Animation.spring(response: 0.35, dampingFraction: 0.7)
    }
}

// MARK: - View Modifiers

private struct CardShadow: ViewModifier {
    func body(content: Content) -> some View {
        content
            .shadow(color: .black.opacity(0.06), radius: 4, x: 0, y: 2)
    }
}

extension View {
    func cardShadow() -> some View {
        modifier(CardShadow())
    }
}
