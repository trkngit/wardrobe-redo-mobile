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
    }

    // MARK: - Typography

    enum Fonts {
        static let display = Font.custom("CormorantGaramond-SemiBold", size: 34, relativeTo: .largeTitle)
        static let h1 = Font.custom("CormorantGaramond-SemiBold", size: 28, relativeTo: .title)
        static let h2 = Font.custom("CormorantGaramond-Medium", size: 22, relativeTo: .title2)
        static let h3 = Font.custom("CormorantGaramond-Medium", size: 18, relativeTo: .title3)
        static let body = Font.system(size: 16, weight: .regular)
        static let bodySmall = Font.system(size: 14, weight: .regular)
        static let caption = Font.system(size: 12, weight: .regular)
        static let overline = Font.system(size: 11, weight: .medium)
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
