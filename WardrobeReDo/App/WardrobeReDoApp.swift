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

        // Wire the UploadQueue handler + replay any stale envelopes from
        // the previous session. Envelopes get here when `AddItemViewModel.save`
        // hit a retryable DB insert error after the repository's own
        // in-process retry budget ran out — the queue persists the
        // pending insert so a later drain (next foreground / cold
        // start) can replay it against Supabase. Safe to re-run on every
        // launch: `idempotencyKey` + the 23505 → fetch-by-key path in
        // `WardrobeRepository.insertItem` resolves duplicates cleanly.
        Task.detached(priority: .utility) {
            await UploadQueue.shared.setHandler { envelope in
                switch envelope.kind {
                case .wardrobeItem:
                    let decoded = try JSONDecoder().decode(NewWardrobeItem.self, from: envelope.payload)
                    _ = try await WardrobeRepository().insertItem(decoded)
                case .outfit:
                    // Not yet wired — outfit queue integration lands in a
                    // follow-up window. Throw a non-retryable error so the
                    // drain stops the cycle instead of churning on this
                    // kind forever; the envelope stays put for a future
                    // handler upgrade.
                    throw CancellationError()
                }
            }
            await UploadQueue.shared.drain()
        }

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
