import Foundation
import Network
import Observation

/// Build 19 — reachability state machine for the app.
///
/// Wraps `NWPathMonitor` (Apple's official reachability API since
/// iOS 12) in an `@Observable` so SwiftUI views and view models can
/// react to online/offline transitions without polling or callback
/// soup. One shared instance lives on `AppState` so every consumer
/// reads the same state.
///
/// Why this exists: the parallel codebase audit flagged "hanging
/// requests when offline" as a high-severity reliability gap.
/// Several repositories make Supabase calls that block indefinitely
/// (or fail with a confusing timeout message) when the device has
/// no connectivity. With a monitor the app can:
///
///   1. Show a clear "You're offline" banner instead of a hanging
///      spinner.
///   2. Short-circuit the generation / regen flows when offline so
///      the user doesn't burn 60 s waiting for a timeout.
///   3. Auto-retry once the path returns to `.satisfied` (future).
///
/// Debounce: the monitor fires `.satisfied` and `.unsatisfied`
/// callbacks on every interface change, which on Wi-Fi can flap
/// for a few hundred ms during reconnect. We debounce 1 s before
/// flipping the published state so the banner doesn't strobe
/// during normal Wi-Fi handoffs.
@MainActor
@Observable
final class NetworkMonitor {

    /// True when the device has at least one viable network interface
    /// reporting `status == .satisfied`. Default is `true` — we
    /// optimistically assume online so the UI doesn't briefly flash
    /// the offline banner during launch before NWPathMonitor's first
    /// callback fires.
    private(set) var isOnline: Bool = true

    /// Underlying Apple monitor. Held strongly so it doesn't get
    /// collected mid-session.
    private let monitor: NWPathMonitor
    private let queue: DispatchQueue

    /// Debounce window for online/offline transitions. 1 s matches
    /// iOS's own Wi-Fi reconnect cadence — short enough to feel
    /// responsive, long enough to ride out a single dropped frame.
    private static let debounce: Duration = .seconds(1)

    /// In-flight debounce task. Cancelled when a new path update
    /// arrives so rapid flapping collapses to the final state.
    private var debounceTask: Task<Void, Never>?

    init() {
        self.monitor = NWPathMonitor()
        self.queue = DispatchQueue(label: "com.wardroberedo.networkmonitor", qos: .utility)
        startMonitoring()
    }

    deinit {
        monitor.cancel()
    }

    private func startMonitoring() {
        monitor.pathUpdateHandler = { [weak self] path in
            // Hop to MainActor because we're publishing observable
            // state. The handler is invoked on `queue` which is a
            // background DispatchQueue.
            Task { @MainActor [weak self] in
                self?.handlePathUpdate(path)
            }
        }
        monitor.start(queue: queue)
    }

    /// Re-arm the debounce on every update. If the path is still
    /// `.satisfied` after the debounce window we publish online;
    /// otherwise offline. Effectively: a transient drop that
    /// recovers within 1 s never shows a banner.
    private func handlePathUpdate(_ path: NWPath) {
        let newIsOnline = path.status == .satisfied
        // No-op if the state hasn't actually flipped from what we
        // already published. Avoids re-publishing on every Wi-Fi
        // interface scan that NWPathMonitor surfaces.
        guard newIsOnline != isOnline else { return }

        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                self?.isOnline = newIsOnline
            }
        }
    }
}
