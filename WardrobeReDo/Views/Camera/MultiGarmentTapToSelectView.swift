import SwiftUI
import UIKit

/// Multi-garment proposal picker. Shown when the RF-DETR-Seg model
/// detects ≥2 clothing items in one photo; the user checks which
/// proposals they want to save as separate wardrobe entries and hits
/// "Save N items".
///
/// Rendering rules:
/// - The source photo is the backdrop so users keep spatial context.
/// - Each proposal overlays its composited cutout (`maskedImage`) at
///   full scale — because the cutout is source-resolution with
///   transparency outside the mask, overlays auto-align with the
///   backdrop under `.scaledToFit`.
/// - Tinted overlays are stacked largest-first / smallest-last so small
///   accessories (glasses, watches) land on top of big garments and
///   stay tappable.
/// - Each proposal gets a stable color from a fixed palette so the
///   user builds a mental map ("the blue chip = the jacket").
///
/// Interaction rules:
/// - All proposals start selected. Most users will want most items;
///   unchecking is faster than checking from scratch.
/// - Cap the overlay at `displayedProposalCap` to avoid visual clutter;
///   surface the remainder in a "+N more" sheet as a simple list.
/// - "Use full photo" in the trailing toolbar is the escape hatch back
///   to the single-item flow (telemetry-logged in the caller).
struct MultiGarmentTapToSelectView: View {
    let sourceImage: UIImage
    let proposals: [MaskProposal]
    @Binding var selectedIDs: Set<MaskProposal.ID>

    var onConfirmed: () -> Void
    var onUseFullPhoto: () -> Void
    var onCancel: () -> Void

    /// Only the top N proposals (by `detectionScore`) render on the
    /// overlay. Everything past N appears in the "+N more" sheet. 5 was
    /// picked as the point where overlapping chips stop being tappable
    /// on typical garment photos.
    static let displayedProposalCap = 5

    @State private var isShowingOverflowSheet = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color(Theme.Colors.background).ignoresSafeArea()

