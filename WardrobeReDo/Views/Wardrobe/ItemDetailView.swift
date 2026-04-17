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
    @State private var showDeleteConfirm = false
    @State private var isArchiving = false
    @State private var errorMessage: String?

    private let imageService = ImageService()

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
    }

    // MARK: - Image

    private var imageSection: some View {
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
