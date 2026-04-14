import SwiftUI
import Supabase

@main
struct WardrobeReDoApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
        }
    }
}
