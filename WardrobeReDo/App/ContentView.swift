import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Group {
            if appState.isLoading {
                LaunchView()
            } else if appState.isAuthenticated {
                if let user = appState.currentUser {
                    if user.onboardingCompleted {
                        TabRootView()
                    } else {
                        OnboardingView()
                    }
                } else {
                    // Authenticated but profile not loaded — show retry when failed
                    LaunchView(showRetry: appState.profileLoadFailed) {
                        Task { await appState.refreshProfile() }
                    }
                    .task { await appState.refreshProfile() }
                }
            } else {
                LoginView()
            }
        }
        .animation(.easeOut(duration: 0.2), value: appState.isAuthenticated)
        .animation(.easeOut(duration: 0.2), value: appState.isLoading)
        .task {
            await appState.initialize()
        }
        .task {
            await appState.handleAuthChange()
        }
    }
}

private struct LaunchView: View {
    var showRetry = false
    var onRetry: (() -> Void)?

    var body: some View {
        ZStack {
            Color(Theme.Colors.background)
                .ignoresSafeArea()
            VStack(spacing: Theme.Spacing.md) {
                Text("Wardrobe")
                    .font(Theme.Fonts.display)
                    .foregroundStyle(Color(Theme.Colors.primary))

                if showRetry {
                    Text("Unable to load your profile")
                        .font(Theme.Fonts.bodySmall)
                        .foregroundStyle(Color(Theme.Colors.textSecondary))
                    GhostButton("Try Again") {
                        onRetry?()
                    }
                    .frame(width: 160)
                } else {
                    ProgressView()
                        .tint(Color(Theme.Colors.primary))
                }
            }
        }
    }
}

#Preview {
    ContentView()
        .environment(AppState())
}
