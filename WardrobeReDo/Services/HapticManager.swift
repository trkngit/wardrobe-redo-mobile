import UIKit

/// Centralized haptic feedback manager with typed feedback styles.
/// Replaces scattered UIImpactFeedbackGenerator calls throughout views.
enum HapticManager {

    // MARK: - Impact

    /// Light tap — button presses, chip selections.
    static func light() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// Medium tap — toggle states, card interactions.
    static func medium() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    /// Heavy tap — destructive actions, confirmations.
    static func heavy() {
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
    }

    // MARK: - Notification

    /// Success — outfit saved, generation complete, item added.
    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    /// Warning — validation issue, missing data.
    static func warning() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }

    /// Error — action failed, network error.
    static func error() {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }

    // MARK: - Selection

    /// Subtle tick — scrolling through items, paging.
    static func selection() {
        UISelectionFeedbackGenerator().selectionChanged()
    }
}
