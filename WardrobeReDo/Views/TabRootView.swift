import SwiftUI

struct TabRootView: View {
    // Build 8 — selection lifted to AppState so failure CTAs in
    // other tabs can deep-link by setting `appState.selectedTab`.
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState
        TabView(selection: $appState.selectedTab) {
            NavigationStack {
                WardrobeGridView()
            }
            .tabItem {
                Label("Wardrobe", systemImage: "tshirt")
            }
            .tag(0)

            NavigationStack {
                DailyOutfitsView()
            }
            .tabItem {
                Label("Outfits", systemImage: "sparkles")
            }
            .tag(1)

            NavigationStack {
                MatchingView()
            }
            .tabItem {
                Label("Match", systemImage: "arrow.triangle.branch")
            }
            .tag(2)

            NavigationStack {
                ProfileView()
            }
            .tabItem {
                Label("Profile", systemImage: "person")
            }
            .tag(3)
        }
        .tint(Color(Theme.Colors.primary))
    }
}

// MARK: - Placeholder views (replaced in later sprints)

private struct PlaceholderScreen: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: Theme.Spacing.md) {
            Text(title)
                .font(Theme.Fonts.h1)
                .foregroundStyle(Color(Theme.Colors.textPrimary))
            Text(subtitle)
                .font(Theme.Fonts.body)
                .foregroundStyle(Color(Theme.Colors.textSecondary))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(Theme.Colors.background))
    }
}

#Preview {
    TabRootView()
}
