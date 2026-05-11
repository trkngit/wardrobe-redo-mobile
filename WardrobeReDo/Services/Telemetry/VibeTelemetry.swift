import Foundation
import os.log

/// Lightweight telemetry for the build-6 vibe slider. All events
/// route through `os.Logger` (Console.app + Sentry breadcrumbs);
/// nothing here uploads PII, raw image bytes, or item IDs. We log:
///
///   1. **Profile default** — fired once per app session when the
///      profile loads. Lets us answer "what's the distribution of
///      default vibes across active users?"
///   2. **Generation vibe** — fired before every outfit-generation
///      call (Outfits tab + Match tab) so we can answer "what
///      does the user actually pick at generate time?"
///   3. **Override** — fired when the per-generation pick differs
///      from the profile default. Signals "their default is
///      probably wrong; they keep overriding."
///   4. **Default change** — fired when the user explicitly
///      changes their default in Settings or onboarding.
///
/// These four events together let us tune the per-stop preset
/// table from real usage data instead of the hand-rolled defaults
/// (see `RULES_AUDIT.md` § "Take-aways").
enum VibeTelemetry {
    private static let logger = Logger(subsystem: "com.wardroberedo", category: "VibeTelemetry")

    /// One-shot per app session. Called from `AppState` after
    /// `loadProfile` resolves.
    static func logProfileDefault(_ vibe: VibeStop) {
        logger.info("profileDefault vibe=\(vibe.rawValue, privacy: .public)")
    }

    /// Fired before every outfit-generation call. `source` is one
    /// of `"outfits"` (today's outfits) or `"match"` (match flow).
    static func logGenerationVibe(_ vibe: VibeStop, source: String) {
        logger.info("generation source=\(source, privacy: .public) vibe=\(vibe.rawValue, privacy: .public)")
    }

    /// Fired when the per-generation pick differs from the
    /// profile default. The `default_` / `selected` pair lets us
    /// build a confusion matrix.
    static func logOverride(default defaultVibe: VibeStop, selected: VibeStop, source: String) {
        guard defaultVibe != selected else { return }
        logger.info(
            "override source=\(source, privacy: .public) default=\(defaultVibe.rawValue, privacy: .public) selected=\(selected.rawValue, privacy: .public)"
        )
    }

    /// Fired when the user explicitly writes a new default
    /// through Settings or completes onboarding with a non-
    /// `.balanced` pick. The `via` payload tags the surface
    /// (`"settings"` / `"onboarding"`).
    static func logDefaultChanged(to vibe: VibeStop, via surface: String) {
        logger.info(
            "defaultChanged via=\(surface, privacy: .public) vibe=\(vibe.rawValue, privacy: .public)"
        )
    }
}
