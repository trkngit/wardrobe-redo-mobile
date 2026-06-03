import SwiftUI
import Kingfisher

extension Notification.Name {
    static let wardrobeDidChange = Notification.Name("wardrobeDidChange")
}

struct ItemDetailView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let item: WardrobeItem

    /// Signed URL for the detail hero — the per-item cutout (see
    /// `heroImagePath`).
    @State private var imageURL: URL?
    /// Signed URL for the ORIGINAL source photo. Shown only in the
    /// fullscreen viewer so the user can still see where the item was
    /// photographed. Build 50 — split out from `imageURL` when the hero
    /// switched from the source photo to the cutout.
    @State private var sourcePhotoURL: URL?
    @State private var showDeleteConfirm = false
    @State private var showArchiveConfirm = false
    @State private var isArchiving = false
    @State private var errorMessage: String?
    // Build 18 — drives the fullscreen image viewer cover. Tapping
    // the hero image flips this true; the viewer's close button (or
    // a drag-down gesture) flips it back. Local @State because the
    // viewer is presentational and doesn't need to survive a navigate.
    @State private var showFullScreenImage = false

    private let imageService = ImageService()

    /// Storage path the detail hero renders. Build 50 — the per-item
    /// cutout when available (so the hero matches the grid card's
    /// eggshell showcase), falling back to the framed thumbnail.
    /// Previously the hero showed the full source photo with a
    /// dim-everything-but-the-bbox highlight overlay, but the overlay's
    /// projection math mislanded the white outline (it rendered clipped
    /// in the bottom-right corner — TF feedback #3342), and a clean
    /// cutout reads far better. The original source photo stays one tap
    /// away via the fullscreen viewer. Exposed for tests; the view body
    /// is not directly inspected.
    var heroImagePath: String {
        ItemCardView.displayPath(for: item)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.lg) {
                imageSection
                colorSection
                detailsSection

                if let errorMessage {
                    HStack(spacing: Theme.Spacing.sm) {
                        Image(systemName: "exclamationmark.circle")
                        Text(errorMessage)
                            .font(Theme.Fonts.bodySmall)
                    }
                    .foregroundStyle(Color(Theme.Colors.destructive))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Theme.Spacing.md)
                    .background(Color(Theme.Colors.destructive).opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
                }

                actionsSection
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.top, Theme.Spacing.sm)
            .padding(.bottom, Theme.Spacing.xxl)
        }
        .background(Color(Theme.Colors.background))
        // Build 17 — localized title. SwiftUI accepts `Text(_:)`
        // via the navigationTitle/Text initializer chain so the
        // catalog translation surfaces here too.
        .navigationTitle(Text(item.subcategory.localizedName))
        .navigationBarTitleDisplayMode(.inline)
        // Build 18 — tap-to-zoom for the hero image. Lives at the
        // root of the view so the cover's dismiss animation owns
        // the full screen rather than being clipped inside the
        // ScrollView.
        .fullScreenCover(isPresented: $showFullScreenImage) {
            // Build 50 — the hero is now the cutout; the fullscreen
            // viewer shows the ORIGINAL source photo so the "where did
            // this come from" context is preserved. Falls back to the
            // hero URL if the source photo URL hasn't resolved yet.
            FullScreenImageViewer(url: sourcePhotoURL ?? imageURL, isPresented: $showFullScreenImage)
        }
        .toolbar {
            // Edit button lives in the trailing slot so the iOS-standard
            // back-chevron stays leading. Pushing `EditItemView` rather
            // than sheet-presenting it keeps the user's tap-and-go
            // navigation consistent with the rest of the app.
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    EditItemView(item: item)
                } label: {
                    Text("Edit")
                }
            }
        }
        .task {
            // Hero shows the cutout (matches the grid card); the
            // fullscreen viewer shows the original source photo.
            imageURL = try? await imageService.signedURL(for: heroImagePath)
            sourcePhotoURL = try? await imageService.signedURL(for: item.imagePath)
        }
        .confirmationDialog(
            "Delete this item?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                Task {
                    do {
                        let repo = WardrobeRepository()
                        try await imageService.deleteImages(
                            imagePath: item.imagePath,
                            thumbnailPath: item.thumbnailPath,
                            maskedImagePath: item.maskedImagePath
                        )
                        try await repo.deleteItem(id: item.id)
                        NotificationCenter.default.post(name: .wardrobeDidChange, object: nil)
                        dismiss()
                    } catch {
                        errorMessage = "Failed to delete item."
                    }
                }
            }
        } message: {
            Text("This will permanently remove the item and its photos.")
        }
        .confirmationDialog(
            "Archive this item?",
            isPresented: $showArchiveConfirm,
            titleVisibility: .visible
        ) {
            Button("Archive") {
                Task {
                    isArchiving = true
                    errorMessage = nil
                    do {
                        let repo = WardrobeRepository()
                        try await repo.archiveItem(id: item.id)
                        NotificationCenter.default.post(name: .wardrobeDidChange, object: nil)
                        dismiss()
                    } catch {
                        errorMessage = "Failed to archive item."
                    }
                    isArchiving = false
                }
            }
        } message: {
            Text("Archived items hide from your wardrobe and outfit suggestions. You can restore them later from the archive view.")
        }
    }

    // MARK: - Image

    private var imageSection: some View {
        // Build 50 — the hero shows the per-item cutout on the eggshell
        // showcase backdrop, identical to the grid card. (It previously
        // showed the full source photo with a dim+outline bbox highlight,
        // but the overlay mislanded its outline — TF feedback #3342 — and
        // a clean cutout reads better and is consistent with the rest of
        // the app.)
        //
        // Build 18 — wrapped in a Button so the whole image is a single
        // hit target that opens the fullscreen viewer (which shows the
        // ORIGINAL source photo). `.buttonStyle(.plain)` keeps the
        // rendering untinted so only the tap behavior is added.
        Button {
            HapticManager.light()
            showFullScreenImage = true
        } label: {
            imageContent
        }
        .buttonStyle(.plain)
        .accessibilityLabel("View item photo full screen")
        .accessibilityHint("Double-tap to enlarge")
    }

    private var imageContent: some View {
        ZStack {
            // Build 48/50 — fixed eggshell behind the hero cutout so the
            // showcase backdrop stays the same stable off-white in both
            // light and dark mode (matches the grid cards + the capture
            // preview). Without this the cutout's transparent area showed
            // the adaptive screen background and flipped with the theme.
            Theme.Colors.showcase

            KFImage(imageURL)
                .placeholder {
                    Rectangle()
                        .fill(Color(Theme.Colors.muted).opacity(0.3))
                        .overlay {
                            VStack(spacing: Theme.Spacing.sm) {
                                ProgressView()
                                    .tint(Color(Theme.Colors.primary))
                                Text("Loading image...")
                                    .font(Theme.Fonts.caption)
                                    .foregroundStyle(Color(Theme.Colors.textSecondary))
                            }
                        }
                }
                .resizable()
                .scaledToFit()
                // Center the scaled cutout inside the hero frame; without
                // this the ZStack's default .topLeading would hug the
                // leading edge since scaledToFit produces a smaller rect.
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        // Build 26 — a fixed hero height keeps the image from collapsing
        // inside the Button-in-ScrollView. 360 fits iPhone SE / 13 mini
        // above the fold (~568 pt content area) without overflowing the
        // scroll view on bigger phones.
        .frame(height: 360)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
        .cardShadow()
    }

    // MARK: - Colors

    private var colorSection: some View {
        Group {
            if !item.dominantColors.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    sectionHeader("Colors")
                    EditorialColorView(colors: item.dominantColors)
                }
                .detailCard()
            }
        }
    }

    // MARK: - Details

    private var detailsSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            sectionHeader("Details")

            // Build 17 — values resolved through `String(localized:)`
            // so the locale-current translation lands in the value
            // column. Labels remain catalog keys via the detailRow
            // signature.
            detailRow("Category", value: String(localized: item.category.localizedName), icon: item.category.iconName)
            detailRow("Subcategory", value: String(localized: item.subcategory.localizedName))

            if let texture = item.texture {
                detailRow("Texture", value: String(localized: texture.localizedName))
            }

            if let fit = item.fitAttribute {
                detailRow("Fit", value: String(localized: fit.localizedName))
            }

            if !item.seasons.isEmpty {
                detailTagRow("Seasons", tags: item.seasons.map { String(localized: $0.localizedName) })
            }

            if !item.occasions.isEmpty {
                detailTagRow("Occasions", tags: item.occasions.map { String(localized: $0.localizedName) })
            }

            detailRow("Worn", value: "\(item.wearCount) time\(item.wearCount == 1 ? "" : "s")", icon: "arrow.counterclockwise")

            if let lastWorn = item.lastWornAt {
                detailRow("Last worn", value: lastWorn.formatted(.dateTime.month().day()), icon: "calendar")
            }
        }
        .detailCard()
    }

    // MARK: - Actions

    private var actionsSection: some View {
        VStack(spacing: Theme.Spacing.sm) {
            Button {
                showArchiveConfirm = true
            } label: {
                HStack(spacing: Theme.Spacing.sm) {
                    if isArchiving {
                        ProgressView()
                            .tint(Color(Theme.Colors.primary))
                            .scaleEffect(0.8)
                    }
                    Image(systemName: "archivebox")
                    Text("Archive Item")
                }
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Color(Theme.Colors.primary))
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.button)
                        .stroke(Color(Theme.Colors.primary), lineWidth: 1)
                )
            }
            .disabled(isArchiving)

            Button {
                showDeleteConfirm = true
            } label: {
                HStack(spacing: Theme.Spacing.sm) {
                    Image(systemName: "trash")
                    Text("Delete Item")
                }
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Color(Theme.Colors.destructive))
                .frame(maxWidth: .infinity)
                .frame(height: 48)
            }
        }
    }

    // MARK: - Helpers

    /// Build 17 — LocalizedStringResource so the section header
    /// pulls from the catalog ("Details" → "Detaylar").
    private func sectionHeader(_ title: LocalizedStringResource) -> some View {
        Text(title)
            .font(Theme.Fonts.h3)
            .foregroundStyle(Color(Theme.Colors.textPrimary))
    }

    /// Build 17 — `label` is a `LocalizedStringResource` so static
    /// keys like "Category" / "Subcategory" / "Texture" pass through
    /// the catalog. The `value` stays a String because callers
    /// already pre-resolve via `String(localized:)` for translated
    /// enum values, and plain-text values like "3 times" don't
    /// belong in the catalog.
    private func detailRow(_ label: LocalizedStringResource, value: String, icon: String? = nil) -> some View {
        HStack {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundStyle(Color(Theme.Colors.textSecondary))
                    .frame(width: 20)
            }
            Text(label)
                .font(Theme.Fonts.bodySmall)
                .foregroundStyle(Color(Theme.Colors.textSecondary))
            Spacer()
            Text(value)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color(Theme.Colors.textPrimary))
        }
    }

    private func detailTagRow(_ label: LocalizedStringResource, tags: [String]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text(label)
                .font(Theme.Fonts.bodySmall)
                .foregroundStyle(Color(Theme.Colors.textSecondary))

            FlowLayout(spacing: Theme.Spacing.xs) {
                ForEach(tags, id: \.self) { tag in
                    Text(tag)
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Color(Theme.Colors.textPrimary))
                        .padding(.horizontal, Theme.Spacing.sm)
                        .padding(.vertical, Theme.Spacing.xs)
                        .background(Color(Theme.Colors.surface))
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.chip))
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.Radius.chip)
                                .stroke(Color(Theme.Colors.border), lineWidth: 1)
                        )
                }
            }
        }
    }
}