                VStack(spacing: 0) {
                    GeometryReader { geo in
                        canvas(in: geo.size)
                    }
                    .frame(maxHeight: .infinity)

                    bottomBar
                }
            }
            .navigationTitle("Tap to pick items")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Use full photo", action: onUseFullPhoto)
                }
            }
            .sheet(isPresented: $isShowingOverflowSheet) {
                overflowSheet
            }
        }
    }

    // MARK: - Derived proposal lists (exposed for tests)

    /// Proposals sorted by detection score, descending. Drives the
    /// "top N on canvas + rest in sheet" split.
    var sortedByScore: [MaskProposal] {
        proposals.sorted { $0.detectionScore > $1.detectionScore }
    }

    /// The (up to) N highest-scoring proposals, re-sorted for rendering
    /// so large items land at the back and small items on top.
    var displayedProposals: [MaskProposal] {
        sortedByScore
            .prefix(Self.displayedProposalCap)
            .sorted { $0.boundingBox.area > $1.boundingBox.area }
    }

    /// Proposals that don't fit on the main canvas. Empty when the user
    /// has ≤`displayedProposalCap` proposals total.
    var overflowProposals: [MaskProposal] {
        Array(sortedByScore.dropFirst(Self.displayedProposalCap))
    }

    var selectionSummary: String {
        "\(selectedIDs.count) of \(proposals.count) selected"
    }

    /// Pluralized CTA text. "Save 1 item" vs "Save 3 items".
    var confirmButtonTitle: String {
        let n = selectedIDs.count
        return n == 1 ? "Save 1 item" : "Save \(n) items"
    }

    // MARK: - Canvas

    private func canvas(in size: CGSize) -> some View {
        let displayRect = Self.displayRect(for: sourceImage.size, in: size)

        return ZStack(alignment: .topLeading) {
            Image(uiImage: sourceImage)
                .resizable()
                .scaledToFit()
                .frame(width: size.width, height: size.height)

            ForEach(displayedProposals) { proposal in
                proposalOverlay(
                    for: proposal,
                    displayRect: displayRect,
                    containerSize: size
                )
            }

            if !overflowProposals.isEmpty {
                moreButton
                    .padding(Theme.Spacing.md)
                    .frame(
                        width: size.width,
                        height: size.height,
                        alignment: .bottomTrailing
                    )
            }
        }
    }

    private func proposalOverlay(
        for proposal: MaskProposal,
        displayRect: CGRect,
        containerSize: CGSize
    ) -> some View {
        let tint = Self.tintColor(for: proposal)
        let isSelected = selectedIDs.contains(proposal.id)
        let viewRect = Self.viewRect(for: proposal.boundingBox, in: displayRect)

        return ZStack(alignment: .topLeading) {
            // Tinted cutout — aligned with backdrop because the masked
            // image is at source resolution and `.scaledToFit` fits it
            // into the same rectangle as the backdrop behind it.
            Image(uiImage: proposal.maskedImage)
                .resizable()
                .scaledToFit()
                .frame(width: containerSize.width, height: containerSize.height)
                .colorMultiply(tint)
                .opacity(isSelected ? 0.85 : 0.35)
                .allowsHitTesting(false)

            // Selection outline on the bbox
            if isSelected {
                Rectangle()
                    .stroke(tint, lineWidth: 2)
                    .frame(width: viewRect.width, height: viewRect.height)
                    .offset(x: viewRect.origin.x, y: viewRect.origin.y)
                    .allowsHitTesting(false)
            }

            // Chip + tap target sized to the bounding box so overlapping
            // proposals route correctly (smallest bbox renders last =
            // on top = first to receive the tap).
            chipAndTapTarget(
                for: proposal,
                viewRect: viewRect,
                tint: tint,
                isSelected: isSelected
            )
        }
    }

    private func chipAndTapTarget(
        for proposal: MaskProposal,
        viewRect: CGRect,
        tint: Color,
        isSelected: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            CategoryChip(
                label: proposal.predictedCategory?.displayName ?? "Item",
                isSelected: isSelected,
                tintColor: tint
            )
            .padding(.leading, 4)
            .padding(.top, 4)
            Spacer(minLength: 0)
        }
        .frame(width: viewRect.width, height: viewRect.height, alignment: .topLeading)
        .offset(x: viewRect.origin.x, y: viewRect.origin.y)
        .contentShape(Rectangle())
        .onTapGesture {
            toggleSelection(proposal.id)
        }
        .accessibilityLabel(
            "\(proposal.predictedCategory?.displayName ?? "Item"), " +
            (isSelected ? "selected" : "not selected")
        )
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        HStack(spacing: Theme.Spacing.md) {
            Text(selectionSummary)
                .font(Theme.Fonts.caption)
                .foregroundStyle(Color(Theme.Colors.textSecondary))
                .accessibilityIdentifier("MultiGarment.SelectionSummary")
            Spacer()
            GoldButton(confirmButtonTitle) {
                onConfirmed()
            }
            .frame(maxWidth: 220)
            .opacity(selectedIDs.isEmpty ? 0.5 : 1)
            .allowsHitTesting(!selectedIDs.isEmpty)
            .accessibilityIdentifier("MultiGarment.ConfirmButton")
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.md)
        .background(.ultraThinMaterial)
    }

    // MARK: - Overflow sheet

    private var overflowSheet: some View {
        NavigationStack {
            List {
                ForEach(overflowProposals) { proposal in
                    overflowRow(for: proposal)
                }
            }
            .navigationTitle("More items")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        isShowingOverflowSheet = false
                    }
                }
            }
        }
    }

    private func overflowRow(for proposal: MaskProposal) -> some View {
        let isSelected = selectedIDs.contains(proposal.id)
        return HStack(spacing: Theme.Spacing.md) {
            Image(uiImage: proposal.maskedImage)
                .resizable()
                .scaledToFit()
                .frame(width: 56, height: 56)
                .background(Color(Theme.Colors.surface))
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(proposal.predictedCategory?.displayName ?? "Item")
                    .font(Theme.Fonts.body)
                Text("Confidence \(Int(proposal.detectionScore * 100))%")
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Color(Theme.Colors.textSecondary))
            }

            Spacer()

            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.title2)
                .foregroundStyle(
                    isSelected
                        ? Color(Theme.Colors.primary)
                        : Color(Theme.Colors.textSecondary)
                )
        }
        .contentShape(Rectangle())
        .onTapGesture {
            toggleSelection(proposal.id)
        }
    }

    private var moreButton: some View {
        Button {
            isShowingOverflowSheet = true
        } label: {
            Text("+\(overflowProposals.count) more")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.vertical, Theme.Spacing.sm)
                .background(.ultraThinMaterial, in: Capsule())
        }
    }

    // MARK: - Logic helpers

    private func toggleSelection(_ id: MaskProposal.ID) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }

    // MARK: - Layout math (static so unit tests can verify without a live view)

    /// Fixed palette for proposal tints. 8 colors gives us enough
    /// distinct hues that a 5-proposal photo never collides.
    static let proposalPalette: [Color] = [
        .cyan, .pink, .yellow, .mint, .orange, .indigo, .red, .teal,
    ]

    /// Stable tint derived from the proposal's UUID — re-renders keep
    /// the same color per proposal.
    static func tintColor(for proposal: MaskProposal) -> Color {
        let index = abs(proposal.id.hashValue) % proposalPalette.count
        return proposalPalette[index]
    }

    /// Where does `imageSize` actually render inside a `container` under
    /// `.scaledToFit`? Returns `.zero` for degenerate sizes so the
    /// overlay math stays safe.
    static func displayRect(for imageSize: CGSize, in container: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0,
              container.width > 0, container.height > 0
        else { return .zero }

        let scale = min(container.width / imageSize.width, container.height / imageSize.height)
        let width = imageSize.width * scale
        let height = imageSize.height * scale
        let x = (container.width - width) / 2
        let y = (container.height - height) / 2
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// Convert a normalized bbox (in image coordinates) into the view's
    /// coordinate space, respecting the letterbox offset from
    /// `displayRect`.
    static func viewRect(for normalizedBox: CGRect, in displayRect: CGRect) -> CGRect {
        CGRect(
            x: displayRect.origin.x + normalizedBox.origin.x * displayRect.width,
            y: displayRect.origin.y + normalizedBox.origin.y * displayRect.height,
            width: normalizedBox.width * displayRect.width,
            height: normalizedBox.height * displayRect.height
        )
    }
}

