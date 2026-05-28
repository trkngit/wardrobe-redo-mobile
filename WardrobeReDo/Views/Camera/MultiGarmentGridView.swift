import SwiftUI
import UIKit

/// Multi-garment proposal picker — **grid layout**.
///
/// Replaces the earlier overlay-on-photo design (`MultiGarmentTapToSelectView`)
/// which stacked translucent tinted cutouts on top of the source photo and
/// became unreadable as soon as detected items overlapped on the body
/// (e.g. a suit + dress shirt + tie all sharing the torso region rendered
/// as a chaotic heatmap).
///
/// Grid layout rules:
/// - Two columns of square cards. Each card shows ONE proposal's
///   composited cutout (`maskedImage`) on a neutral background — the
///   user sees each detected garment individually instead of guessing
///   which colored blob is which.
/// - Cards scroll vertically — no overflow sheet, no "+N more" affordance.
/// - The card's whole surface is the tap target. A checkmark + tinted
///   border indicate selection. Category label sits below the image.
///
/// Interaction rules (unchanged from the old view, so the ViewModel
/// surface stays identical):
/// - All proposals start selected.
/// - "Use full photo" remains the escape hatch back to the single-item
///   flow.
/// - "Save N items" confirms the selection and pops the queue.
struct MultiGarmentGridView: View {
    let proposals: [MaskProposal]
    @Binding var selectedIDs: Set<MaskProposal.ID>

    var onConfirmed: () -> Void
    var onUseFullPhoto: () -> Void
    var onCancel: () -> Void

    /// Two flexible columns. The grid stretches square cards to fill
    /// each column equally on every screen size — no per-device math.
    private let columns: [GridItem] = [
        GridItem(.flexible(), spacing: Theme.Spacing.md),
        GridItem(.flexible(), spacing: Theme.Spacing.md),
    ]

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ZStack {
                Color(Theme.Colors.background).ignoresSafeArea()

                VStack(spacing: 0) {
                    if shouldShowLayeredLookHint {
                        layeredLookHint
                    }
                    grid
                    bottomBar
                }
            }
            .navigationTitle("Pick items to save")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Use full photo", action: onUseFullPhoto)
                }
            }
        }
    }

    // MARK: - Derived state (exposed for tests)

    /// Proposals laid out in detection-score order, descending. The grid
    /// surfaces the highest-confidence garments first so a user who
    /// only wants the obvious items can grab them in the first row.
    var sortedProposals: [MaskProposal] {
        proposals.sorted { $0.detectionScore > $1.detectionScore }
    }

    var selectionSummary: String {
        "\(selectedIDs.count) of \(proposals.count) selected"
    }

    /// Pluralized CTA text. "Save 1 item" vs "Save 3 items".
    ///
    /// Build 27 — return type changed to `LocalizedStringResource`
    /// after the PrimaryButton signature update. Catalog provides the
    /// translated singular + plural variants; the count slots into
    /// the format specifier.
    var confirmButtonTitle: LocalizedStringResource {
        let n = selectedIDs.count
        return n == 1
            ? LocalizedStringResource("Save 1 item")
            : LocalizedStringResource("Save \(n) items")
    }

    /// Heuristic for the layered-look help tip. The model often fuses a
    /// t-shirt + open overshirt into a single `.top` proposal because the
    /// pieces visually overlap on the torso. When at least one detected
    /// `.top` covers more than 30% of the frame we flag it as a likely
    /// layered look and surface a tip suggesting the user re-shoot each
    /// piece separately. A solitary, well-cropped t-shirt rarely crosses
    /// the threshold so the hint stays out of the way for the common
    /// single-piece case.
    var shouldShowLayeredLookHint: Bool {
        proposals.contains { proposal in
            proposal.predictedCategory == .top
                && proposal.boundingBox.area > Self.layeredLookAreaThreshold
        }
    }

    /// Threshold (normalized image area in [0, 1]) above which a `.top`
    /// proposal is considered large enough to suggest a layered look.
    /// Pulled out so the test suite can pin the exact boundary value.
    static let layeredLookAreaThreshold: CGFloat = 0.30

    // MARK: - Layered-look hint

    /// Inline help tip shown above the grid when the detector likely
    /// merged a t-shirt + overshirt (or any layered top) into a single
    /// proposal. We can't fix the segmentation post-hoc, so we nudge the
    /// user to re-shoot each piece separately for a cleaner result.
    private var layeredLookHint: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.sm) {
            Image(systemName: "info.circle")
                .foregroundStyle(Color(Theme.Colors.primary))
            Text("Wearing layers? Take a separate photo of each piece for the cleanest results.")
                .font(Theme.Fonts.caption)
                .foregroundStyle(Color(Theme.Colors.textSecondary))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .fill(Color(Theme.Colors.primary).opacity(0.08))
        )
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.top, Theme.Spacing.sm)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("MultiGarmentGrid.LayeredLookHint")
    }

    // MARK: - Grid

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: Theme.Spacing.md) {
                ForEach(sortedProposals) { proposal in
                    GridCard(
                        proposal: proposal,
                        isSelected: selectedIDs.contains(proposal.id),
                        onTap: { toggleSelection(proposal.id) }
                    )
                }
            }
            .padding(Theme.Spacing.md)
        }
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        HStack(spacing: Theme.Spacing.md) {
            Text(selectionSummary)
                .font(Theme.Fonts.caption)
                .foregroundStyle(Color(Theme.Colors.textSecondary))
                .accessibilityIdentifier("MultiGarmentGrid.SelectionSummary")
            Spacer()
            PrimaryButton(confirmButtonTitle) {
                onConfirmed()
            }
            .frame(maxWidth: 220)
            .opacity(selectedIDs.isEmpty ? 0.5 : 1)
            .allowsHitTesting(!selectedIDs.isEmpty)
            .accessibilityIdentifier("MultiGarmentGrid.ConfirmButton")
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.md)
        .background(.ultraThinMaterial)
    }

    // MARK: - Logic helpers

    private func toggleSelection(_ id: MaskProposal.ID) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }
}

