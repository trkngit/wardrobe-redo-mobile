import SwiftUI
import Supabase

@main
struct WardrobeReDoApp: App {
    @State private var appState = AppState()

    init() {
        // Crash reporting first — catches any init-time crashes below.
        // No-op if SENTRY_DSN is not in Secrets.plist.
        SentryService.configure()
        ImageCacheService.configure()
        #if DEBUG
        // Off-main smoke test for multi-garment inference. Runs once at
        // launch so a broken Core ML model / corrupt Background Assets
        // payload is caught before a user taps the shutter. DEBUG-only
        // so production users never pay this cost.
        Task.detached(priority: .utility) {
            await MultiGarmentSmokeTest.run()
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
        }
    }
}
