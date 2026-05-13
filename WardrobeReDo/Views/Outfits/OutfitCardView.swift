import SwiftUI
import Kingfisher

/// A card displaying one outfit: editorial name, item thumbnails,
/// score badge, and reaction indicator. Designed for the paged
/// daily outfits carousel.
struct OutfitCardView: View {
    let dailyOutfit: DailyOutfit
    let thumbnailURLs: [UUID: URL]

    private var outfit: Outfit { dailyOutfit.outfit }
    private var items: [WardrobeItem] { dailyOutfit.items }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // MARK: - Header
            headerSection

            // MARK: - Item Thumbnails
            itemThumbnailStrip

            // MARK: - Footer
            footerSection
        }
        .background(Color(Theme.Colors.surface))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
        .cardShadow()
        // Build 10 — visually dim a skipped outfit so the carousel
        // reflects the user's "not today" signal. Previously the
        // skip reaction only set a forward-arrow icon in the
        // footer — easy to miss. Halving the opacity + a tiny
        // desaturation effect makes the card recede without
        // removing it, so the user can change their mind by
        // re-reacting. Animates with the existing reaction-update
        // path on the VM (no new animation key needed).
        .opacity(isSkipped ? 0.45 : 1.0)
        .saturation(isSkipped ? 0.4 : 1.0)
        .animation(Theme.Animation.standard, value: isSkipped)
    }

    /// True when the user explicitly skipped this outfit. The
    /// reaction column is a free-form string for forward
    /// compatibility, but `"skip"` is the value the React menu
    /// writes today.
    private var isSkipped: Bool { outfit.reaction == "skip" }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            // Score badge
            HStack {
                Text(outfit.editorialName)
                    .font(Theme.Fonts.h2)
                    .foregroundStyle(Color(Theme.Colors.textPrimary))
                    .lineLimit(1)

                Spacer()

                scoreBadge
            }

            if let description = outfit.editorialDescription {
                Text(description)
                    .font(Theme.Fonts.bodySmall)
                    .foregroundStyle(Color(Theme.Colors.textSecondary))
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.top, Theme.Spacing.md)
        .padding(.bottom, Theme.Spacing.sm)
    }

    // MARK: - Score Badge

    private var scoreBadge: some View {
        let percentage = Int(outfit.score * 100)
        return Text("\(percentage)")
            .font(.system(size: 18, weight: .semibold, design: .rounded))
            .foregroundStyle(Color(Theme.Colors.primary))
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.vertical, Theme.Spacing.xs)
            .background(Color(Theme.Colors.primaryMuted).opacity(0.2))
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.chip))
    }

    // MARK: - Item Thumbnail Strip

    private var itemThumbnailStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Spacing.sm) {
                ForEach(items) { item in
                    itemThumbnail(for: item)
                }
            }
            .padding(.horizontal, Theme.Spacing.md)
        }
        .padding(.vertical, Theme.Spacing.sm)
    }

    private func itemThumbnail(for item: WardrobeItem) -> some View {
        VStack(spacing: Theme.Spacing.xs) {
            ZStack(alignment: .topTrailing) {
                KFImage(thumbnailURLs[item.id])
                    .placeholder {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(Theme.Colors.muted).opacity(0.3))
                            .overlay {
                                Image(systemName: item.category.iconName)
                                    .font(.system(size: 18, weight: .light))
                                    .foregroundStyle(Color(Theme.Colors.textSecondary))
                            }
                    }
                    .resizable()
                    .scaledToFill()
                    .frame(width: 80, height: 100)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                // Build 9 — wear-count badge in the top-right corner.
                // Helps the user spot wardrobe-rotation imbalance:
                // "this top is in every other outfit" pops visually.
                // Hidden at zero wears (fresh item) so unworn pieces
                // look clean; appears as a small numbered chip once
                // wear count climbs. The pill background uses the
                // primary tint at low opacity so it reads as
                // informative metadata, not an alert.
                if item.wearCount > 0 {
                    wearCountBadge(count: item.wearCount)
                        .padding(.top, 4)
                        .padding(.trailing, 4)
                        .accessibilityLabel("Worn \(item.wearCount) \(item.wearCount == 1 ? "time" : "times")")
                }
            }

            // Slot role indicator
            if let slot = dailyOutfit.slots.first(where: { $0.wardrobeItemId == item.id }) {
                Text(slot.role.capitalized)
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(
                        slot.role == "hero"
                            ? Color(Theme.Colors.primary)
                            : Color(Theme.Colors.textSecondary)
                    )
            }
        }
    }

    /// Build 9 — tiny wear-count chip. Scales the visual weight
    /// with the count: 1-2 reads subtle, 5+ reads "rotation-heavy".
    /// Numbers above 9 collapse to "9+" so the pill stays
    /// fixed-width and the thumbnail strip doesn't reflow.
    ///
    /// Build 25 — contrast tune. Was `Color(primary).opacity(0.92)`
    /// fill, which in dark mode reads as a dim gold-on-dark pill
    /// that doesn't pop against the cutout's transparent
    /// background. Solid `primary` + a stronger drop shadow lifts
    /// the badge off the thumbnail in both modes. White stroke
    /// kept for the cut-from-photo halo effect on busy items.
    private func wearCountBadge(count: Int) -> some View {
        Text(count > 9 ? "9+" : "\(count)")
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .frame(minWidth: 18, minHeight: 18)
            .padding(.horizontal, 4)
            .background(
                Capsule()
                    .fill(Color(Theme.Colors.primary))
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
            )
            .overlay(
                Capsule()
                    .stroke(.white, lineWidth: 1)
            )
    }

    // MARK: - Footer

    private var footerSection: some View {
        HStack {
            // Color dots from outfit items
            HStack(spacing: 3) {
                ForEach(Array(colorDots.prefix(5).enumerated()), id: \.offset) { _, hex in
                    Circle()
                        .fill(Color(hex: hex))
                        .frame(width: 8, height: 8)
                        .overlay(Circle().stroke(.white, lineWidth: 0.5))
                }
            }

            Spacer()

            // Reaction indicator
            if let reaction = outfit.reaction {
                reactionIcon(reaction)
            }

            // Worn badge
            if outfit.isWorn {
                Label("Worn", systemImage: "checkmark.circle.fill")
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Color(Theme.Colors.primary))
            }
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.bottom, Theme.Spacing.md)
        .padding(.top, Theme.Spacing.xs)
    }

    // MARK: - Helpers

    private var colorDots: [String] {
        items.compactMap { $0.dominantColors.first?.hex }
    }

    private func reactionIcon(_ reaction: String) -> some View {
        let (icon, color): (String, Color) = switch reaction {
        case "love": ("heart.fill", .red)
        case "like": ("hand.thumbsup.fill", Color(Theme.Colors.primary))
        default: ("forward.fill", Color(Theme.Colors.textSecondary))
        }

        return Image(systemName: icon)
            .font(.system(size: 12))
            .foregroundStyle(color)
            .padding(.trailing, Theme.Spacing.xs)
    }
}
