import Foundation
import Observation
import os
import Supabase

@MainActor
@Observable
final class AppState {
    var isAuthenticated = false
    var isLoading = true
    var currentUser: Profile?
    var profileLoadFailed = false

    // MARK: - Build 8 — cross-tab navigation

    /// Index of the currently visible tab. Lifted out of
    /// `TabRootView` so deep-link CTAs (e.g. "Add an Item"
    /// in the Outfits failure banner) can switch tabs without
    /// passing bindings through every intermediate view.
    ///
    /// Ordering matches `TabRootView`: 0=Wardrobe, 1=Outfits,
    /// 2=Match, 3=Profile.
    var selectedTab: Int = 0

    /// Pulse this from a deep-link CTA to ask the Wardrobe tab
    /// to open the Add Item sheet on its next appearance. The
    /// grid view consumes + clears this in `onAppear` so
    /// repeated tab switches don't keep re-presenting it.
    var pendingAddItem: Bool = false

    // MARK: - Build 19 — network reachability

    /// Reachability monitor for the app. Single instance shared
    /// across views via the `AppState` environment. Read
    /// `networkMonitor.isOnline` to decide whether to short-circuit
    /// network calls or surface an offline banner.
    let networkMonitor = NetworkMonitor()

    private let supabase = SupabaseManager.shared.client
    private let userRepository = UserRepository()
    private let logger = Logger(subsystem: "com.wardroberedo", category: "AppState")

    func initialize() async {
        logger.info("initialize: starting")
        if let userId = await fetchSessionUserId() {
            // Build 20 — hash-mask the user ID so log correlation
            // still works (same input → same hash) without leaking
            // the raw UUID to Console / Sentry.
            LogPrivacy.info(logger, category: "initialize.sessionFound", userId: userId)
            isAuthenticated = true
            await loadProfile(userId: userId)
            logger.info("initialize: profile load complete, currentUser=\(self.currentUser != nil)")
        } else {
            logger.info("initialize: no session found")
            isAuthenticated = false
        }
        isLoading = false
        logger.info("initialize: done, isLoading=false")
    }

    func handleAuthChange() async {
        logger.info("handleAuthChange: listening")
        while !Task.isCancelled {
            for await (event, session) in supabase.auth.authStateChanges {
                logger.info("handleAuthChange: event=\(String(describing: event))")
                switch event {
                case .signedIn:
                    isAuthenticated = true
                    if let userId = session?.user.id {
                        await loadProfile(userId: userId)
                    }
                case .signedOut:
                    isAuthenticated = false
                    currentUser = nil
                default:
                    break
                }
            }
            logger.warning("handleAuthChange: stream ended, reconnecting in 2s")
            try? await Task.sleep(for: .seconds(2))
        }
    }

    func signOut() async {
        do {
            try await supabase.auth.signOut()
            WidgetDataService.clearWidget()
            NotificationService.shared.cancelDailyReminder()
        } catch {
            // Build 20 — privacy split: "signOut failed" is the
            // searchable public marker; the wrapped error (which
            // can contain auth state) is masked in release.
            LogPrivacy.error(logger, category: "signOut", reason: error)
        }
    }

    func refreshProfile() async {
        logger.info("refreshProfile: starting")
        profileLoadFailed = false
        guard let userId = await fetchSessionUserId() else {
            logger.warning("refreshProfile: no session")
            profileLoadFailed = true
            return
        }
        await loadProfile(userId: userId)
    }

    /// Fetches the current user ID from the auth session, racing against a
    /// 5-second timeout to prevent hanging when Supabase is unreachable.
    ///
    /// Build 22 — race plumbing extracted to `TimeoutRace.runWithTimeout`
    /// so the three timeout-race sites in the app share one
    /// implementation. Behavior is unchanged: nil result either means
    /// the session API returned nil OR the 5 s deadline fired first.
    private func fetchSessionUserId() async -> UUID? {
        await TimeoutRace.runWithTimeout(timeout: .seconds(5)) {
            try? await SupabaseManager.shared.client.auth.session.user.id
        }
    }

    /// Loads the user profile with a 10-second timeout to prevent hanging
    /// when the Supabase database query is slow or unreachable.
    ///
    /// Build 22 — race plumbing extracted to `TimeoutRace.runWithTimeout`.
    /// See `fetchSessionUserId` for the rationale.
    private func loadProfile(userId: UUID) async {
        // Build 20 — see initialize() for the rationale.
        LogPrivacy.info(logger, category: "loadProfile.starting", userId: userId)
        let profile: Profile? = await TimeoutRace.runWithTimeout(timeout: .seconds(10)) {
            try? await UserRepository().fetchProfile(userId: userId)
        }

        if let profile {
            currentUser = profile
            profileLoadFailed = false
            logger.info("loadProfile: success, displayName=\(profile.displayName)")
            // Build 6: tag the user's stored default vibe once per
            // app session so we can see the distribution across
            // active users without sampling per-generation events.
            VibeTelemetry.logProfileDefault(profile.defaultVibe)
        } else {
            profileLoadFailed = true
            // Build 20 — same hash-masking as the success-path log.
            LogPrivacy.info(logger, category: "loadProfile.failedOrTimedOut", userId: userId)
        }
    }
}