// MARK: - Grid card

private struct GridCard: View {
    let proposal: MaskProposal
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                imageThumbnail
                label
            }
            .padding(Theme.Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.card)
                    .fill(Color(Theme.Colors.surface))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card)
                    .stroke(
                        isSelected
                            ? Color(Theme.Colors.primary)
                            : Color(Theme.Colors.muted).opacity(0.3),
                        lineWidth: isSelected ? 2 : 1
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            "\(proposal.predictedCategory?.displayName ?? "Item"), " +
            (isSelected ? "selected" : "not selected")
        )
        .accessibilityAddTraits(.isButton)
    }

    private var imageThumbnail: some View {
        // The previous chain — `.scaledToFit()` then
        // `.aspectRatio(1, .fit)` — applied the square constraint AFTER
        // SwiftUI had already sized the image to its natural aspect
        // ratio, so cards rendered at different heights (a tall jeans
        // card next to a short shoe card on the same row).
        //
        // Wrapping a square `Color` placeholder via `.aspectRatio(1)`
        // FIRST forces a uniform square frame; the masked cutout then
        // renders inside via overlay + scaledToFit + padding so the
        // image is always centered, never cropped, and every card in
        // the grid has the same dimensions regardless of cutout
        // aspect ratio.
        Color(Theme.Colors.background)
            .aspectRatio(1, contentMode: .fit)
            .overlay(
                Image(uiImage: proposal.maskedImage)
                    .resizable()
                    .scaledToFit()
                    .padding(Theme.Spacing.sm)
            )
            .overlay(alignment: .topTrailing) {
                checkmarkBadge
                    .padding(Theme.Spacing.xs)
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card - 4))
    }

    private var checkmarkBadge: some View {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .font(.title2)
            .foregroundStyle(
                isSelected
                    ? Color(Theme.Colors.primary)
                    : Color.white.opacity(0.85)
            )
            .background(
                Circle()
                    .fill(.ultraThinMaterial)
                    .frame(width: 28, height: 28)
            )
    }

    private var label: some View {
        HStack(spacing: 4) {
            // Build 17 — pull localized category name when known,
            // fall back to a translated "Item" otherwise.
            Text(proposal.predictedCategory?.localizedName ?? LocalizedStringResource("Item"))
                .font(Theme.Fonts.bodySmall.weight(.medium))
                .foregroundStyle(Color(Theme.Colors.textPrimary))
                .lineLimit(1)
            Spacer(minLength: 0)
            Text("\(Int(proposal.detectionScore * 100))%")
                .font(Theme.Fonts.caption)
                .foregroundStyle(Color(Theme.Colors.textSecondary))
                .monospacedDigit()
        }
    }
}

#if DEBUG
#Preview("3 proposals") {
    MultiGarmentGridViewPreviewHost(proposalCount: 3)
}

#Preview("5 proposals") {
    MultiGarmentGridViewPreviewHost(proposalCount: 5)
}

#Preview("8 proposals (scrolls)") {
    MultiGarmentGridViewPreviewHost(proposalCount: 8)
}

private struct MultiGarmentGridViewPreviewHost: View {
    let proposalCount: Int
    @State private var selectedIDs: Set<UUID> = []

    private var proposals: [MaskProposal] {
        (0..<proposalCount).map { makePreviewProposal(index: $0) }
    }

    private func makePreviewProposal(index i: Int) -> MaskProposal {
        let categories: [ClothingCategory] = [.outerwear, .top, .bottom, .shoe, .accessory, .dress, .top, .accessory]
        let bbox = CGRect(x: 0.1, y: 0.1, width: 0.4, height: 0.4)
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
        MultiGarmentGridView(
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
