import Foundation

/// Retry policy for async network / persistence operations.
///
/// Use case: any Supabase call, Storage upload, or other transient-failure-
/// prone operation. Wrap with `withRetry(_:_)` to get exponential backoff
/// with jitter and automatic retry-classification.
///
/// Not for idempotency — use `idempotencyKey` on the payload for that
/// (see migration 00010). Retries without idempotency keys can double-
/// insert on network-partition timeouts.
public struct RetryPolicy: Sendable {
    /// Maximum number of attempts including the initial call (so
    /// `maxAttempts=3` = 1 initial try + 2 retries).
    public let maxAttempts: Int

    /// Base delay before the first retry. Doubles each subsequent retry
    /// up to `maxDelay`.
    public let initialDelay: Duration

    /// Upper bound on any individual delay. Prevents runaway backoff
    /// on very unreliable networks.
    public let maxDelay: Duration

    /// Jitter fraction (0…1). `0.2` means each delay is sampled uniformly
    /// in `[base * 0.8, base * 1.2]`. Prevents thundering herd when many
    /// clients retry at once.
    public let jitter: Double

    public init(maxAttempts: Int, initialDelay: Duration, maxDelay: Duration, jitter: Double) {
        precondition(maxAttempts >= 1, "maxAttempts must be >= 1")
        precondition(jitter >= 0 && jitter <= 1, "jitter must be in [0,1]")
        self.maxAttempts = maxAttempts
        self.initialDelay = initialDelay
        self.maxDelay = maxDelay
        self.jitter = jitter
    }

    /// Standard policy for most Supabase calls: 3 attempts, 0.5s → 1s → 2s
    /// (clamped at 5s), 20 % jitter.
    public static let `default` = RetryPolicy(
        maxAttempts: 3,
        initialDelay: .milliseconds(500),
        maxDelay: .seconds(5),
        jitter: 0.2
    )

    /// Tight policy for user-initiated saves where we don't want to
    /// hold the UI hostage. 2 attempts, 250ms gap.
    public static let interactive = RetryPolicy(
        maxAttempts: 2,
        initialDelay: .milliseconds(250),
        maxDelay: .milliseconds(250),
        jitter: 0.1
    )

    /// Aggressive policy for background upload queue draining. Six
    /// attempts over ~1 minute — enough to ride out a short network
    /// blip, bounded so a hard failure surfaces for user feedback.
    public static let background = RetryPolicy(
        maxAttempts: 6,
        initialDelay: .seconds(1),
        maxDelay: .seconds(30),
        jitter: 0.3
    )
}

/// Classify whether an error is worth retrying. Network transients and
/// 5xx server errors are retryable; auth failures, 4xx client errors,
/// and cancellations are not.
public func isRetryableError(_ error: Error) -> Bool {
    if error is CancellationError { return false }

    if let urlError = error as? URLError {
        switch urlError.code {
        case .notConnectedToInternet, .networkConnectionLost, .timedOut,
             .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
             .resourceUnavailable, .internationalRoamingOff,
             .dataNotAllowed, .secureConnectionFailed:
            return true
        default:
            return false
        }
    }

    // Supabase / PostgREST errors expose `statusCode` via localized
    // description. We can't switch on it strictly typed without
    // depending on PostgREST module here, so we string-match common
    // server-side signals as a best-effort.
    let desc = String(describing: error).lowercased()
    if desc.contains("502") || desc.contains("503") || desc.contains("504") ||
       desc.contains("timeout") || desc.contains("connection reset") {
        return true
    }

    return false
}

/// Run `op` under `policy`, retrying retryable failures with exponential
/// backoff and jitter. Non-retryable errors are re-thrown immediately.
/// Respects task cancellation between attempts.
///
/// The operation is `@Sendable` because `withRetry` is nonisolated and
/// the closure is stored/called across iterations. Callers inside
/// `@MainActor`-isolated types satisfy this automatically — MainActor
/// isolation provides the exclusivity Sendable requires.
public func withRetry<T: Sendable>(
    _ policy: RetryPolicy = .default,
    operation: @Sendable () async throws -> T
) async throws -> T {
    var currentDelay = policy.initialDelay
    var lastError: Error?

    for attempt in 1...policy.maxAttempts {
        do {
            try Task.checkCancellation()
            return try await operation()
        } catch {
            lastError = error
            if attempt == policy.maxAttempts { throw error }
            guard isRetryableError(error) else { throw error }

            let jittered = jitteredDelay(currentDelay, jitter: policy.jitter)
            try await Task.sleep(for: jittered)

            // Double the base delay for next iteration, clamped at maxDelay.
            let doubled = currentDelay + currentDelay
            currentDelay = min(doubled, policy.maxDelay)
        }
    }

    // Unreachable — the loop either returns or throws — but the compiler
    // can't prove it. Throw the last captured error rather than fatalError
    // so production never crashes on an impossible path.
    throw lastError ?? CancellationError()
}

/// Apply `±jitter` fraction to `base` and return the result. Extracted
/// to a free function for unit-test determinism.
func jitteredDelay(_ base: Duration, jitter: Double) -> Duration {
    guard jitter > 0 else { return base }
    let nanos = base.components.seconds * 1_000_000_000 + base.components.attoseconds / 1_000_000_000
    let spread = Double(nanos) * jitter
    let offset = Double.random(in: -spread...spread)
    let jitteredNanos = max(0, Int64(Double(nanos) + offset))
    return .nanoseconds(jitteredNanos)
}
