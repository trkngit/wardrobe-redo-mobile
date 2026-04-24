import Foundation
// `UNNotificationSettings` isn't Sendable under Xcode 16's Swift 6
// checker even though it's effectively immutable. Later Xcodes soften
// this to a warning; `@preconcurrency` keeps both toolchains happy.
@preconcurrency import UserNotifications

/// Manages daily local notifications ("Your outfits are ready").
/// Stores enabled state in UserDefaults.
@MainActor
final class NotificationService {

    static let shared = NotificationService()

    private let center = UNUserNotificationCenter.current()
    private let notificationId = "daily-outfit-reminder"
    private let enabledKey = "notifications_enabled"

    // MARK: - State

    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    // MARK: - Request Permission

    /// Request notification authorization. Returns true if granted.
    func requestPermission() async -> Bool {
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .badge, .sound])
            return granted
        } catch {
            return false
        }
    }

    /// Check current authorization status.
    func checkPermission() async -> UNAuthorizationStatus {
        let settings = await center.notificationSettings()
        return settings.authorizationStatus
    }

    // MARK: - Schedule Daily Notification

    /// Schedule a daily notification at the given hour (0-23).
    /// Default: 8:00 AM local time.
    func scheduleDailyReminder(hour: Int = 8, minute: Int = 0) {
        // Remove existing before rescheduling
        center.removePendingNotificationRequests(withIdentifiers: [notificationId])

        let content = UNMutableNotificationContent()
        content.title = "Your outfits are ready"
        content.body = "Check today's styled outfit suggestions from your wardrobe."
        content.sound = .default

        var dateComponents = DateComponents()
        dateComponents.hour = hour
        dateComponents.minute = minute

        let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: true)
        let request = UNNotificationRequest(
            identifier: notificationId,
            content: content,
            trigger: trigger
        )

        center.add(request)
        isEnabled = true
    }

    // MARK: - Cancel

    /// Cancel the daily notification.
    func cancelDailyReminder() {
        center.removePendingNotificationRequests(withIdentifiers: [notificationId])
        isEnabled = false
    }

    // MARK: - Toggle

    /// Toggle notifications on/off. Requests permission if enabling for the first time.
    /// Toggle notifications on/off. Requests permission if enabling for the first time.
    /// Returns the final enabled state (may differ from requested if permission denied).
    @discardableResult
    func toggle(enabled: Bool) async -> Bool {
        if enabled {
            let status = await checkPermission()
            if status == .notDetermined {
                let granted = await requestPermission()
                if !granted {
                    isEnabled = false
                    return false
                }
            } else if status == .denied {
                isEnabled = false
                return false
            }
            scheduleDailyReminder()
            return true
        } else {
            cancelDailyReminder()
            return false
        }
    }
}
