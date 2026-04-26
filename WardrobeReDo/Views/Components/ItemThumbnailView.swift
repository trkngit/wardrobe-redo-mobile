import SwiftUI
import Kingfisher

/// Single source of truth for rendering a wardrobe item's thumbnail
/// across the app. Today four surfaces render item thumbnails — the
/// wardrobe grid, the match-tab piece selector, the outfit-card item
/// strip, and the outfit-detail item grid. Each used to resolve the
/// Storage path inline, which let one bug class (preferring the framed
/// source-photo thumbnail over the per-item cutout) regress in three
/// places while only one was patched.
///
/// Design intent for build 5+:
///   * `displayPath(for:)` is the single resolver. Every surface that
///     wants to show an item thumbnail goes through this view (or, at
///     minimum, calls the static resolver) rather than reading
///     `thumbnailPath` directly.
///   * `Size` covers the three present consumers — 44pt strip cells in
///     the match tab, 160pt grid cards, and full-width detail heroes —
///     so adopting `ItemThumbnailView` doesn't require call sites to
///     redo their layout math.
///   * The view stays presentational: it accepts an already-resolved
///     `URL?` and delegates URL resolution to the call site's view
///     model (matching the existing `ItemCardView` contract). PR #22
///     just lands the component; PR #27 swaps the four surfaces over
///     once the redesign locks in.
struct ItemThumbnailView: View {
    enum Size {
        /// 44pt — match tab piece selector strip.
        case small
        /// 160pt — wardrobe grid cards, outfit-card item strip.
        case medium
        /// Full-width — item detail hero, outfit detail grid cells.
        case large

        var dimension: CGFloat? {
            switch self {
            case .small: return 44
            case .medium: return 160
            case .large: return nil
            }
        }
    }

    let item: WardrobeItem
    let url: URL?
    let size: Size

    /// Storage path the thumbnail prefers — the per-item cutout
    /// (`maskedImagePath`) when available, falling back to the framed
    /// source-photo thumbnail. Mirrors `ItemCardView.displayPath` so
    /// call sites can migrate either name without changing behaviour.
    static func displayPath(for item: WardrobeItem) -> String {
        ItemCardView.displayPath(for: item)
    }

    var body: some View {
        ZStack {
            // White background — pure white in light mode and the system
            // secondary background (≈#1C1C1E) in dark mode. Industry
            // convention for fashion product cards (Whering, Acloset,
            // Indyx, SSENSE) and what unifies a wardrobe of cutouts shot
            // against wildly different sources into one product surface.
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .fill(cardBackground)

            KFImage(url)
                .placeholder { placeholder }
                .resizable()
                // `scaledToFit` (not `.scaledToFill`) is the load-bearing
                // change in PR #27: the cutout sits centred on the white
                // card with breathing room rather than getting cropped to
                // the frame edge. A 16pt inset puts the garment at the
                // ~70% fill point industry mockups land on.
                .scaledToFit()
                .padding(thumbnailPadding)
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(width: size.dimension, height: size.dimension)
    }

    /// Padding shrinks for the 44pt strip cell so the garment stays
    /// readable at small sizes — 16pt of inset on a 44pt frame leaves no
    /// room for the image. Medium and large keep the spec's 16pt.
    private var thumbnailPadding: CGFloat {
        switch size {
        case .small: return 4
        case .medium, .large: return 16
        }
    }

    private var cardBackground: Color {
        Color(uiColor: .systemBackground)
    }

    private var placeholder: some View {
        Image(systemName: item.category.iconName)
            .font(.system(size: size == .small ? 16 : 24, weight: .light))
            .foregroundStyle(Color(Theme.Colors.textSecondary))
    }
}

#Preview("Sizes") {
    let item = WardrobeItem(
        id: UUID(),
        userId: UUID(),
        imagePath: "",
        thumbnailPath: "thumb.jpg",
        maskedImagePath: "masked.png",
        category: .top,
        subcategory: .tshirt,
        dominantColors: [],
        seasons: [.spring],
        occasions: [.casual],
        wearCount: 0,
        isArchived: false,
        createdAt: .now,
        updatedAt: .now
    )

    return VStack(spacing: 16) {
        ItemThumbnailView(item: item, url: nil, size: .small)
        ItemThumbnailView(item: item, url: nil, size: .medium)
        ItemThumbnailView(item: item, url: nil, size: .large)
            .frame(maxWidth: 240)
    }
    .padding()
}
