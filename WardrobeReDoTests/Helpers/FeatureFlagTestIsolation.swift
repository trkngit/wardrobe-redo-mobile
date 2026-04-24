import Foundation
@testable import WardrobeReDo

/// Cross-suite serialization primitive for tests that mutate
/// `FeatureFlags.isMultiGarmentEnabled` (or any other
/// `UserDefaults.standard`-backed flag).
///
/// `@Suite(.serialized)` only serializes tests within a SINGLE suite.
/// Swift Testing runs DIFFERENT suites in parallel by default, so a
/// `FeatureFlags.resetAll()` in one suite can race a `= true` setter in
/// another and flip the flag out from under an in-flight test body.
/// The symptom is flaky "flag is on but routing took the off branch"
/// failures in whichever test loses the race.
///
/// An `NSLock` would deadlock here: flag-touching tests are
/// `@MainActor`-isolated, and many of them `await` (e.g.
/// `onCameraPhotoCaptured`) inside their critical section. Holding a
/// thread-blocking lock across an await on the main actor pins the
/// main-thread executor — any other MainActor-isolated task that tries
/// to acquire the same lock freezes the whole test run.
///
/// This actor-based async semaphore is await-safe: acquire suspends
/// instead of blocking, so the MainActor executor is free to run the
/// holding task's continuation. Callers pair `acquire()` with a
/// `release()` scheduled from `defer`.
actor FeatureFlagTestIsolation {
    /// Shared global mutex for every flag-touching test. Using a single
    /// instance is the whole point — per-test instances wouldn't
    /// serialize cross-suite.
    static let shared = FeatureFlagTestIsolation()

    private var isHeld = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Acquire exclusive access. Suspends (not blocks) until the
    /// current holder calls `release()`.
    func acquire() async {
        if !isHeld {
            isHeld = true
            return
        }
        await withCheckedContinuation { cont in
            waiters.append(cont)
        }
        // When resumed from a waiter queue we already own the lock —
        // the previous holder's `release()` handed it directly to us.
    }

    /// Release exclusive access. If other tests are queued, hands the
    /// lock directly to the next waiter without lowering `isHeld`,
    /// preserving mutual exclusion without a spurious unlock/relock
    /// round-trip.
    func release() {
        if waiters.isEmpty {
            isHeld = false
        } else {
            let next = waiters.removeFirst()
            next.resume()
        }
    }
}
