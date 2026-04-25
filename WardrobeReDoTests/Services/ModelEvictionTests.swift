import CoreML
import Foundation
import Testing
import UIKit
@testable import WardrobeReDo

/// Coverage for the memory-warning eviction wired into all three
/// Core ML services (`MultiGarmentProposalService`, `SAM2Extractor`,
/// `AttributeClassifierService`).
///
/// What the contract guarantees:
///   1. The first call loads the model exactly once.
///   2. Subsequent calls without an evict don't re-load.
///   3. After `evictLoadedModel()`, the next call reloads — proving
///      that a `didReceiveMemoryWarningNotification` would free the
///      ~150 MB / ~30 MB / ~10 MB held by each model and the next
///      capture would pay a single load cost rather than die from a
///      watchdog termination.
///
/// We can't post a real `UIApplication.didReceiveMemoryWarningNotification`
/// in a unit test reliably (the observer is queue-bound and tests would
/// race on the timing). Instead we drive `evictLoadedModel()` directly
/// — it's the same code path the notification observer triggers.
///
/// Each service is exercised through its `prewarm()` API which only
/// calls `loadModelIfAvailable()` and returns. We can't return a real
/// `MLModel` from a test loader (the type is opaque), so we use a
/// loader that returns nil and assert the loader was *called* the
/// expected number of times. The contract that matters — "evict
/// re-arms the load attempt" — is provable from the call count alone.
@Suite("ModelEviction") struct ModelEvictionTests {

    // MARK: - MultiGarmentProposalService

    @Test func multiGarmentEvictResetsLoadAttempt() async {
        let counter = CallCounter()
        let service = MultiGarmentProposalService(
            modelLoader: {
                Task { await counter.increment() }
                return nil
            }
        )

        // First prewarm tries to load.
        await service.prewarm()
        // Second prewarm without an evict should NOT try again — the
        // first nil result armed `modelLoadAttempted`.
        await service.prewarm()

        // Wait for the loader's increment Task to drain.
        try? await Task.sleep(for: .milliseconds(50))
        let beforeEvict = await counter.value
        #expect(beforeEvict == 1, "loader should be called exactly once before evict")

        service.evictLoadedModel()

        // After eviction the next prewarm reattempts the load.
        await service.prewarm()
        try? await Task.sleep(for: .milliseconds(50))
        let afterEvict = await counter.value
        #expect(afterEvict == 2, "evict should re-arm the load attempt")
    }

    // MARK: - SAM2Extractor

    @Test func sam2EvictResetsLoadAttempt() async {
        let counter = CallCounter()
        let extractor = SAM2Extractor(
            modelLoader: {
                Task { await counter.increment() }
                return nil
            }
        )

        await extractor.prewarm()
        await extractor.prewarm()
        try? await Task.sleep(for: .milliseconds(50))
        let beforeEvict = await counter.value
        #expect(beforeEvict == 1)

        extractor.evictLoadedModel()
        await extractor.prewarm()
        try? await Task.sleep(for: .milliseconds(50))
        let afterEvict = await counter.value
        #expect(afterEvict == 2)
    }

    // MARK: - AttributeClassifierService

    @Test func attributeClassifierEvictResetsLoadAttempt() async {
        let counter = CallCounter()
        let service = AttributeClassifierService(
            modelLoader: {
                Task { await counter.increment() }
                return nil
            }
        )

        await service.prewarm()
        await service.prewarm()
        try? await Task.sleep(for: .milliseconds(50))
        let beforeEvict = await counter.value
        #expect(beforeEvict == 1)

        service.evictLoadedModel()
        await service.prewarm()
        try? await Task.sleep(for: .milliseconds(50))
        let afterEvict = await counter.value
        #expect(afterEvict == 2)
    }

    // MARK: - Helpers

    /// Actor-isolated counter so the loader closures (which run on
    /// arbitrary queues from `loadModelIfAvailable`) can record calls
    /// safely.
    private actor CallCounter {
        private(set) var value = 0
        func increment() { value += 1 }
    }
}
