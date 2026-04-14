import SwiftUI

struct TabRootView: View {
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
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
                MatchingPlaceholderView()
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

private struct MatchingPlaceholderView: View {
    var body: some View {
        PlaceholderScreen(title: "What Goes With This?", subtitle: "Select an item to find matches")
            .navigationTitle("Match")
    }
}

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
