import Foundation

/// Build 22 — shared helper for the "do this with a timeout" pattern.
///
/// Three sites in the codebase implement the same `withTaskGroup`
/// race against `Task.sleep`:
///
///   • `AppState.fetchSessionUserId()` — 5 s timeout
///   • `AppState.loadProfile(userId:)` — 10 s timeout
///   • `OutfitViewModel.runGeneration(…)` — 60 s timeout
///
/// Each duplicated the same boilerplate (add operation task, add
/// sleep task, race via `group.next()`, cancel all, return). Each
/// also independently re-discovered the defensive `?? nil` coalesce
/// after Build 19's crash audit found a force-unwrap in the
/// original implementations.
///
/// This helper centralizes the pattern so future "operation with
/// timeout" sites can call one function instead of reimplementing
/// the race + cancellation contract. Pure utility; no app state,
/// no dependencies beyond Swift Concurrency.
///
/// **Returns** `nil` if the timeout fires first OR if `operation`
/// returns nil. Callers that need to distinguish those two cases
/// should encode the success/failure into the result type
/// themselves (e.g. `Result<T, Error>`).
///
/// **Cancellation** is automatic: when `next()` returns the first
/// result, `cancelAll()` ensures the other task doesn't leak a
/// hanging awaiter.
enum TimeoutRace {
    /// Runs `operation` with a `timeout` deadline. Returns whichever
    /// finishes first — the operation's result, or `nil` for the
    /// timeout. Defaults match the most common observation: most
    /// timed operations want `nil` on timeout, not an error throw.
    static func runWithTimeout<T: Sendable>(
        timeout: Duration,
        operation: @escaping @Sendable () async -> T?
    ) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            // Build 19 — defensive `?? nil`. `group.next()`
            // theoretically returns nil only when the group is
            // empty, which can't happen here, but Swift's
            // structured-concurrency contract doesn't make that
            // a hard guarantee — we take the safe coalesce.
            let result = (await group.next()) ?? nil
            group.cancelAll()
            return result
        }
    }
}
