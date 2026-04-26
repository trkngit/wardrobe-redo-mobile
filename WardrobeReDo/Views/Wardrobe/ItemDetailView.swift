import SwiftUI
import Kingfisher

extension Notification.Name {
    static let wardrobeDidChange = Notification.Name("wardrobeDidChange")
}

struct ItemDetailView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let item: WardrobeItem

    @State private var imageURL: URL?
    /// Intrinsic size of the source photo, captured from
    /// `KFImage.onSuccess`. Stays nil while the image is loading or if
    /// the load failed; the bbox overlay is suppressed until it's
    /// populated so we never render the highlight in the wrong place
    /// (the `.scaledToFit` letterbox bands shift with the source
    /// aspect ratio).
    @State private var loadedImageSize: CGSize?
    @State private var showDeleteConfirm = false
    @State private var showArchiveConfirm = false
    @State private var isArchiving = false
    @State private var errorMessage: String?

    private let imageService = ImageService()

    /// True when the item has a non-nil bounding box, so the source photo
    /// renders with a dim-everything-but-the-bbox overlay. Exposed for
    /// tests; the view body is not directly inspected.
    var shouldShowBoundingBoxOverlay: Bool {
        item.boundingBox != nil
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
        .navigationTitle(item.subcategory.displayName)
        .navigationBarTitleDisplayMode(.inline)
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
            imageURL = try? await imageService.signedURL(for: item.imagePath)
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
        // For multi-pick items the source photo holds multiple garments
        // (e.g. shirt + pants from one mirror selfie). Without a per-item
        // overlay the user can't tell which garment this row represents.
        // When `boundingBox` is present we dim everything outside the
        // bbox and outline it; otherwise the photo renders plainly so
        // legacy / single-item rows look unchanged.
        //
        // `.scaledToFit()` letterboxes the image inside the 400pt-tall
        // frame whenever the source-photo aspect ratio differs from the
        // frame's. Anchoring the overlay to the GeometryReader frame
        // would land the highlight in the letterbox bands; instead we
        // capture the loaded image's intrinsic size via
        // `KFImage.onSuccess` and project the bbox onto the actual
        // rendered image rect inside the frame.
        GeometryReader { geo in
            ZStack {
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
                    .onSuccess { result in
                        // `result.image.size` already accounts for
                        // EXIF orientation — Kingfisher applies it
                        // before handing the UIImage off — so this
                        // matches how `.scaledToFit()` lays the photo
                        // out inside the frame.
                        loadedImageSize = result.image.size
                    }
                    .resizable()
                    .scaledToFit()

                if let bbox = item.boundingBox?.cgRect,
                   let imageSize = loadedImageSize {
                    let imageRect = aspectFitRect(for: imageSize, in: geo.size)
                    let pixelRect = bbox
                        .scaled(to: imageRect.size)
                        .offsetBy(dx: imageRect.minX, dy: imageRect.minY)

                    // Dim the area outside the bbox using an even-odd
                    // fill (outer rect minus inner hole).
                    Rectangle()
                        .fill(Color.black.opacity(0.45))
                        .mask(
                            BoundingBoxHoleShape(rect: pixelRect)
                                .fill(style: FillStyle(eoFill: true))
                        )
                        .allowsHitTesting(false)

                    // Outline the bbox so the highlighted region reads
                    // as deliberate framing rather than a punched-out
                    // hole.
                    Rectangle()
                        .stroke(Color.white, lineWidth: 2)
                        .frame(width: pixelRect.width, height: pixelRect.height)
                        .offset(x: pixelRect.minX, y: pixelRect.minY)
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(maxHeight: 400)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
        .cardShadow()
    }

    // MARK: - Colors

    private var colorSection: some View {
        Group {
            if !item.dominantColors.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    sectionHeader("Colors")
                    ColorSwatchDetailView(colors: item.dominantColors)
                }
                .detailCard()
            }
        }
    }

    // MARK: - Details

    private var detailsSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            sectionHeader("Details")

            detailRow("Category", value: item.category.displayName, icon: item.category.iconName)
            detailRow("Subcategory", value: item.subcategory.displayName)

            if let texture = item.texture {
                detailRow("Texture", value: texture.displayName)
            }

            if let fit = item.fitAttribute {
                detailRow("Fit", value: fit.displayName)
            }

            if !item.seasons.isEmpty {
                detailTagRow("Seasons", tags: item.seasons.map(\.displayName))
            }

            if !item.occasions.isEmpty {
                detailTagRow("Occasions", tags: item.occasions.map(\.displayName))
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

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(Theme.Fonts.h3)
            .foregroundStyle(Color(Theme.Colors.textPrimary))
    }

    private func detailRow(_ label: String, value: String, icon: String? = nil) -> some View {
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

    private func detailTagRow(_ label: String, tags: [String]) -> some View {
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

// MARK: - Bounding Box Overlay

/// Shape composed of an outer rectangle (the full image bounds) and an
/// inner rectangle (the bbox). Filled with an even-odd rule, the inner
/// rect punches a hole — so masking a black-tinted Rectangle with this
/// shape dims everything *outside* the bbox while leaving the garment
/// itself untouched.
private struct BoundingBoxHoleShape: Shape {
    let rect: CGRect

    func path(in pathRect: CGRect) -> Path {
        var path = Path(pathRect)
        path.addRect(rect)
        return path
    }
}

private extension CGRect {
    /// Scales a normalized [0, 1] rect into a pixel rect for the given
    /// size. `BoundingBoxCodable.cgRect` returns normalized coords; the
    /// detail-view overlay multiplies by the rendered image size at the
    /// call site.
    func scaled(to size: CGSize) -> CGRect {
        CGRect(
            x: minX * size.width,
            y: minY * size.height,
            width: width * size.width,
            height: height * size.height
        )
    }
}

/// Computes the rendered rect when an image of `imageSize` is fit
/// inside `containerSize` with `.scaledToFit()` (letterbox bands either
/// above/below or left/right). Returns the rect of the actual image
/// content within the container — origin is the top-left of the
/// rendered photo, size matches its on-screen pixel dimensions.
///
/// `internal` (file-package) so the unit tests can pin its math:
/// `.scaledToFit()` makes the bbox alignment depend on it, and a
/// regression here would silently land the overlay in the letterbox
/// bands again — exactly the bug PR #21 fixes.
///
/// Edge cases: returns `.zero` if either dimension is zero or
/// non-finite (avoids NaN propagation into the overlay rect).
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
