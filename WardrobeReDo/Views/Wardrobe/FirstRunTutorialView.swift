import SwiftUI

/// Three-slide pager shown the first time the user reaches the photo
/// capture step. Explains what a "good" photo looks like, what to do
/// with a bad background, and previews the tap-to-select surface that
/// every capture lands on after processing. Dismissal persists through
/// `FirstRunTutorialView.hasSeenKey` so the pager shows at most once.
struct FirstRunTutorialView: View {

    /// UserDefaults key for the "user dismissed the tutorial" flag.
    /// Exposed as a static so callers can reset it from a Debug menu
    /// without duplicating the literal.
    static let hasSeenKey = "wardrobe.captureTutorial.seen"

    var onDismiss: () -> Void

    @State private var selection: Int = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TabView(selection: $selection) {
                    ForEach(Array(slides.enumerated()), id: \.offset) { index, slide in
                        slideView(slide)
                            .tag(index)
                            .padding(.horizontal, Theme.Spacing.lg)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                .indexViewStyle(.page(backgroundDisplayMode: .always))

                primaryButton
                    .padding(.horizontal, Theme.Spacing.lg)
                    .padding(.bottom, Theme.Spacing.lg)
            }
            .background(Color(Theme.Colors.background).ignoresSafeArea())
            .navigationTitle("Getting started")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Skip", action: dismiss)
                }
            }
        }
    }

    // MARK: - Slides

    private struct Slide {
        let systemImage: String
        let tint: Color
        let title: String
        let body: String
    }

    private let slides: [Slide] = [
        Slide(
            systemImage: "photo.on.rectangle.angled",
            tint: .green,
            title: "Plain background",
            body: "Photograph each item against a wall, bed sheet, or floor without patterns. The cleaner the background, the more accurate the color palette."
        ),
        Slide(
            systemImage: "wand.and.stars",
            tint: Color(Theme.Colors.primary),
            title: "Cluttered? We'll try to help.",
            body: "If a clean background isn't possible, capture anyway. Wardrobe auto-crops the clothing — preview it on the next screen and tap to refine if needed."
        ),
        Slide(
            systemImage: "hand.tap.fill",
            tint: .orange,
            title: "Review before saving.",
            body: "For a single item, tap to refine the crop. If you're wearing multiple pieces — jacket, shirt, skirt — we detect each one and you pick which to save. Uncheck anything you don't want, then Save."
        ),
    ]

    private func slideView(_ slide: Slide) -> some View {
        VStack(spacing: Theme.Spacing.lg) {
            Image(systemName: slide.systemImage)
                .font(.system(size: 96, weight: .light))
                .foregroundStyle(slide.tint)
                .padding(.top, Theme.Spacing.xl)

            VStack(spacing: Theme.Spacing.sm) {
                Text(slide.title)
                    .font(Theme.Fonts.h2)
                    .foregroundStyle(Color(Theme.Colors.textPrimary))
                    .multilineTextAlignment(.center)

                Text(slide.body)
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Color(Theme.Colors.textSecondary))
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, Theme.Spacing.md)

            Spacer(minLength: Theme.Spacing.xl)
        }
    }

    // MARK: - Primary button

    private var primaryButton: some View {
        let isLast = selection == slides.count - 1
        return GoldButton(isLast ? "Got it" : "Next") {
            if isLast { dismiss() }
            else { withAnimation { selection += 1 } }
        }
    }

    // MARK: - Helpers

    private func dismiss() {
        UserDefaults.standard.set(true, forKey: Self.hasSeenKey)
        onDismiss()
    }
}

extension FirstRunTutorialView {
    /// True when the user has already dismissed the tutorial at least once.
    static var hasBeenSeen: Bool {
        UserDefaults.standard.bool(forKey: hasSeenKey)
    }
}

#Preview {
    FirstRunTutorialView(onDismiss: {})
}
