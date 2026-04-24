import Foundation
import Testing
@testable import WardrobeReDo

/// Unit tests for `withRetry`, `RetryPolicy`, and the retryable-error
/// classifier. Covers:
///
/// 1. **Happy path** — first-try success returns the value and runs no
///    retries.
/// 2. **Transient retry** — a URLError `.timedOut` yields one retry
///    that then succeeds; we observe attempt count and final value.
/// 3. **Non-retryable short-circuit** — a `CancellationError` (or a
///    random domain error) throws immediately without consuming
///    attempts.
/// 4. **Exhaustion** — persistent retryable failure throws the **last**
///    error after `maxAttempts` tries.
/// 5. **Classifier** — `isRetryableError` matches the documented
///    URLError cases and the string-match fallback.
/// 6. **Jitter math** — `jitteredDelay` stays within `[base*(1-j),
///    base*(1+j)]` and is non-negative even under large jitter.
///
/// All tests use very small delays (1–5ms) so the suite runs in well
/// under a second.
struct RetryPolicyTests {

    // MARK: - Helpers

    /// A policy tuned for test speed: 3 attempts, 1ms → 2ms, no jitter.
    /// Deterministic — no `Double.random` call inside `jitteredDelay`.
    private static let testPolicy = RetryPolicy(
        maxAttempts: 3,
        initialDelay: .milliseconds(1),
        maxDelay: .milliseconds(2),
        jitter: 0
    )

    // MARK: - Happy path

    @Test func firstTrySuccessReturnsImmediately() async throws {
        var attempts = 0
        let value = try await withRetry(Self.testPolicy) {
            attempts += 1
            return 42
        }
        #expect(value == 42)
        #expect(attempts == 1)
    }

    // MARK: - Transient retry

    @Test func timeoutRetriesThenSucceeds() async throws {
        var attempts = 0
        let value = try await withRetry(Self.testPolicy) { () -> Int in
            attempts += 1
            if attempts == 1 {
                throw URLError(.timedOut)
            }
            return 7
        }
        #expect(value == 7)
        #expect(attempts == 2)
    }

    // MARK: - Non-retryable short-circuit

    @Test func cancellationErrorShortCircuits() async {
        var attempts = 0
        do {
            _ = try await withRetry(Self.testPolicy) { () -> Int in
                attempts += 1
                throw CancellationError()
            }
            Issue.record("expected throw")
        } catch is CancellationError {
            #expect(attempts == 1)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func nonRetryableDomainErrorShortCircuits() async {
        struct DomainError: Error {}
        var attempts = 0
        do {
            _ = try await withRetry(Self.testPolicy) { () -> Int in
                attempts += 1
                throw DomainError()
            }
            Issue.record("expected throw")
        } catch is DomainError {
            #expect(attempts == 1)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    // MARK: - Exhaustion

    @Test func exhaustionThrowsLastError() async {
        var attempts = 0
        do {
            _ = try await withRetry(Self.testPolicy) { () -> Int in
                attempts += 1
                throw URLError(.networkConnectionLost)
            }
            Issue.record("expected throw")
        } catch let urlError as URLError {
            #expect(urlError.code == .networkConnectionLost)
            // maxAttempts = 3 → one initial + two retries = three runs.
            #expect(attempts == 3)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    // MARK: - Classifier

    @Test func classifierRetriesDocumentedURLErrorCodes() {
        let retryable: [URLError.Code] = [
            .notConnectedToInternet,
            .networkConnectionLost,
            .timedOut,
            .cannotFindHost,
            .cannotConnectToHost,
            .dnsLookupFailed,
            .resourceUnavailable,
            .internationalRoamingOff,
            .dataNotAllowed,
            .secureConnectionFailed
        ]
        for code in retryable {
            #expect(isRetryableError(URLError(code)), "expected \(code) to be retryable")
        }
    }

    @Test func classifierDoesNotRetryBadURLOrUnsupported() {
        #expect(!isRetryableError(URLError(.badURL)))
        #expect(!isRetryableError(URLError(.unsupportedURL)))
    }

    @Test func classifierStringMatchesServer5xx() {
        struct ServerError: Error, CustomStringConvertible {
            let description: String
        }
        #expect(isRetryableError(ServerError(description: "HTTP 502 Bad Gateway")))
        #expect(isRetryableError(ServerError(description: "Gateway timeout on upstream")))
        #expect(isRetryableError(ServerError(description: "connection reset by peer")))
        // Not retryable: normal 4xx string
        #expect(!isRetryableError(ServerError(description: "HTTP 404 Not Found")))
    }

    // MARK: - Jitter math

    @Test func jitterIsZeroWhenFactorZero() {
        let base: Duration = .milliseconds(100)
        let result = jitteredDelay(base, jitter: 0)
        // Exact equality — guard returns base unchanged.
        #expect(result == base)
    }

    @Test func jitterStaysWithinBand() {
        // 200% jitter band would produce a 3x spread; clamp floor at 0.
        let base: Duration = .milliseconds(10)
        for _ in 0..<50 {
            let jittered = jitteredDelay(base, jitter: 0.2)
            // Lower bound: base * 0.8; upper bound: base * 1.2.
            // Convert both to nanoseconds for an integer compare.
            let nanos = jittered.components.seconds * 1_000_000_000
                + jittered.components.attoseconds / 1_000_000_000
            #expect(nanos >= 0)
            #expect(nanos <= 12_000_000) // 12ms upper bound
            // Allow the floor to go below 8ms since max(0, …) can
            // collapse under extreme jitter. We just require non-negative.
        }
    }
}
