import Foundation
@testable import WardrobeReDo

/// Cross-suite serialization primitive for tests that mutate
/// `MLDiagnosticsStore.shared` (the singleton that holds smoke-test
/// status + inference records).
///
/// `@Suite(.serialized)` only serializes tests within a SINGLE suite.
/// `MultiGarmentSmokeTestTests` and `MLDiagnosticsStoreTests` both
/// reach into `MLDiagnosticsStore.shared` — Swift Testing runs them as
/// separate suites in parallel, so a `resetAll()` in one suite can
/// stomp a `setSmokeTestStatus(...)` in the other. The symptom is a
/// flaky "status is .notRun, expected .passed" failure whichever test
/// loses the race.
///
/// Mirrors `FeatureFlagTestIsolation`: actor-based async semaphore so
/// MainActor-isolated tests can hold it across `await` without pinning
/// the main-thread executor the way an `NSLock` would.
actor MLDiagnosticsTestIsolation {
    /// Shared global mutex — using a single instance is the point.
    /// Per-test instances would not serialize cross-suite.
    static let shared = MLDiagnosticsTestIsolation()

    private var isHeld = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Acquire exclusive access. Suspends until the current holder
    /// calls `release()`.
    func acquire() async {
        if !isHeld {
            isHeld = true
            return
        }
        await withCheckedContinuation { cont in
            waiters.append(cont)
        }
    }

    /// Release exclusive access. Hands the lock directly to the next
    /// waiter if any, preserving mutual exclusion without an
    /// unlock/relock round-trip.
    func release() {
        if waiters.isEmpty {
            isHeld = false
        } else {
            let next = waiters.removeFirst()
            next.resume()
        }
    }
}
