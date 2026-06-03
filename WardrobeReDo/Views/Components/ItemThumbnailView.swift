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

    /// Build 31 — holds the alpha-trimmed copy of the loaded
    /// thumbnail once `AlphaTrimmer` produces it. `nil` while the
    /// trim is in flight OR for items where the original image had
    /// no trimmable padding. The overlay below renders this if
    /// present, falling through to the original KFImage otherwise.
    @State private var trimmedImage: UIImage?

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
                // Build 31 — when the image lands, kick off an
                // alpha-trim on a background task so the cutout's
                // tight non-transparent bounds become the visual
                // bbox. See `AlphaTrimmer` for why: items with loose
                // masks previously looked ~50% smaller than items
                // with tight masks. The trimmed result lands in the
                // cache and the overlay below picks it up. While the
                // trim is in flight we render the original — that's
                // ~5ms on A15+, only on first paint per URL.
                .onSuccess { result in
                    triggerTrim(for: result.image)
                }
                .resizable()
                // `scaledToFit` (not `.scaledToFill`) is the load-bearing
                // change in PR #27: the cutout sits centred on the white
                // card with breathing room rather than getting cropped to
                // the frame edge. A 16pt inset puts the garment at the
                // ~70% fill point industry mockups land on.
                .scaledToFit()
                .padding(thumbnailPadding)

            // Build 31 — overlays the trimmed image once
            // `triggerTrim` completes. Until then we render the
            // original KFImage above (a short visual blip on first
            // paint per URL, never on cache hits).
            if let trimmed = trimmedImage {
                Image(uiImage: trimmed)
                    .resizable()
                    .scaledToFit()
                    .padding(thumbnailPadding)
                    .background(cardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
                    .transition(.opacity)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(width: size.dimension, height: size.dimension)
        .animation(Theme.Animation.standard, value: trimmedImage)
        .onChange(of: url) { _, _ in
            // Reset when the URL changes (e.g. cell reuse in a
            // LazyVGrid) — otherwise the previous item's trim
            // briefly bleeds through before the new one lands.
            trimmedImage = nil
            if let url, let cached = AlphaTrimCache.shared.image(forKey: url.absoluteString) {
                trimmedImage = cached
            }
        }
        .onAppear {
            // Prime from the cache on first appear so cache hits
            // skip the KFImage round-trip entirely.
            if let url, let cached = AlphaTrimCache.shared.image(forKey: url.absoluteString) {
                trimmedImage = cached
            }
        }
    }

    /// Background-task trim. Reads the cache first so a cache hit
    /// is a no-op. On miss, runs `AlphaTrimmer.trimmed(_:)` off the
    /// main actor, stores it in the cache, and assigns
    /// `trimmedImage` on the main actor to publish to SwiftUI.
    /// `@State`'s setter is `nonmutating` so writing from a
    /// captured closure works the same as writing from the body.
    private func triggerTrim(for image: UIImage) {
        guard let url else { return }
        let key = url.absoluteString
        if let cached = AlphaTrimCache.shared.image(forKey: key) {
            trimmedImage = cached
            return
        }
        Task.detached(priority: .userInitiated) {
            guard let trimmed = AlphaTrimmer.trimmed(image) else { return }
            AlphaTrimCache.shared.store(trimmed, forKey: key)
            await MainActor.run {
                // Ignore if the URL changed mid-flight — the
                // `.onChange(of: url)` handler above already
                // surfaced whatever the new URL's trim happens
                // to be.
                guard self.url?.absoluteString == key else { return }
                self.trimmedImage = trimmed
            }
        }
    }

    /// Padding shrinks for the 44pt strip cell so the garment stays
    /// readable at small sizes — 16pt of inset on a 44pt frame leaves no
    /// room for the image. Build 26 / Bug A — the grid `.medium` cell
    /// dropped to 8pt because user testing read the prior 16pt as
    /// "items look too small". The white-card breathing room aesthetic
    /// stays (8pt is still real padding around the cutout) but the
    /// garment now occupies ~85% of the card area instead of ~55%
    /// for short-aspect items like sneakers. Detail view stays at
    /// 16pt — that surface has the room to spare.
    private var thumbnailPadding: CGFloat {
        switch size {
        case .small: return 4
        case .medium: return 8
        case .large: return 16
        }
    }

    private var cardBackground: Color {
        // Build 48 — fixed eggshell, theme-stable (was the adaptive
        // `.systemBackground`, which flipped to ~#1C1C1E in dark mode).
        // The user wants every cutout showcased on a stable off-white
        // bone backdrop regardless of system theme, so a wardrobe of
        // cutouts shot against wildly different sources unifies into one
        // consistent product surface that doesn't darken at night.
        Theme.Colors.showcase
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
