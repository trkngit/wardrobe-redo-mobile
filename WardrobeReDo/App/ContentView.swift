import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Group {
            if appState.isLoading {
                LaunchView()
            } else if appState.isAuthenticated {
                if appState.currentUser?.onboardingCompleted == false {
                    OnboardingView()
                } else {
                    TabRootView()
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
    var body: some View {
        ZStack {
            Color(Theme.Colors.background)
                .ignoresSafeArea()
            VStack(spacing: Theme.Spacing.md) {
                Text("Wardrobe")
                    .font(Theme.Fonts.display)
                    .foregroundStyle(Color(Theme.Colors.primary))
                ProgressView()
                    .tint(Color(Theme.Colors.primary))
            }
        }
    }
}

#Preview {
    ContentView()
        .environment(AppState())
}