// MARK: - Detail Card Modifier

private struct DetailCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Spacing.md)
            .background(Color(Theme.Colors.surface))
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
            .cardShadow()
    }
}

private extension View {
    func detailCard() -> some View {
        modifier(DetailCardModifier())
    }
}

// MARK: - Flow Layout

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = layout(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
                proposal: .unspecified
            )
        }
    }

    private func layout(proposal: ProposedViewSize, subviews: Subviews) -> LayoutResult {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)

            if currentX + size.width > maxWidth, currentX > 0 {
                currentX = 0
                currentY += rowHeight + spacing
                rowHeight = 0
            }

            positions.append(CGPoint(x: currentX, y: currentY))
            rowHeight = max(rowHeight, size.height)
            totalHeight = currentY + rowHeight
            currentX += size.width + spacing
        }

        return LayoutResult(
            positions: positions,
            size: CGSize(width: maxWidth, height: totalHeight)
        )
    }

    private struct LayoutResult {
        let positions: [CGPoint]
        let size: CGSize
    }
}

// MARK: - Geometry

/// Computes the rendered rect when an image of `imageSize` is fit inside
/// `containerSize` with `.scaledToFit()` (letterbox bands either
/// above/below or left/right). Returns the rect of the actual image
/// content within the container — origin is the top-left of the rendered
/// photo, size matches its on-screen pixel dimensions.
///
/// A pure geometry helper kept at file scope (`internal`, not `private`)
/// so the unit tests can pin its math (see `WardrobeItemBoundingBoxTests`).
///
/// Edge cases: returns `.zero` if either dimension is zero or non-finite
/// (avoids NaN propagation).
func aspectFitRect(for imageSize: CGSize, in containerSize: CGSize) -> CGRect {
    guard imageSize.width > 0, imageSize.height > 0,
          containerSize.width > 0, containerSize.height > 0,
          imageSize.width.isFinite, imageSize.height.isFinite,
          containerSize.width.isFinite, containerSize.height.isFinite else {
        return .zero
    }

    let containerAspect = containerSize.width / containerSize.height
    let imageAspect = imageSize.width / imageSize.height

    if imageAspect > containerAspect {
        // Image wider than container — bands above and below.
        let height = containerSize.width / imageAspect
        let y = (containerSize.height - height) / 2
        return CGRect(x: 0, y: y, width: containerSize.width, height: height)
    } else {
        // Image taller (or equal aspect) — bands left and right.
        let width = containerSize.height * imageAspect
        let x = (containerSize.width - width) / 2
        return CGRect(x: x, y: 0, width: width, height: containerSize.height)
    }
}
