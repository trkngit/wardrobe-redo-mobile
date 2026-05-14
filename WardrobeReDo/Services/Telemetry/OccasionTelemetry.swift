import Foundation
import os.log

/// Build 7 — companion to `VibeTelemetry` for the occasion picker.
///
/// Build 6 made vibe a real persisted slider; occasion is session-
/// local because it changes too often to persist meaningfully. The
/// two pickers now share a behavior (every tap auto-regenerates),
/// so they should share an observability shape: one log line per
/// real regen (NOT per raw tap, to avoid flooding during rapid
/// drags), no PII, no item IDs, route through `os.Logger`
/// (Console.app + Sentry breadcrumbs).
///
/// We deliberately don't have a `logChange(previous:new:)` here
/// the way `VibeTelemetry.logOverride` checks against a persisted
/// profile default — occasion has no persisted default, so the
/// useful signal is simply "what did the user end up at when the
/// regen actually fired". Successive `logGenerationOccasion` lines
/// from one session reconstruct the change sequence if needed.
enum OccasionTelemetry {
    private static let logger = Logger(subsystem: "com.wardroberedo", category: "OccasionTelemetry")

    /// Fired before every outfit-generation call, alongside
    /// `VibeTelemetry.logGenerationVibe`. `source` is one of
    /// `"outfits"` (today's outfits) or `"match"` (match flow).
    /// Logged from `runGeneration` / `findMatches`, so rapid
    /// picker taps that get debounced into a single regen
    /// produce exactly one log line.
    static func logGenerationOccasion(_ occasion: Occasion, source: String) {
        logger.info(
            "generation source=\(source, privacy: .public) occasion=\(occasion.rawValue, privacy: .public)"
        )
    }
}
