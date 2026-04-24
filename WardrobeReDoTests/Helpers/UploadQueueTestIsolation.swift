import Foundation
@testable import WardrobeReDo

/// Cross-suite serialization primitive for tests that mutate the
/// `UploadQueue.shared` actor — its pending list, its installed handler,
/// and its on-disk `Library/Caches/upload-queue.json`.
///
/// `@Suite(.serialized)` only serializes tests *within* one suite. Swift
/// Testing happily runs `UploadQueueTests` in parallel with
/// `AddItemViewModelUploadQueueTests` because they live in different
/// suites, so one suite's `setHandler` / `clear` can race the other's
/// `enqueue` / `drain` and produce false-positive "the envelope is gone"
/// or "the handler threw something I didn't install" failures. The
/// symptom we actually hit on CI run 24908100779: `pendingCount() == 2`
/// failing because a sibling suite's drain cycle consumed the envelopes
/// mid-assertion.
///
/// This actor-based async semaphore mirrors `FeatureFlagTestIsolation`
/// exactly — acquire suspends (not blocks) until the current holder
/// releases, so MainActor-isolated tests that `await` inside their
/// critical section don't deadlock. Callers pair `acquire()` with a
/// `release()` scheduled from `defer`.
actor UploadQueueTestIsolation {
    /// Shared global mutex for every UploadQueue-touching test. Using a
    /// single instance is the whole point — per-test instances wouldn't
    /// serialize cross-suite.
    static let shared = UploadQueueTestIsolation()

    private var isHeld = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Acquire exclusive access. Suspends (not blocks) until the current
    /// holder calls `release()`.
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
