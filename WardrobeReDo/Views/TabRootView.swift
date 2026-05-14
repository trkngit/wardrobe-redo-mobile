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
        // Build 19 — global offline banner. Reuses the StatusToast
        // pattern (a Capsule pinned to the bottom of the screen)
        // but with a warning icon instead of the checkmark, and
        // without auto-dismiss — the banner stays as long as the
        // monitor reports offline, then disappears on its own when
        // connectivity returns.
        .overlay(alignment: .bottom) {
            if !appState.networkMonitor.isOnline {
                offlineBanner
                    .padding(.bottom, Theme.Spacing.xxl + Theme.Spacing.lg)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.3), value: appState.networkMonitor.isOnline)
    }

    /// Build 19 — offline indicator. Reuses StatusToast's visual
    /// vocabulary (Capsule, surface fill, drop shadow) but skips
    /// the auto-dismiss task since "still offline" should remain
    /// visible until the network comes back.
    private var offlineBanner: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: "wifi.slash")
                .foregroundStyle(Color(Theme.Colors.destructive))
            Text("You're offline")
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
        .accessibilityLabel("Offline. Network connectivity unavailable.")
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
