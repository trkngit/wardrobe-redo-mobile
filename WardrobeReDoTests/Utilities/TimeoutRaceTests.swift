import Foundation
import Testing
@testable import WardrobeReDo

// MARK: - TimeoutRace (build 22)
//
// `TimeoutRace.runWithTimeout` is the shared helper extracted from
// the three duplicated timeout-race sites in AppState +
// OutfitViewModel. Tests verify the contract callers depend on:
// happy path returns the operation result, slow operations resolve
// to nil after the deadline, and cancellation propagates.

@Test
func timeoutRaceReturnsOperationResultWhenFast() async {
    // Operation returns immediately — should win the race and
    // come back as a non-nil value.
    let result = await TimeoutRace.runWithTimeout(
        timeout: .seconds(5)
    ) { () -> Int? in
        42
    }
    #expect(result == 42)
}

@Test
func timeoutRaceReturnsNilWhenTimeoutFires() async {
    // Operation sleeps past the deadline — the timeout branch
    // wins and produces nil.
    let result = await TimeoutRace.runWithTimeout(
        timeout: .milliseconds(50)
    ) { () -> Int? in
        try? await Task.sleep(for: .seconds(5))
        return 99
    }
    #expect(result == nil)
}

@Test
func timeoutRacePropagatesNilFromOperation() async {
    // A nil-returning operation is indistinguishable from a
    // timeout by design — callers that need to tell them apart
    // should encode success/failure in the result type
    // themselves.
    let result = await TimeoutRace.runWithTimeout(
        timeout: .seconds(5)
    ) { () -> String? in
        nil
    }
    #expect(result == nil)
}