// MARK: - Category chip

private struct CategoryChip: View {
    let label: String
    let isSelected: Bool
    let tintColor: Color

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? tintColor : Color(Theme.Colors.textPrimary))
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color(Theme.Colors.textPrimary))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial, in: Capsule())
    }
}

#if DEBUG
#Preview("3 proposals") {
    MultiGarmentTapToSelectViewPreviewHost(proposalCount: 3)
}

#Preview("7 proposals (overflow)") {
    MultiGarmentTapToSelectViewPreviewHost(proposalCount: 7)
}

/// Wraps the view with `@State` plumbing for Xcode previews — the view
/// itself takes a `@Binding` so a host is needed to drive it.
private struct MultiGarmentTapToSelectViewPreviewHost: View {
    let proposalCount: Int
    @State private var selectedIDs: Set<UUID> = []

    private var proposals: [MaskProposal] {
        (0..<proposalCount).map { makePreviewProposal(index: $0) }
    }

    private func makePreviewProposal(index i: Int) -> MaskProposal {
        let categories: [ClothingCategory] = [.outerwear, .top, .bottom, .shoe, .accessory, .dress, .top]
        let offset: CGFloat = 0.1 + CGFloat(i) * 0.08
        let side: CGFloat = 0.35 - CGFloat(i) * 0.02
        let bbox = CGRect(x: offset, y: offset, width: side, height: side)
        return MaskProposal(
            id: UUID(),
            maskedImage: UIImage(systemName: "tshirt.fill") ?? UIImage(),
            mask: nil,
            confidence: .high,
            predictedCategory: categories[i % categories.count],
            boundingBox: bbox,
            detectionScore: Float(0.95 - Double(i) * 0.05),
            modelClassRaw: "class_\(i)"
        )
    }

    var body: some View {
        MultiGarmentTapToSelectView(
            sourceImage: UIImage(systemName: "photo.fill") ?? UIImage(),
            proposals: proposals,
            selectedIDs: $selectedIDs,
            onConfirmed: {},
            onUseFullPhoto: {},
            onCancel: {}
        )
        .onAppear {
            selectedIDs = Set(proposals.map(\.id))
        }
    }
}
#endif
