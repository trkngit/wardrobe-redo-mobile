import Foundation
import os

/// Build 20 — privacy-aware logging helpers.
///
/// Background: the parallel codebase audit flagged that several
/// `Logger.error` calls interpolate `String(describing: error)` —
/// which under `Logger`'s default-private rules masks the message
/// as `<private>` in release builds. That's correct for credentials
/// but it also masks useful diagnostic info (HTTP status codes,
/// SQL error codes) that we WANT to see in Sentry / Console.app.
///
/// The right model — and what Apple's WWDC 2020 "Explore logging
/// in Swift" session recommends — is to split each log line into:
///
///   • A public "what happened" message (always shown).
///   • A private payload (masked in release, full in debug).
///
/// These helpers make that pattern explicit so callers don't have
/// to think about the privacy attribute on every site. They're
/// thin wrappers; the work is in the convention, not the code.
///
/// Usage:
///
///     logger.error("\(category, privacy: .public): \(reason, privacy: .private)")
///
/// becomes
///
///     LogPrivacy.error(logger, category: "signIn", reason: error)
///
/// Reads the same as the inline version but harder to get wrong.
enum LogPrivacy {

    /// Log an error with a public category prefix + a private
    /// payload. The category should be a short, deterministic
    /// string (e.g. "signIn", "loadProfile", "uploadImage") that
    /// lets you grep production logs without leaking anything
    /// user-specific.
    ///
    /// `error` is converted via `String(describing:)` and tagged
    /// `.private`, so its contents are masked in release builds
    /// where they could contain emails / session tokens.
    static func error(
        _ logger: Logger,
        category: StaticString,
        reason: Error,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        let reasonString = String(describing: reason)
        logger.error("\(category, privacy: .public) failed: \(reasonString, privacy: .private)")
    }

    /// Warning variant — same shape, lower severity.
    static func warning(
        _ logger: Logger,
        category: StaticString,
        reason: String
    ) {
        logger.warning("\(category, privacy: .public): \(reason, privacy: .private)")
    }

    /// Info variant — useful for "we finished X for user Y" lines
    /// where the user ID is privacy-sensitive. UUID is logged
    /// as private (a hashed redaction in release) so we can still
    /// correlate logs without exposing the raw ID.
    static func info(
        _ logger: Logger,
        category: StaticString,
        userId: UUID
    ) {
        logger.info("\(category, privacy: .public) for userId=\(userId.uuidString, privacy: .private(mask: .hash))")
    }
}
