import SwiftUI
import Kingfisher

struct ItemCardView: View {
    let item: WardrobeItem
    let thumbnailURL: URL?

    /// Storage path the card prefers to render. Items extracted via the
    /// post-00007 pipeline carry a transparent-background cutout at
    /// `maskedImagePath` — using that instead of the framed thumbnail is
    /// what makes two items from the same mirror selfie look distinct
    /// (each card shows just the garment, not the full source photo).
    /// Legacy rows where extraction never ran fall back to `thumbnailPath`.
    static func displayPath(for item: WardrobeItem) -> String {
        item.maskedImagePath ?? item.thumbnailPath
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Thumbnail
            ZStack(alignment: .topTrailing) {
                KFImage(thumbnailURL)
                    .placeholder {
                        Rectangle()
                            .fill(Color(Theme.Colors.muted).opacity(0.3))
                            .overlay {
                                Image(systemName: item.category.iconName)
                                    .font(.system(size: 24, weight: .light))
                                    .foregroundStyle(Color(Theme.Colors.textSecondary))
                            }
                    }
                    .resizable()
                    .scaledToFill()
                    .frame(minHeight: 160)
                    .clipped()

                // Category badge
                Text(item.subcategory.displayName)
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Color(Theme.Colors.textPrimary))
                    .padding(.horizontal, Theme.Spacing.sm)
                    .padding(.vertical, Theme.Spacing.xs)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.chip))
                    .padding(Theme.Spacing.sm)
            }

            // Color dots + metadata
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                HStack(spacing: 4) {
                    ForEach(Array(item.dominantColors.prefix(3).enumerated()), id: \.offset) { index, color in
                        Circle()
                            .fill(Color(hex: color.hex))
                            .frame(width: 10, height: 10)
                            .overlay(
                                Circle().stroke(.white, lineWidth: 1)
                            )
                            .scalePopIn(delay: Double(index) * 0.1)
                    }

                    Spacer()

                    if item.wearCount > 0 {
                        HStack(spacing: 2) {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: 9))
                            Text("\(item.wearCount)")
                                .font(Theme.Fonts.caption)
                        }
                        .foregroundStyle(Color(Theme.Colors.textSecondary))
                    }
                }

                Text(item.category.displayName)
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Color(Theme.Colors.textSecondary))
            }
            .padding(Theme.Spacing.sm)
        }
        .background(Color(Theme.Colors.surface))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
        .cardShadow()
    }
}

#Preview {
    let item = WardrobeItem(
        id: UUID(),
        userId: UUID(),
        imagePath: "",
        thumbnailPath: "",
        category: .top,
        subcategory: .tshirt,
        dominantColors: [
            ColorProfile(hex: "#2C3E50", hue: 210, saturation: 0.3, lightness: 0.25, percentage: 65, colorFamily: "navy", isNeutral: true),
            ColorProfile(hex: "#E74C3C", hue: 6, saturation: 0.78, lightness: 0.57, percentage: 22, colorFamily: "red", isNeutral: false),
        ],
        texture: .cotton,
        fitAttribute: .regular,
        formalityComponents: nil,
        formalityComputed: nil,
        seasons: [.spring, .summer],
        occasions: [.casual],
        visualWeight: nil,
        wearCount: 5,
        lastWornAt: nil,
        isArchived: false,
        createdAt: .now,
        updatedAt: .now
    )

    ItemCardView(item: item, thumbnailURL: nil)
        .frame(width: 180)
        .padding()
}
