import Foundation
import Testing
@testable import WardrobeReDo

/// Coverage for the processing timeout in
/// `AddItemViewModel.processWithTimeout`.
///
/// The full timeout race is integration-flavoured (requires a hung
/// `ImageService.processImage` call that exceeds the budget). We pin
/// the public surface here:
///   1. Default timeout constant — bumping it requires deliberate
///      test review, not an accidental drift.
///   2. The `PhotoProcessingOutcome` enum has the two cases the
///      caller branches on.
///
/// End-to-end timeout behaviour (Vision/SAM2 hang → user-visible
/// error → return to photo step) is exercised by the existing
/// `applyProcessedFromLibrary` nil-fallback tests, which take the
/// same code path the timeout case routes through.
@MainActor
@Suite("AddItemViewModel.processingTimeout") struct AddItemViewModelProcessingTimeoutTests {

    @Test func defaultTimeoutIsThirtySeconds() {
        // Pin the default — bumping it should be a deliberate UX
        // decision, not silent drift. The 30s budget is comfortably
        // past the 99th percentile success path on real devices and
        // well under the iOS watchdog ceiling.
        #expect(AddItemViewModel.photoProcessingTimeoutSeconds == 30)
    }

    @Test @MainActor func outcomeEnumHasCompletedCase() {
        // Smoke check that the public PhotoProcessingOutcome enum
        // exposes the cases the caller branches on. If a refactor
        // collapses the timeout into a Bool or removes the enum
        // entirely, this fails-fast.
        let processed: ProcessedImage? = nil
        let completed: AddItemViewModel.PhotoProcessingOutcome = .completed(processed)
        let timedOut: AddItemViewModel.PhotoProcessingOutcome = .timedOut

        switch completed {
        case .completed: break
        case .timedOut: Issue.record("expected .completed, got .timedOut")
        }
        switch timedOut {
        case .completed: Issue.record("expected .timedOut, got .completed")
        case .timedOut: break
        }
    }
}
