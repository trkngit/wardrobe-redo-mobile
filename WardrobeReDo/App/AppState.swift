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

    private let supabase = SupabaseManager.shared.client
    private let userRepository = UserRepository()
    private let logger = Logger(subsystem: "com.wardroberedo", category: "AppState")

    func initialize() async {
        logger.info("initialize: starting")
        if let userId = await fetchSessionUserId() {
            logger.info("initialize: session found, userId=\(userId)")
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
            logger.error("signOut failed: \(error)")
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
    private func fetchSessionUserId() async -> UUID? {
        await withTaskGroup(of: UUID?.self) { group in
            group.addTask {
                try? await SupabaseManager.shared.client.auth.session.user.id
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(5))
                return nil
            }
            let result = await group.next()!
            group.cancelAll()
            return result
        }
    }

    /// Loads the user profile with a 10-second timeout to prevent hanging
    /// when the Supabase database query is slow or unreachable.
    private func loadProfile(userId: UUID) async {
        logger.info("loadProfile: starting for userId=\(userId)")
        let profile: Profile? = await withTaskGroup(of: Profile?.self) { group in
            group.addTask {
                try? await UserRepository().fetchProfile(userId: userId)
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(10))
                return nil
            }
            let result = await group.next()!
            group.cancelAll()
            return result
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
            logger.warning("loadProfile: failed or timed out for userId=\(userId)")
        }
    }
}
