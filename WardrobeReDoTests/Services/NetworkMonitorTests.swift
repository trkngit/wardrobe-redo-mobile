import Foundation
import Testing
@testable import WardrobeReDo

// MARK: - NetworkMonitor (build 19)
//
// `NetworkMonitor` wraps Apple's `NWPathMonitor` and exposes a
// debounced `isOnline` flag via Observation. Testing the live
// path-monitor would require manipulating the simulator's network
// stack, which Swift Testing can't do directly. Instead these tests
// pin down the contract the rest of the app relies on:
//
//   1. Default is online (true) — the launch state never briefly
//      flashes the offline banner before the first path update.
//   2. The monitor itself is constructible without crashing —
//      this is a smoke test that `init()` doesn't blow up on the
//      simulator (where `NWPathMonitor` is sometimes flaky).
//
// Wider behavioral tests (debounce timing, Wi-Fi handoff flapping)
// would need a `NetworkMonitor` protocol + a fake implementation;
// that refactor is deferred to a build where we actually want to
// drive offline UX from tests, not just verify the monitor doesn't
// crash on init.

@Test @MainActor
func networkMonitorDefaultsToOnline() {
    // Optimistic default — the banner shouldn't flash on every
    // launch before NWPathMonitor's first callback fires.
    let monitor = NetworkMonitor()
    #expect(monitor.isOnline == true)
}

@Test @MainActor
func networkMonitorInitDoesNotCrash() {
    // Smoke test: construct + tear down without exceptions or
    // SIGABRT. The deinit cancels the underlying NWPathMonitor;
    // if that path has a use-after-free we'd see it here.
    _ = NetworkMonitor()
}
