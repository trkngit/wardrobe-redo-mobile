import WidgetKit
import SwiftUI

// MARK: - Timeline Entry

struct OutfitEntry: TimelineEntry {
    let date: Date
    let outfitName: String
    let score: Int
    let itemCount: Int
    let isPlaceholder: Bool

    static let placeholder = OutfitEntry(
        date: .now,
        outfitName: "The Tailored Line",
        score: 78,
        itemCount: 4,
        isPlaceholder: true
    )

    static let empty = OutfitEntry(
        date: .now,
        outfitName: "No outfits yet",
        score: 0,
        itemCount: 0,
        isPlaceholder: false
    )
}

// MARK: - Timeline Provider

struct OutfitTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> OutfitEntry {
        .placeholder
    }

    func getSnapshot(in context: Context, completion: @escaping (OutfitEntry) -> Void) {
        if context.isPreview {
            completion(.placeholder)
        } else {
            completion(loadCurrentEntry())
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<OutfitEntry>) -> Void) {
        let entry = loadCurrentEntry()

        // Refresh every 2 hours
        let nextUpdate = Calendar.current.date(byAdding: .hour, value: 2, to: .now)!
        let timeline = Timeline(entries: [entry], policy: .after(nextUpdate))
        completion(timeline)
    }

    /// Load today's top outfit from App Group shared UserDefaults.
    private func loadCurrentEntry() -> OutfitEntry {
        guard let defaults = UserDefaults(suiteName: "group.com.digitalatelier.wardroberedo"),
              let name = defaults.string(forKey: "widget_outfit_name") else {
            return .empty
        }

        return OutfitEntry(
            date: .now,
            outfitName: name,
            score: defaults.integer(forKey: "widget_outfit_score"),
            itemCount: defaults.integer(forKey: "widget_outfit_items"),
            isPlaceholder: false
        )
    }
}

// MARK: - Small Widget View

struct SmallWidgetView: View {
    let entry: OutfitEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "sparkles")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.orange)

                Spacer()

                if entry.score > 0 {
                    Text("\(entry.score)")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(.orange)
                }
            }

            Spacer()

            Text(entry.outfitName)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(2)

            if entry.itemCount > 0 {
                Text("\(entry.itemCount) items")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                Text("Open to generate")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .containerBackground(for: .widget) {
            Color(.systemBackground)
        }
    }
}

// MARK: - Medium Widget View

struct MediumWidgetView: View {
    let entry: OutfitEntry

    var body: some View {
        HStack(spacing: 16) {
            // Left: today's info
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.orange)
                    Text("Today's Outfit")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                }

                Spacer()

                Text(entry.outfitName)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                HStack(spacing: 12) {
                    if entry.score > 0 {
                        Label("\(entry.score)", systemImage: "chart.bar.fill")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.orange)
                    }
                    if entry.itemCount > 0 {
                        Label("\(entry.itemCount) items", systemImage: "tshirt")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            // Right: decorative score ring
            if entry.score > 0 {
                ZStack {
                    Circle()
                        .stroke(Color.orange.opacity(0.2), lineWidth: 4)
                    Circle()
                        .trim(from: 0, to: Double(entry.score) / 100.0)
                        .stroke(Color.orange, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(-90))

                    Text("\(entry.score)")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundStyle(.orange)
                }
                .frame(width: 56, height: 56)
            }
        }
        .containerBackground(for: .widget) {
            Color(.systemBackground)
        }
    }
}

// MARK: - Widget Configuration

struct WardrobeWidget: Widget {
    let kind = "WardrobeWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: OutfitTimelineProvider()) { entry in
            if #available(iOS 17.0, *) {
                WidgetEntryView(entry: entry)
            }
        }
        .configurationDisplayName("Today's Outfit")
        .description("See your top styled outfit suggestion at a glance.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct WidgetEntryView: View {
    @Environment(\.widgetFamily) var family
    let entry: OutfitEntry

    var body: some View {
        switch family {
        case .systemMedium:
            MediumWidgetView(entry: entry)
        default:
            SmallWidgetView(entry: entry)
        }
    }
}

// MARK: - Widget Bundle

@main
struct WardrobeWidgetBundle: WidgetBundle {
    var body: some Widget {
        WardrobeWidget()
    }
}

// MARK: - Previews

#Preview("Small", as: .systemSmall) {
    WardrobeWidget()
} timeline: {
    OutfitEntry.placeholder
    OutfitEntry.empty
}

#Preview("Medium", as: .systemMedium) {
    WardrobeWidget()
} timeline: {
    OutfitEntry.placeholder
    OutfitEntry.empty
}
