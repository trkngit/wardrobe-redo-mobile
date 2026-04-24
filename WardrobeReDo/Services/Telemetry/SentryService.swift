import Foundation
import OSLog

#if canImport(Sentry)
import Sentry
#endif

/// Production crash + error reporting hook.
///
/// Sentry is initialized only when a non-empty `SENTRY_DSN` exists in
/// `Secrets.plist`. If the DSN is missing or empty, configuration is a
/// silent no-op — the app still works, just without remote error
/// reporting. This lets devs run locally without a DSN and lets the
/// autonomous build land the integration before the user provisions
/// a real DSN.
///
/// Safety / privacy:
/// - `attachStacktrace = true`, but PII is never attached.
/// - `sendDefaultPii = false` — email, IP, username are redacted.
/// - Breadcrumbs for network calls are opt-out via `enableNetworkBreadcrumbs = false`
///   to avoid leaking Supabase URLs or query params.
/// - Environment is tagged from `INFOPLIST_KEY_CFBundleShortVersionString` +
///   build config (debug vs release).
enum SentryService {

    private static let log = Logger(subsystem: "com.wardroberedo", category: "Sentry")

    /// Configure Sentry if a DSN is provisioned. Call once at app launch,
    /// ideally before any network or ML code so initial crashes are captured.
    static func configure() {
        #if canImport(Sentry)
        guard let dsn = readDSN(), !dsn.isEmpty else {
            log.info("SENTRY_DSN not set — crash reporting disabled")
            return
        }

        SentrySDK.start { options in
            options.dsn = dsn
            options.debug = false

            #if DEBUG
            options.environment = "debug"
            options.tracesSampleRate = 1.0
            #else
            options.environment = "release"
            options.tracesSampleRate = 0.1
            #endif

            // Privacy-first defaults.
            options.sendDefaultPii = false
            options.attachStacktrace = true
            options.enableNetworkBreadcrumbs = false

            // Release tag = app marketing version + build number.
            if let info = Bundle.main.infoDictionary,
               let version = info["CFBundleShortVersionString"] as? String,
               let build = info["CFBundleVersion"] as? String {
                options.releaseName = "wardroberedo@\(version)+\(build)"
            }
        }
        log.info("Sentry initialized")
        #else
        log.info("Sentry module unavailable at compile time — skipping")
        #endif
    }

    /// Fire a non-fatal `message`-level event through Sentry as a smoke
    /// test. Used by the DEBUG Developer menu to verify crash-reporting
    /// plumbing end-to-end — per the Tier A1 verification criteria
    /// ("trigger a caught event in DEBUG dev menu → event appears in
    /// Sentry dashboard within 60 s").
    ///
    /// Safe to call whether or not Sentry was initialized. Returns `true`
    /// if an event was submitted, `false` if the SDK is disabled (missing
    /// DSN, or module unavailable at compile time). Caller can surface
    /// that to the dev so they know to provision the DSN before expecting
    /// dashboard activity.
    @discardableResult
    static func captureSmokeEvent(note: String = "manual smoke") -> Bool {
        #if canImport(Sentry)
        guard SentrySDK.isEnabled else {
            log.info("Sentry smoke requested but SDK is disabled (no DSN?)")
            return false
        }
        SentrySDK.capture(message: "wardroberedo dev-menu smoke — \(note)")
        log.info("Sentry smoke event fired (note=\(note, privacy: .public))")
        return true
        #else
        log.info("Sentry smoke requested but module unavailable at compile time")
        return false
        #endif
    }

    // MARK: - Private

    /// Read `SENTRY_DSN` from the same `Secrets.plist` Supabase uses.
    /// Returns `nil` if the file or key is missing — crash reporting then
    /// silently stays off.
    private static func readDSN() -> String? {
        guard let path = Bundle.main.path(forResource: "Secrets", ofType: "plist"),
              let dict = NSDictionary(contentsOfFile: path) else {
            return nil
        }
        return dict["SENTRY_DSN"] as? String
    }
}
