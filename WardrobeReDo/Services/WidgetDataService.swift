import Foundation
import WidgetKit

/// Writes outfit data to the shared App Group so the widget
/// can display today's top outfit without a network call.
enum WidgetDataService {

    private static let suiteName = "group.com.digitalatelier.wardroberedo"

    /// Update widget data with today's top outfit.
    static func updateWidget(outfitName: String, score: Int, itemCount: Int) {
        guard let defaults = UserDefaults(suiteName: suiteName) else { return }

        defaults.set(outfitName, forKey: "widget_outfit_name")
        defaults.set(score, forKey: "widget_outfit_score")
        defaults.set(itemCount, forKey: "widget_outfit_items")

        // Tell WidgetKit to refresh
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Clear widget data (e.g. on sign out).
    static func clearWidget() {
        guard let defaults = UserDefaults(suiteName: suiteName) else { return }
        defaults.removeObject(forKey: "widget_outfit_name")
        defaults.removeObject(forKey: "widget_outfit_score")
        defaults.removeObject(forKey: "widget_outfit_items")
        WidgetCenter.shared.reloadAllTimelines()
    }
}
